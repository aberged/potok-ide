defmodule PotokIde.Social.GroupJoinRequest do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_join_requests" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :requester, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:group_id, :requester_id])
    |> validate_required([:group_id, :requester_id])
    |> unique_constraint([:group_id, :requester_id],
      name: :group_join_requests_group_id_requester_id_index
    )
  end
end
