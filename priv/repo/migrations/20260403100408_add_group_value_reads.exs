defmodule PotokIde.Repo.Migrations.AddGroupValueReads do
  use Ecto.Migration

  def change do
    create table(:group_value_reads, primary_key: false) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :last_read_value_id, :bigint

      timestamps(type: :utc_datetime)
    end

    create index(:group_value_reads, [:profile_id])
    create index(:group_value_reads, [:group_id])

    create unique_index(:group_value_reads, [:profile_id, :group_id],
             name: :group_value_reads_profile_id_group_id_index
           )
  end
end
