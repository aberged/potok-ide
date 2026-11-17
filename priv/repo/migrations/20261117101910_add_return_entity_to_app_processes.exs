defmodule PotokIde.Repo.Migrations.AddReturnEntityToAppProcesses do
  use Ecto.Migration

  # The entity a process drawn in Potok hands back to the process that
  # called it, which each of its ends fills in (`Processes.Engine`). Cleared
  # when the entity goes, as the entity it takes is; an entity a drawing
  # names is not deleted in the first place (`GroupEntities.delete/3`).
  def change do
    alter table(:app_processes) do
      add :return_entity_id, references(:group_entities, on_delete: :nilify_all)
    end

    create index(:app_processes, [:return_entity_id])
  end
end
