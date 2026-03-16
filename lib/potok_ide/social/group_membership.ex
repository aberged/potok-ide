defmodule PotokIde.Social.GroupMembership do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "group_memberships" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:group_id, :profile_id])
    |> validate_required([:group_id, :profile_id])
    |> unique_constraint([:group_id, :profile_id],
      name: :group_memberships_group_id_profile_id_index
    )
  end
end
