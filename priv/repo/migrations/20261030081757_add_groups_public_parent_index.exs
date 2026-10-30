defmodule PotokIde.Repo.Migrations.AddGroupsPublicParentIndex do
  use Ecto.Migration

  def change do
    # Visible sub-groups are the profile's memberships plus the public
    # children; every direct conversation is a child of the root, so without
    # this the public half scans all of them.
    create index(:groups, [:parent_id], where: "is_public", name: :groups_public_parent_index)
  end
end
