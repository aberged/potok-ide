defmodule PotokIde.Events do
  @moduledoc """
  The group calendar: events, members' answers per occurrence, members' own
  reminders and the notifications about them.

  Only members of a group see and use its calendar. Members with
  `create_events` add events, authors change or cancel their own while they
  are members, and `manage_events` changes anyone's. The root group holds every
  profile, so it holds no events; its calendar shows the events of every
  group the profile is a member of.

  Members with `publish_events` make an event public: every profile sees it
  in the root calendar (and in the calendar of its group when the group is
  public), may answer it and pick its own reminders. Those who
  are no members get reminders and changes of the occurrences they said
  they come to (going or maybe).

  Changes are broadcast on a topic per group (`subscribe/1`) as
  `{:calendar, {:events_changed, group_id}}` and
  `{:calendar, {:responses_changed, event_id, date}}`; those of public
  events also on the topic `subscribe(:public)`.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Events.{
    Event,
    Format,
    MemberSetting,
    Notifications,
    Occurrence,
    Recurrence,
    Reminders,
    Response
  }

  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccountProfile, Group, GroupMembership, Profile}

  @summary_profiles 12

  # Fields whose change moves occurrences: answers and imported copies follow.
  @schedule_fields [
    :starts_at,
    :ends_at,
    :all_day,
    :recurrence,
    :recurrence_interval,
    :recurrence_weekdays,
    :recurrence_monthly,
    :recurrence_until
  ]

  # Changes members are told about.
  @notable_fields [:location | @schedule_fields]

  ## Live updates

  @doc "Subscribes to the events of a group, or with `:public` to every public event."
  def subscribe(group_id_or_public),
    do: Phoenix.PubSub.subscribe(PotokIde.PubSub, topic(group_id_or_public))

  def unsubscribe(group_id_or_public),
    do: Phoenix.PubSub.unsubscribe(PotokIde.PubSub, topic(group_id_or_public))

  defp topic(:public), do: "public_events"
  defp topic(group_id), do: "group_events:#{group_id}"

  @doc "Tells open calendars that show the event that it changed (say, its tags)."
  def broadcast_events_changed(%Event{} = event),
    do: broadcast_event(event, {:events_changed, event.group_id})

  # To the event's group and, when the event is public (or `was_public?`),
  # to every calendar that shows public events.
  defp broadcast_event(%Event{} = event, message, was_public? \\ false) do
    broadcast(event.group_id, message)
    if event.is_public or was_public?, do: broadcast(:public, message)
    :ok
  end

  defp broadcast(group_id_or_public, message),
    do:
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        topic(group_id_or_public),
        {:calendar, message}
      )

  ## Access

  @doc "Whether the holder of `access` to `group` may add events to it."
  def can_create?(%Access{} = access, %Group{} = group),
    do: not group.is_root and Access.can?(access, :create_events)

  @doc """
  Whether `profile`, holding `access` to the event's group, may change or
  cancel the event.
  """
  def can_manage?(%Access{} = access, %Profile{} = profile, %Event{} = event) do
    access.member? and (event.creator_id == profile.id or Access.can?(access, :manage_events))
  end

  @doc "Whether the holder of `access` to `group` may make its events public, or private again."
  def can_publish?(%Access{} = access, %Group{} = group),
    do: not group.is_root and not group.is_direct and Access.can?(access, :publish_events)

  @doc "Whether `profile` sees the event: anyone a public one, members the others."
  def visible?(%Profile{} = profile, %Event{} = event),
    do: event.is_public or Social.member_of_group?(profile, event_group(event))

  ## Reading

  @doc """
  The groups whose events the calendar of `group` shows to `profile`: the
  group when the profile is a member, and with `include_subgroups?` (always
  in the root group) every group below it the profile is a member of.
  """
  def calendar_group_ids(%Profile{} = profile, %Group{} = group, include_subgroups?) do
    if include_subgroups? or group.is_root do
      # Up from each of the profile's groups until `group` is reached.
      %Postgrex.Result{rows: rows} =
        Repo.query!(
          """
          WITH RECURSIVE chain(member_group_id, id, parent_id) AS (
            SELECT g.id, g.id, g.parent_id
            FROM group_memberships gm
            JOIN groups g ON g.id = gm.group_id
            WHERE gm.profile_id = $1

            UNION ALL

            SELECT c.member_group_id, p.id, p.parent_id
            FROM chain c
            JOIN groups p ON p.id = c.parent_id
            WHERE c.id <> $2
          )
          SELECT DISTINCT member_group_id FROM chain WHERE id = $2
          """,
          [profile.id, group.id]
        )

      List.flatten(rows)
    else
      if Social.member_of_group?(profile, group), do: [group.id], else: []
    end
  end

  @doc """
  The occurrences of the events of `group_ids` that overlap `[from, to)`,
  in order, with `public: true` also those of every public event, or with
  `public: other_group_ids` the public events of those groups. Cancelled
  events are left out. Events come with their group.
  """
  def list_occurrences(group_ids, from, to, opts \\ [])

  def list_occurrences(group_ids, %DateTime{} = from, %DateTime{} = to, opts) do
    public = Keyword.get(opts, :public, false)

    if group_ids == [] and public in [false, []],
      do: [],
      else: query_occurrences(group_ids, from, to, public)
  end

  defp query_occurrences(group_ids, from, to, public) do
    # An occurrence on a series' last date may last up to 31 days.
    until_from = Date.add(DateTime.to_date(from), -32)

    shown =
      case public do
        true ->
          dynamic([e], e.group_id in ^group_ids or e.is_public)

        public_ids when is_list(public_ids) ->
          dynamic([e], e.group_id in ^group_ids or (e.is_public and e.group_id in ^public_ids))

        false ->
          dynamic([e], e.group_id in ^group_ids)
      end

    from(e in Event,
      where: ^shown,
      where: is_nil(e.cancelled_at),
      where: e.starts_at < ^to,
      where:
        e.ends_at >= ^from or
          (e.recurrence != :none and
             (is_nil(e.recurrence_until) or e.recurrence_until >= ^until_from)),
      preload: [:group]
    )
    |> Repo.all()
    |> Enum.flat_map(&Recurrence.occurrences(&1, from, to))
    |> Enum.sort_by(
      &{DateTime.to_unix(&1.starts_at), String.downcase(&1.event.title), &1.event.id}
    )
  end

  @doc "Whether the group has a public event that is not cancelled."
  def public_events?(%Group{id: group_id}) do
    from(e in Event,
      where: e.group_id == ^group_id and e.is_public and is_nil(e.cancelled_at)
    )
    |> Repo.exists?()
  end

  @doc "The event when guests can see a preview of it (`PotokIdeWeb.PublicPreview`)."
  def get_public_event(id) when is_integer(id) do
    from(e in Event, where: e.id == ^id and e.is_public and is_nil(e.cancelled_at))
    |> Repo.one()
  end

  @doc "The event with its group and creator, when `profile` sees it (`visible?/2`)."
  def get_event(%Profile{} = profile, id) when is_integer(id) do
    with %Event{} = event <- Repo.get(Event, id),
         event = Repo.preload(event, [:group, :creator]),
         true <- visible?(profile, event) do
      {:ok, event}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "A new event for the form, on `date` from 18:00 to 19:00 with a reminder an hour before."
  def new_event(%Date{} = date) do
    %Event{
      start_date: date,
      start_time: ~T[18:00:00],
      end_date: date,
      end_time: ~T[19:00:00],
      reminder_minutes: [60]
    }
  end

  def change_event(%Event{} = event, attrs, time_zone),
    do: Event.changeset(event, attrs, time_zone)

  ## Writing

  @doc """
  Adds an event to `group`; the form's times are read in `time_zone`, which
  the event keeps. With `announce: true` (the default) it is posted in the
  group's chat when the creator may post there, and members get a push.
  """
  def create_event(%Profile{} = creator, %Group{} = group, attrs, time_zone, opts \\ []) do
    access = Access.for_profile(creator, group)

    if can_create?(access, group) do
      now = DateTime.utc_now(:second)

      %Event{group_id: group.id, creator_id: creator.id, reminded_through: now}
      |> Event.changeset(attrs, time_zone)
      |> check_publish(access, group)
      |> put_next_reminder(now, [])
      |> Repo.insert()
      |> case do
        {:ok, event} ->
          event = %{event | group: group, creator: creator}
          broadcast_event(event, {:events_changed, group.id})

          event =
            if Keyword.get(opts, :announce, true) and Access.can?(access, :post_values),
              do: announce(creator, group, event),
              else: event

          {:ok, event}

        error ->
          error
      end
    else
      {:error, :not_permitted}
    end
  end

  defp announce(creator, group, event) do
    first = Recurrence.build(event, Recurrence.start_date(event))

    link = fn repo, value ->
      {count, _} =
        repo.update_all(from(e in Event, where: e.id == ^event.id), set: [value_id: value.id])

      {:ok, count}
    end

    case Social.post_event_announcement(
           creator,
           group,
           announcement_content(event, first),
           link,
           Notifications.created(creator, group, first)
         ) do
      {:ok, value} -> %{event | value_id: value.id}
      {:error, _reason} -> event
    end
  end

  # The value's text, for reply quotes and excerpts; the chat shows the
  # event's card in its place. Written in the creator's language and the
  # event's zone.
  defp announcement_content(event, first) do
    today = Recurrence.local_date(DateTime.utc_now(), event.time_zone)

    [
      "📅 **#{escape_markdown(event.title)}**",
      Format.occurrence(first, event.time_zone, today),
      Format.recurrence(event),
      event.location != "" && escape_markdown(event.location)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("  \n")
  end

  defp escape_markdown(text), do: String.replace(text, ~r/([\\`*_\[\]#<>|~])/u, "\\\\\\1")

  @doc """
  Changes an event. The form's times are read in the event's own zone. With
  `notify: true` (the default) members, and those who said they come to a
  public event, are told when its time, place or repeat rule changed.
  """
  def update_event(%Profile{} = actor, %Event{} = event, attrs, opts \\ []) do
    group = event_group(event)
    access = Access.for_profile(actor, group)

    cond do
      not can_manage?(access, actor, event) ->
        {:error, :not_permitted}

      Event.cancelled?(event) ->
        {:error, :cancelled}

      true ->
        Repo.transaction(fn ->
          locked = lock_event!(event.id)

          changeset =
            locked
            |> Event.changeset(attrs, locked.time_zone)
            |> check_publish(access, group)

          schedule_changed? = Enum.any?(@schedule_fields, &Map.has_key?(changeset.changes, &1))
          notable? = Enum.any?(@notable_fields, &Map.has_key?(changeset.changes, &1))

          changeset =
            if schedule_changed?,
              do: Ecto.Changeset.put_change(changeset, :sequence, locked.sequence + 1),
              else: changeset

          changeset = put_next_reminder(changeset, locked.reminded_through, :stored)

          # Read before the answers they gave may be dropped.
          followers = if notable?, do: follower_ids(locked, {:since, today(locked)}), else: []

          case Repo.update(changeset) do
            {:ok, updated} ->
              if schedule_changed?, do: prune_responses(locked, updated)
              {updated, notable?, locked.is_public, followers}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, {updated, notable?, was_public?, followers}} ->
            updated = %{updated | group: group, creator: event.creator}
            broadcast_event(updated, {:events_changed, group.id}, was_public?)
            Social.refresh_value(updated.value_id)

            # An event made private no longer concerns those who are no members.
            followers = if updated.is_public, do: followers, else: []

            if notable? and Keyword.get(opts, :notify, true),
              do: notify_changed(actor, group, updated, followers)

            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Cancels an event: it leaves the calendar, its chat card says it was
  cancelled, and members who did not decline its next occurrence are told,
  as are those who said they come to an occurrence of a public one.
  """
  def cancel_event(%Profile{} = actor, %Event{} = event) do
    group = event_group(event)

    cond do
      not can_manage?(Access.for_profile(actor, group), actor, event) ->
        {:error, :not_permitted}

      Event.cancelled?(event) ->
        {:error, :cancelled}

      true ->
        now = DateTime.utc_now(:second)
        next = Recurrence.next_occurrence_after(event, now)

        event
        |> Ecto.Changeset.change(
          cancelled_at: now,
          next_reminder_at: nil,
          sequence: event.sequence + 1
        )
        |> Repo.update()
        |> case do
          {:ok, cancelled} ->
            cancelled = %{cancelled | group: group, creator: event.creator}
            broadcast_event(cancelled, {:events_changed, group.id})
            Social.refresh_value(cancelled.value_id)

            if next do
              payload_for = Notifications.cancelled(actor, group, cancelled)
              followers = follower_ids(event, {:since, today(event)})

              notify_members(
                group,
                actor,
                {event.id, next.date},
                followers,
                "event cancel",
                payload_for
              )
            end

            {:ok, cancelled}

          error ->
            error
        end
    end
  end

  @doc """
  Cancels the occurrence of a repeating event on the local `date`, which
  must be to come. Members who did not decline it are told, as are those
  who said they come to it when the event is public.
  """
  def cancel_occurrence(%Profile{} = actor, %Event{} = event, %Date{} = date) do
    group = event_group(event)
    occurrence = Recurrence.occurrence(event, date)
    now = DateTime.utc_now(:second)

    cond do
      not can_manage?(Access.for_profile(actor, group), actor, event) ->
        {:error, :not_permitted}

      Event.cancelled?(event) or not Event.recurring?(event) ->
        {:error, :not_repeating}

      is_nil(occurrence) or DateTime.compare(occurrence.ends_at, now) != :gt ->
        {:error, :not_found}

      true ->
        Repo.transaction(fn ->
          locked = lock_event!(event.id)

          locked
          |> Event.exclude_date_changeset(date)
          |> Ecto.Changeset.put_change(:sequence, locked.sequence + 1)
          |> put_next_reminder(locked.reminded_through, :stored)
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, updated} ->
            updated = %{updated | group: group, creator: event.creator}
            broadcast_event(updated, {:events_changed, group.id})

            payload_for = Notifications.occurrence_cancelled(actor, group, occurrence)

            notify_members(
              group,
              actor,
              {event.id, date},
              follower_ids(updated, date),
              "event occurrence cancel",
              payload_for
            )

            {:ok, updated}

          error ->
            error
        end
    end
  end

  ## Answers

  @doc """
  Sets the profile's answer (`:going`, `:maybe`, `:declined`, or nil to take
  it back) for the occurrence on the local `date`, until it has ended. Any
  profile answers a public event; members the others.
  """
  def respond(%Profile{} = profile, %Event{} = event, %Date{} = date, status)
      when status in [:going, :maybe, :declined, nil] do
    occurrence = Recurrence.occurrence(event, date)
    now = DateTime.utc_now(:second)

    cond do
      not visible?(profile, event) ->
        {:error, :not_a_member_of_group}

      Event.cancelled?(event) or is_nil(occurrence) or
          DateTime.compare(occurrence.ends_at, now) != :gt ->
        {:error, :not_found}

      is_nil(status) ->
        from(r in Response,
          where: r.event_id == ^event.id and r.profile_id == ^profile.id and r.occurs_on == ^date
        )
        |> Repo.delete_all()

        broadcast_event(event, {:responses_changed, event.id, date})
        {:ok, nil}

      true ->
        %Response{event_id: event.id, profile_id: profile.id, occurs_on: date}
        |> Response.changeset(%{status: status})
        |> Repo.insert(
          on_conflict: [set: [status: status, updated_at: now]],
          conflict_target: [:event_id, :occurs_on, :profile_id],
          returning: true
        )
        |> case do
          {:ok, response} ->
            broadcast_event(event, {:responses_changed, event.id, date})
            {:ok, response}

          error ->
            error
        end
    end
  end

  @doc """
  The answers for the occurrence on `date`: counts per status and the first
  #{@summary_profiles} profiles of each, counting current members only (any
  profile for a public event), and `profile`'s own answer.
  """
  def response_summary(%Event{} = event, %Date{} = date, %Profile{} = profile) do
    all = from(r in Response, where: r.event_id == ^event.id and r.occurs_on == ^date)

    answers =
      if event.is_public,
        do: all,
        else:
          from([r] in all,
            join: gm in GroupMembership,
            on: gm.group_id == ^event.group_id and gm.profile_id == r.profile_id
          )

    counts =
      from([r] in answers, group_by: r.status, select: {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    ranked =
      from([r] in answers,
        select: %{
          profile_id: r.profile_id,
          status: r.status,
          rank:
            over(row_number(), partition_by: r.status, order_by: [asc: r.updated_at, asc: r.id])
        }
      )

    profiles =
      from(x in subquery(ranked),
        join: p in Profile,
        on: p.id == x.profile_id,
        where: x.rank <= @summary_profiles,
        order_by: [asc: x.rank],
        select: {x.status, p}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    mine =
      from(r in Response,
        where: r.event_id == ^event.id and r.occurs_on == ^date and r.profile_id == ^profile.id,
        select: r.status
      )
      |> Repo.one()

    %{
      counts: Map.new(Response.statuses(), &{&1, Map.get(counts, &1, 0)}),
      profiles: Map.new(Response.statuses(), &{&1, Map.get(profiles, &1, [])}),
      mine: mine
    }
  end

  ## Members' own reminders

  @doc "The profile's own reminders for the event, or nil when it uses the organizer's."
  def member_reminders(%Profile{} = profile, %Event{} = event) do
    from(s in MemberSetting,
      where: s.event_id == ^event.id and s.profile_id == ^profile.id,
      select: s.reminder_minutes
    )
    |> Repo.one()
  end

  def change_member_reminders(%Event{} = event, attrs \\ %{}),
    do: MemberSetting.changeset(%MemberSetting{}, attrs, event)

  @doc """
  Sets the profile's own reminders for every occurrence of the event, or
  with `:default` goes back to the organizer's. Those who are no members of
  a public event's group get them for the occurrences they come to.
  """
  def set_member_reminders(%Profile{} = profile, %Event{} = event, attrs) do
    if visible?(profile, event) do
      Repo.transaction(fn ->
        locked = lock_event!(event.id)

        result =
          case attrs do
            :default ->
              from(s in MemberSetting,
                where: s.event_id == ^event.id and s.profile_id == ^profile.id
              )
              |> Repo.delete_all()

              {:ok, nil}

            attrs ->
              (Repo.get_by(MemberSetting, event_id: event.id, profile_id: profile.id) ||
                 %MemberSetting{event_id: event.id, profile_id: profile.id})
              |> MemberSetting.changeset(attrs, locked)
              |> Repo.insert_or_update()
          end

        case result do
          {:ok, setting} ->
            next =
              Reminders.next_reminder_at(
                locked,
                Reminders.offsets(locked),
                locked.reminded_through
              )

            from(e in Event, where: e.id == ^event.id)
            |> Repo.update_all(set: [next_reminder_at: next])

            setting

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :not_a_member_of_group}
    end
  end

  ## Reminders

  defdelegate send_due_reminders(now \\ DateTime.utc_now(:second)), to: Reminders

  ## Helpers

  defp event_group(%Event{group: %Group{} = group}), do: group
  defp event_group(%Event{group_id: group_id}), do: Repo.get!(Group, group_id)

  defp lock_event!(id), do: Repo.one!(from(e in Event, where: e.id == ^id, lock: "FOR UPDATE"))

  defp today(%Event{} = event), do: Recurrence.local_date(DateTime.utc_now(), event.time_zone)

  # Only those who may publish make an event public, or private again.
  defp check_publish(changeset, access, group) do
    if can_publish?(access, group),
      do: changeset,
      else: Ecto.Changeset.delete_change(changeset, :is_public)
  end

  # `next_reminder_at` from the new fields, counting the members' own
  # offsets (`:stored`, for an event that exists) or only the organizer's.
  defp put_next_reminder(%Ecto.Changeset{valid?: false} = changeset, _since, _members),
    do: changeset

  defp put_next_reminder(changeset, since, members) do
    event = Ecto.Changeset.apply_changes(changeset)
    offsets = if members == :stored, do: Reminders.offsets(event), else: event.reminder_minutes

    Ecto.Changeset.put_change(
      changeset,
      :next_reminder_at,
      Reminders.next_reminder_at(event, offsets, since)
    )
  end

  # Answers are for a date and a time. Those to come are dropped when their
  # date is no longer an occurrence, or all of them when the time changed.
  defp prune_responses(%Event{} = old, %Event{} = new) do
    today = today(new)
    future = from(r in Response, where: r.event_id == ^new.id and r.occurs_on >= ^today)

    if local_time_and_length(old) != local_time_and_length(new) do
      Repo.delete_all(future)
    else
      gone =
        from([r] in future, distinct: true, select: r.occurs_on)
        |> Repo.all()
        |> Enum.reject(&Recurrence.occurs_on?(new, &1))

      if gone != [], do: Repo.delete_all(from([r] in future, where: r.occurs_on in ^gone))
    end
  end

  defp local_time_and_length(%Event{} = event) do
    local = DateTime.shift_zone!(event.starts_at, event.time_zone)
    {event.all_day, DateTime.to_time(local), DateTime.diff(event.ends_at, event.starts_at)}
  end

  defp notify_changed(actor, group, event, followers) do
    case Recurrence.next_occurrence_after(event, DateTime.utc_now(:second)) do
      nil ->
        :ok

      %Occurrence{} = next ->
        notify_members(
          group,
          actor,
          nil,
          followers,
          "event change",
          Notifications.changed(actor, group, next)
        )
    end
  end

  # The profiles who are no members of a public event's group and said they
  # come (going or maybe) to its occurrence on `date`, or with `{:since,
  # date}` to any occurrence from that date on.
  defp follower_ids(%Event{is_public: false}, _dates), do: []

  defp follower_ids(%Event{} = event, dates) do
    query =
      from(r in Response,
        left_join: gm in GroupMembership,
        on: gm.group_id == ^event.group_id and gm.profile_id == r.profile_id,
        where:
          r.event_id == ^event.id and r.status in ^[:going, :maybe] and is_nil(gm.profile_id),
        distinct: true,
        select: r.profile_id
      )

    case dates do
      %Date{} = date -> from([r] in query, where: r.occurs_on == ^date)
      {:since, %Date{} = date} -> from([r] in query, where: r.occurs_on >= ^date)
    end
    |> Repo.all()
  end

  # Members other than `actor`, with `{event_id, date}` not those who
  # declined that occurrence, and the `followers` (profile ids).
  defp notify_members(group, actor, declined, followers, context, payload_for) do
    Dispatch.run(fn ->
      group
      |> member_account_ids(actor, declined)
      |> with_follower_accounts(actor, followers)
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_localized(context, group.id, payload_for)
    end)
  end

  defp with_follower_accounts(query, _actor, []), do: query

  defp with_follower_accounts(query, %Profile{} = actor, followers) do
    union(
      query,
      ^from(ap in AccountProfile,
        where: ap.profile_id in ^followers and ap.profile_id != ^actor.id,
        select: ap.account_id
      )
    )
  end

  defp member_account_ids(%Group{} = group, %Profile{} = actor, declined) do
    query =
      from(gm in GroupMembership,
        join: ap in AccountProfile,
        on: ap.profile_id == gm.profile_id,
        where: gm.group_id == ^group.id and gm.profile_id != ^actor.id,
        select: ap.account_id
      )

    case declined do
      nil ->
        query

      {event_id, date} ->
        from([gm] in query,
          left_join: r in Response,
          on: r.event_id == ^event_id and r.profile_id == gm.profile_id and r.occurs_on == ^date,
          where: is_nil(r.status) or r.status != ^:declined
        )
    end
  end
end
