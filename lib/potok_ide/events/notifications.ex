defmodule PotokIde.Events.Notifications do
  @moduledoc """
  Push payloads about events. Each is built in every supported language,
  since every device gets notifications in the language it saved its push
  subscription with (`PotokIde.Accounts.PushSubscription.locale`). Times are
  given in the event's zone.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1]

  alias PotokIde.Events.{Event, Format, Occurrence, Recurrence}
  alias PotokIde.Social.{Group, Profile}

  def created(%Profile{} = creator, %Group{} = group, %Occurrence{} = occurrence) do
    localized(fn ->
      %{
        title:
          dgettext("events", "%{name} added an event in %{group}",
            name: creator.username,
            group: group.name
          ),
        body: "#{occurrence.event.title} · #{when_text(occurrence)}",
        tag: tag(occurrence.event),
        url: url(occurrence),
        badge: badge(creator)
      }
    end)
  end

  def changed(%Profile{} = actor, %Group{} = group, %Occurrence{} = occurrence) do
    localized(fn ->
      %{
        title: dgettext("events", "Event changed: %{title}", title: occurrence.event.title),
        body: "#{when_text(occurrence)} · #{group.name}",
        tag: tag(occurrence.event),
        url: url(occurrence),
        badge: badge(actor)
      }
    end)
  end

  def cancelled(%Profile{} = actor, %Group{} = group, %Event{} = event) do
    localized(fn ->
      %{
        title: dgettext("events", "Event cancelled: %{title}", title: event.title),
        body: group.name,
        tag: tag(event),
        url: "/groups/#{group.id}/calendar?event=#{event.id}",
        badge: badge(actor)
      }
    end)
  end

  def occurrence_cancelled(%Profile{} = actor, %Group{} = group, %Occurrence{} = occurrence) do
    localized(fn ->
      %{
        title: dgettext("events", "Cancelled: %{title}", title: occurrence.event.title),
        body: "#{when_text(occurrence)} · #{group.name}",
        tag: "#{tag(occurrence.event)}-#{occurrence.date}",
        url: url(occurrence),
        badge: badge(actor)
      }
    end)
  end

  @doc "The reminder `minutes` before an occurrence (before 09:00 for all-day ones)."
  def reminder(%Group{} = group, %Occurrence{event: event} = occurrence, minutes) do
    localized(fn ->
      location = if event.location != "", do: " · #{event.location}", else: ""

      %{
        title: event.title,
        body:
          "#{starts_in(event, minutes)} · #{when_text(occurrence)}#{location} · #{group.name}",
        tag: "#{tag(event)}-#{occurrence.date}-reminder",
        url: url(occurrence),
        badge: PotokIdeWeb.Avatars.group_badge_url(group)
      }
    end)
  end

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

  # Same route as the badges of the other notifications (see `Social`).
  defp badge(%Profile{id: profile_id}), do: "/avatar/profile/#{profile_id}?format=png"
end
