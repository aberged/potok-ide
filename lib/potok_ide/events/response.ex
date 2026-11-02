defmodule PotokIde.Events.Response do
  @moduledoc """
  A member's answer for one occurrence of an event, named by its local start
  date. Members who declined get no reminders for that occurrence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses [:going, :maybe, :declined]

  schema "group_event_responses" do
    field :occurs_on, :date
    field :status, Ecto.Enum, values: @statuses

    belongs_to :event, PotokIde.Events.Event
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  `event_id`, `profile_id` and `occurs_on` are set on the struct by the
  caller, never cast.
  """
  def changeset(response, attrs) do
    response
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> check_constraint(:status, name: :group_event_responses_status_check)
  end
end
