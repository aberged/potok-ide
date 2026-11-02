defmodule PotokIde.Events.MemberSetting do
  @moduledoc """
  A member's own reminders for every occurrence of an event, in place of the
  organizer's. An empty list turns them off; without a row the member gets
  the event's reminders.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Events.Event

  schema "group_event_member_settings" do
    field :reminder_minutes, {:array, :integer}, default: []

    belongs_to :event, Event
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  @doc """
  `event_id` and `profile_id` are set on the struct by the caller, never
  cast. `event` gives the reminder choices.
  """
  def changeset(setting, attrs, %Event{} = event) do
    attrs =
      case attrs do
        %{"reminder_minutes" => minutes} when is_list(minutes) ->
          Map.put(attrs, "reminder_minutes", Enum.reject(minutes, &(&1 == "")))

        attrs ->
          attrs
      end

    setting
    |> cast(attrs, [:reminder_minutes])
    |> update_change(:reminder_minutes, &(&1 |> Enum.uniq() |> Enum.sort()))
    |> validate_subset(:reminder_minutes, Event.reminder_choices(event))
    |> validate_length(:reminder_minutes, max: Event.max_reminders())
  end
end
