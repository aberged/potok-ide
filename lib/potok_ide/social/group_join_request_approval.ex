defmodule PotokIde.Social.GroupJoinRequestApproval do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_join_request_approvals" do
    field :approved_at, :utc_datetime

    belongs_to :group, PotokIde.Social.Group
    belongs_to :requester, PotokIde.Social.Profile
    belongs_to :approver, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:group_id, :requester_id, :approver_id, :approved_at])
    |> validate_required([:group_id, :requester_id, :approver_id, :approved_at])
  end
end
