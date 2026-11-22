defmodule PotokIde.Social.GroupJoinRequest do
  @moduledoc """
  A profile asks to join a public group, with the roles it would like there
  (`role_keys`) and, if it wants, why (`note`). How it is decided is the
  group's rule (`Group.join_mode`, see `PotokIde.Social.GroupRequests`):
  while a vote on it runs, `poll_id` names that vote.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_note 500

  schema "group_join_requests" do
    field :note, :string
    field :role_keys, {:array, :string}, default: []

    belongs_to :group, PotokIde.Social.Group
    belongs_to :requester, PotokIde.Social.Profile
    # The vote on admitting them, while it runs.
    belongs_to :poll, PotokIde.Polls.Poll

    timestamps(type: :utc_datetime)
  end

  def max_note, do: @max_note

  @doc "`group_id` and `requester_id` are the caller's; the note and roles are what they asked."
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:group_id, :requester_id, :note, :role_keys])
    |> validate_required([:group_id, :requester_id])
    |> update_change(:note, &trim/1)
    |> validate_length(:note, max: @max_note, count: :codepoints)
    |> unique_constraint([:group_id, :requester_id],
      name: :group_join_requests_group_id_requester_id_index
    )
  end

  defp trim(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      note -> note
    end
  end

  defp trim(note), do: note
end
