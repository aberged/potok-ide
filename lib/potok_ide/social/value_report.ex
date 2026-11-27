defmodule PotokIde.Social.ValueReport do
  @moduledoc """
  A message a profile reported to the admins of its group
  (`PotokIde.Social.ValueReports`). The admins see it until one of them
  dismisses it or deletes the message, which takes the report with it. The
  reporter sees only that they reported it; its author never learns who did.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @reasons [:spam, :abuse, :inappropriate, :other]
  @max_note 500

  schema "value_reports" do
    field :reason, Ecto.Enum, values: @reasons
    # Kept out of logs: it is between the reporter and the admins.
    field :note, :string, default: "", redact: true
    field :dismissed_at, :utc_datetime

    belongs_to :group, PotokIde.Social.Group
    belongs_to :value, PotokIde.Social.Value
    belongs_to :reporter, PotokIde.Social.Profile
    belongs_to :dismissed_by, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def reasons, do: @reasons
  def max_note, do: @max_note

  @doc "The reporter's own fields: the reason and a note; the rest is set by `ValueReports`."
  def changeset(%__MODULE__{} = report, attrs) do
    report
    # An empty note stays "", which the column holds, instead of nil.
    |> cast(attrs, [:reason, :note], empty_values: [nil])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:reason])
    |> validate_length(:note, max: @max_note)
    |> unique_constraint([:value_id, :reporter_id])
    |> check_constraint(:reason, name: :value_reports_reason_check)
    |> check_constraint(:note, name: :value_reports_note_length)
  end
end
