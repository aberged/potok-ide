defmodule PotokIde.Events.Reminders do
  @moduledoc """
  When event reminders are due, and who gets them.

  A reminder of `m` minutes is due `m` minutes before an occurrence starts,
  or before 09:00 on the day of an all-day one. An event's offsets are the
  organizer's and every member's own (`MemberSetting`); each member gets
  the ones they chose, or the organizer's, unless they declined the
  occurrence. Of a public event, those who are no members of its group get
  them for the occurrences they said they come to (going or maybe).

  `Event.reminded_through` says up to when reminders are handled and is the
  source of truth; `Event.next_reminder_at` is when the scheduler should look
  again. It may be early (a pass then sends nothing) but is never late, so
  writers that compute it from an older `reminded_through` stay safe.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Events.{Event, MemberSetting, Notifications, Occurrence, Recurrence, Response}
  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Social.{AccountProfile, Group, GroupMembership}

  # Reminders found later than this (say, after a deploy) are dropped: a
  # "starts in 15 minutes" an hour late helps nobody.
  @grace_seconds 600
  @batch_size 200
  @all_day_time ~T[09:00:00]

  @doc "The offsets of the event: the organizer's and the members' own."
  def offsets(%Event{} = event) do
    members =
      from(s in MemberSetting,
        where: s.event_id == ^event.id,
        select: fragment("DISTINCT unnest(?)", s.reminder_minutes)
      )
      |> Repo.all()

    Enum.sort(Enum.uniq(event.reminder_minutes ++ members))
  end

  @doc "The instant reminders count back from."
  def anchor(%Occurrence{event: %Event{all_day: true} = event, date: date}),
    do: Recurrence.to_utc(date, @all_day_time, event.time_zone)

  def anchor(%Occurrence{starts_at: starts_at}), do: starts_at

  @doc """
  The first reminder after `since` for `offsets`, or nil when there is none
  (a cancelled event, or a series that has ended).
  """
  def next_reminder_at(%Event{cancelled_at: %DateTime{}}, _offsets, _since), do: nil
  def next_reminder_at(%Event{}, [], _since), do: nil

  def next_reminder_at(%Event{} = event, offsets, %DateTime{} = since) do
    offsets
    |> Enum.map(fn minutes ->
      target = DateTime.add(since, minutes * 60)

      case Recurrence.find(event, search_from(event, target), &later?(anchor(&1), target)) do
        nil -> nil
        occurrence -> DateTime.add(anchor(occurrence), -minutes * 60)
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  @doc """
  The reminders due in `(from, to]`, as `{occurrence, minutes}` pairs.
  """
  def due(%Event{} = event, offsets, %DateTime{} = from, %DateTime{} = to) do
    for minutes <- offsets,
        occurrence <- due_occurrences(event, minutes, from, to),
        do: {occurrence, minutes}
  end

  defp due_occurrences(event, minutes, from, to) do
    low = DateTime.add(from, minutes * 60)
    high = DateTime.add(to, minutes * 60)

    event
    |> Recurrence.dates_from(search_from(event, low))
    |> Stream.map(&Recurrence.build(event, &1))
    |> Stream.take_while(&(not later?(anchor(&1), high)))
    |> Enum.filter(&later?(anchor(&1), low))
  end

  # Every occurrence whose anchor is after `instant` starts on or after this
  # local date (a day of margin for the zone offset).
  defp search_from(event, instant),
    do: Date.add(Recurrence.local_date(instant, event.time_zone), -1)

  defp later?(a, b), do: DateTime.compare(a, b) == :gt

  @doc """
  Sends the reminders that are due at `now` and moves every handled event's
  `reminded_through` to `now`. Events are taken with `FOR UPDATE SKIP
  LOCKED`, so several nodes can run this at once without sending a reminder
  twice. Pushes go out after the commit: a crash in between loses them
  rather than sending them again.
  """
  def send_due_reminders(%DateTime{} = now \\ DateTime.utc_now(:second)) do
    now = DateTime.truncate(now, :second)

    {:ok, {handled, reminders}} =
      Repo.transaction(fn ->
        events =
          from(e in Event,
            where: e.next_reminder_at <= ^now,
            order_by: [asc: e.next_reminder_at],
            limit: @batch_size,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> Repo.all()

        reminders = Enum.flat_map(events, &handle_event(&1, now))
        {length(events), reminders}
      end)

    Enum.each(reminders, &send_reminder/1)

    if handled == @batch_size, do: send_due_reminders(now), else: :ok
  end

  defp handle_event(%Event{} = event, now) do
    offsets = offsets(event)
    from = Enum.max([event.reminded_through, DateTime.add(now, -@grace_seconds)], DateTime)

    due =
      if is_nil(event.cancelled_at) and later?(now, from),
        do: due(event, offsets, from, now),
        else: []

    from(e in Event, where: e.id == ^event.id)
    |> Repo.update_all(
      set: [reminded_through: now, next_reminder_at: next_reminder_at(event, offsets, now)]
    )

    due
  end

  defp send_reminder({%Occurrence{event: event} = occurrence, minutes}) do
    Dispatch.run(fn ->
      group = Repo.get(Group, event.group_id)

      if group do
        payload_for = Notifications.reminder(group, occurrence, minutes)

        event
        |> recipient_account_ids(occurrence.date, minutes)
        |> Dispatch.subscriptions_by_account()
        |> Dispatch.deliver_localized("event reminder", event.id, payload_for)
      end
    end)
  end

  @doc """
  A query selecting the accounts of the members who get the reminder of
  `minutes` for the occurrence on `date`: those whose own reminders, or else
  the organizer's, include it, and who did not decline. Of a public event,
  also those who are no members and said they come (going or maybe) with
  such reminders. An account is selected when any of its profiles is.
  """
  def recipient_account_ids(%Event{} = event, %Date{} = date, minutes) do
    members =
      from(gm in GroupMembership,
        join: ap in AccountProfile,
        on: ap.profile_id == gm.profile_id,
        left_join: s in MemberSetting,
        on: s.event_id == ^event.id and s.profile_id == gm.profile_id,
        left_join: r in Response,
        on: r.event_id == ^event.id and r.profile_id == gm.profile_id and r.occurs_on == ^date,
        where: gm.group_id == ^event.group_id,
        where:
          fragment(
            "? = ANY(COALESCE(?, ?))",
            ^minutes,
            s.reminder_minutes,
            type(^event.reminder_minutes, {:array, :integer})
          ),
        where: is_nil(r.status) or r.status != ^:declined,
        select: ap.account_id
      )

    if event.is_public,
      do: union(members, ^follower_account_ids(event, date, minutes)),
      else: members
  end

  defp follower_account_ids(%Event{} = event, %Date{} = date, minutes) do
    from(r in Response,
      join: ap in AccountProfile,
      on: ap.profile_id == r.profile_id,
      left_join: gm in GroupMembership,
      on: gm.group_id == ^event.group_id and gm.profile_id == r.profile_id,
      left_join: s in MemberSetting,
      on: s.event_id == ^event.id and s.profile_id == r.profile_id,
      where: r.event_id == ^event.id and r.occurs_on == ^date and is_nil(gm.profile_id),
      where: r.status in ^[:going, :maybe],
      where:
        fragment(
          "? = ANY(COALESCE(?, ?))",
          ^minutes,
          s.reminder_minutes,
          type(^event.reminder_minutes, {:array, :integer})
        ),
      select: ap.account_id
    )
  end
end
