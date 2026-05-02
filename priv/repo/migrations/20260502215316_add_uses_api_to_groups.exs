defmodule PotokIde.Repo.Migrations.AddUsesApiToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :uses_api, :boolean, null: false, default: false
    end
  end
end
