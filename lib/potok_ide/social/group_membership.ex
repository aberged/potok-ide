defmodule PotokIde.Social.GroupMembership do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "group_memberships" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    # Held only through the parent group (see `Social.MemberInheritance`).
    field :inherited, :boolean, default: false
    # Until when the member silenced the group (`Social.GroupMutes`); never
    # cast, set by `GroupMutes.set/3`.
    field :muted_until, :utc_datetime
    # The last value the member got a push for, and when; the next one of
    # this group waits until they read up to it or five minutes pass. Never
    # cast, set by `Social` when a value is posted.
    field :last_push_value_id, :integer
    field :last_pushed_at, :utc_datetime

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
