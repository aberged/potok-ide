defmodule PotokIde.Repo.Migrations.AddMutedUntilToGroupMemberships do
  use Ecto.Migration

  # Until when a member silenced the group (`PotokIde.Social.GroupMutes`).
  # Empty for everyone: rows that `MemberInheritance` writes in raw SQL keep
  # the default.
  def change do
    alter table(:group_memberships) do
      add :muted_until, :utc_datetime
    end
  end
end
