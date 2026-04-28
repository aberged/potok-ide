defmodule PotokIde.Repo.Migrations.AddDataToValues do
  use Ecto.Migration

  def change do
    alter table(:values) do
      add :data, :map
    end
  end
end
