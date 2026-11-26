defmodule PotokIde.Events.Notifications do
  @moduledoc """
  Push payloads about events. Each is built in every supported language,
  since every device gets notifications in the language it saved its push
  subscription with (`PotokIde.Accounts.PushSubscription.locale`). Times are
  given in the event's zone.

  As in `PotokIde.Social.Notifications`, the title is the group and the body
  starts with 📅; a reminder is titled with the event, as calendars do. The
  label "Calendar" goes under the title where the phone shows one. A payload
  is worth delivering until its occurrence ends, a reminder until shortly
  after it starts.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1, expires_at: 1, now_ms: 0]

  alias PotokIde.Events.{Event, Format, Occurrence, Recurrence}
  alias PotokIde.PushNotifications.Conversation
  alias PotokIde.Social.{Group, Profile}
  alias PotokIdeWeb.Avatars

  # A reminder of a timed occurrence still helps a little after it started.
  @reminder_grace_seconds 15 * 60

  def created(%Profile{} = creator, %Group{} = group, %Occurrence{} = occurrence) do
    look = Conversation.of(group, creator)
    name = Profile.display_name(creator)

    base =
      base(group, occurrence.event, look, url(occurrence), occurrence.ends_at)
      |> Map.merge(%{sender: name, sender_icon: Avatars.profile_badge_url(creator)})

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body: "📅 #{name}: #{occurrence.event.title} · #{when_text(occurrence)}",
        label: label()
      })
    end)
  end

  def changed(%Profile{} = actor, %Group{} = group, %Occurrence{} = occurrence) do
    look = Conversation.of(group, actor)
    base = base(group, occurrence.event, look, url(occurrence), occurrence.ends_at)

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body:
          "📅 " <>
            dgettext("events", "Event changed: %{title}", title: occurrence.event.title) <>
            " · " <> when_text(occurrence),
        label: label()
      })
    end)
  end

  def cancelled(%Profile{} = actor, %Group{} = group, %Event{} = event) do
    look = Conversation.of(group, actor)
    base = base(group, event, look, "/groups/#{group.id}/calendar?event=#{event.id}", nil)

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body: "📅 " <> dgettext("events", "Event cancelled: %{title}", title: event.title),
        label: label()
      })
    end)
  end

  def occurrence_cancelled(%Profile{} = actor, %Group{} = group, %Occurrence{} = occurrence) do
    look = Conversation.of(group, actor)

    base =
      base(group, occurrence.event, look, url(occurrence), occurrence.ends_at)
      |> Map.put(:tag, "#{tag(occurrence.event)}-#{occurrence.date}")

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body:
          "📅 " <>
            dgettext("events", "Cancelled: %{title}", title: occurrence.event.title) <>
            " · " <> when_text(occurrence),
        label: label()
      })
    end)
  end

  @doc "The reminder `minutes` before an occurrence (before 09:00 for all-day ones)."
  def reminder(%Group{} = group, %Occurrence{event: event} = occurrence, minutes) do
    look = Conversation.of(group, nil)

    until =
      if event.all_day,
        do: occurrence.ends_at,
        else: DateTime.add(occurrence.starts_at, @reminder_grace_seconds)

    base =
      base(group, event, look, url(occurrence), until)
      |> Map.merge(%{kind: "event_reminder", tag: "#{tag(event)}-#{occurrence.date}-reminder"})

    localized(fn ->
      location = if event.location != "", do: " · #{event.location}", else: ""

      Map.merge(base, %{
        title: event.title,
        body:
          "#{starts_in(event, minutes)} · #{when_text(occurrence)}#{location} · #{look.title}",
        label: label()
      })
    end)
  end

  defp base(%Group{} = group, %Event{} = event, look, url, until) do
    %{
      kind: "event",
      tag: tag(event),
      url: url,
      group_id: group.id,
      icon: look.icon,
      timestamp: now_ms(),
      expires_at: expires_at(until || :week)
    }
  end

  defp label, do: dgettext("notifications", "Calendar")

  defp starts_in(%Event{all_day: true}, 0), do: dgettext("events", "Today")
  defp starts_in(%Event{all_day: true}, 1440), do: dgettext("events", "Tomorrow")

  defp starts_in(%Event{all_day: true}, minutes),
    do: dngettext("events", "In %{count} day", "In %{count} days", div(minutes, 1440))

  defp starts_in(%Event{}, 0), do: dgettext("events", "Starting now")

  defp starts_in(%Event{}, minutes) when minutes < 60,
    do: dngettext("events", "In %{count} minute", "In %{count} minutes", minutes)

  defp starts_in(%Event{}, minutes) when minutes < 1440,
    do: dngettext("events", "In %{count} hour", "In %{count} hours", div(minutes, 60))

  defp starts_in(%Event{}, minutes),
    do: dngettext("events", "In %{count} day", "In %{count} days", div(minutes, 1440))

  defp when_text(%Occurrence{event: event} = occurrence) do
    today = Recurrence.local_date(DateTime.utc_now(), event.time_zone)
    Format.occurrence(occurrence, event.time_zone, today)
  end

  # One tag per event, so a later notification replaces the earlier one.
  defp tag(%Event{id: id, group_id: group_id}), do: "group-#{group_id}-event-#{id}"

  defp url(%Occurrence{event: event, date: date}),
    do: "/groups/#{event.group_id}/calendar?event=#{event.id}&on=#{date}"
end
