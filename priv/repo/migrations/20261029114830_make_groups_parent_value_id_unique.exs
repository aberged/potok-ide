defmodule PotokIde.Repo.Migrations.MakeGroupsParentValueIdUnique do
  use Ecto.Migration

  # A value has at most one thread group; the unique index also settles two
  # members opening the same thread at once. NULLs (ordinary groups) stay allowed.
  def change do
    drop index(:groups, [:parent_value_id])
    create unique_index(:groups, [:parent_value_id])
  end
end
