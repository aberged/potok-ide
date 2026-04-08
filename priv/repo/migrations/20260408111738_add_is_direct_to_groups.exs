defmodule PotokIde.Repo.Migrations.AddIsDirectToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :is_direct, :boolean, default: false, null: false
    end
  end
end
