defmodule PotokIde.Social.GroupJoinRequestApproval do
  @moduledoc """
  That someone was admitted to a group on their request, and by whom: a
  member who manages requests (`approver_id`) or a vote (`poll_id`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "group_join_request_approvals" do
    field :approved_at, :utc_datetime

    belongs_to :group, PotokIde.Social.Group
    belongs_to :requester, PotokIde.Social.Profile
    belongs_to :approver, PotokIde.Social.Profile
    # Admitted by a vote: the poll that decided it.
    belongs_to :poll, PotokIde.Polls.Poll

    timestamps(type: :utc_datetime)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:group_id, :requester_id, :approver_id, :poll_id, :approved_at])
    |> validate_required([:group_id, :requester_id, :approved_at])
    |> check_constraint(:approver_id, name: :group_join_request_approvals_by_check)
  end
end
