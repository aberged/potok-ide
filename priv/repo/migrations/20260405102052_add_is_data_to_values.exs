defmodule PotokIde.Repo.Migrations.AddIsDataToValues do
  use Ecto.Migration

  def change do
    alter table(:values) do
      add :is_data, :boolean, null: false, default: false
    end
  end
end
