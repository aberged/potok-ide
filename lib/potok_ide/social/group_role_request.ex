defmodule PotokIde.Social.GroupRoleRequest do
  @moduledoc """
  A member asks for roles in a group (`role_keys`), saying why if it wants
  (`note`). It holds only the roles still waiting for whoever manages
  requests: a role that goes to a vote leaves it for its poll, and a decided
  one for a `PotokIde.Social.GroupRequestDecision`. One per member and
  group, which goes with the membership. See `PotokIde.Social.GroupRequests`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "group_role_requests" do
    field :role_keys, {:array, :string}
    field :note, :string

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:role_keys, :note])
    |> validate_required([:role_keys])
    |> validate_length(:role_keys, min: 1)
    |> validate_length(:note,
      max: PotokIde.Social.GroupJoinRequest.max_note(),
      count: :codepoints
    )
    |> unique_constraint([:group_id, :profile_id],
      name: :group_role_requests_group_id_profile_id_index
    )
  end
end
