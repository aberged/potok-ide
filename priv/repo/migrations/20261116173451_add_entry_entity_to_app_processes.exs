defmodule PotokIde.Repo.Migrations.AddEntryEntityToAppProcesses do
  use Ecto.Migration

  # The entity a process drawn in Potok takes when it starts: what a caller
  # hands it, what a signal carries, what someone fills in to start it by
  # hand, or how a value of its collection reads
  # (`PotokIde.Processes.Triggers`). The key takes no action on a delete: an
  # entity a process takes is not deleted (`GroupEntities.delete/3`), and a
  # group that goes takes both along in one statement.
  def change do
    alter table(:app_processes) do
      add :entry_entity_id, references(:group_entities, on_delete: :nothing)
    end

    create index(:app_processes, [:entry_entity_id])
  end
end
