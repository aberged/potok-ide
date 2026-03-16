defmodule PotokIde.Repo.Migrations.AddParentValueToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :parent_value_id, references(:values, on_delete: :nilify_all)
    end

    create index(:groups, [:parent_value_id])
  end
end
