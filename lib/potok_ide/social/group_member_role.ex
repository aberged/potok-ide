defmodule PotokIde.Social.GroupMemberRole do
  @moduledoc """
  A role assigned to a member of one group. `role_key` points at a role of the
  group's effective manifest; "everyone" is implicit and never stored.
  """

  use Ecto.Schema

  @primary_key false
  schema "group_member_roles" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    field :role_key, :string

    timestamps(type: :utc_datetime)
  end
end
