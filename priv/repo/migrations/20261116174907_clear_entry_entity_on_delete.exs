defmodule PotokIde.Repo.Migrations.ClearEntryEntityOnDelete do
  use Ecto.Migration

  # The entity a process takes is cleared when the entity goes, as a group
  # field's process is, rather than held with no action: a key that takes no
  # action reads as one that blocks, and deleting a group, which takes its
  # entities and its processes along together, is blocked by neither. An
  # entity a process takes is not deleted in the first place
  # (`GroupEntities.delete/3`).
  def change do
    alter table(:app_processes) do
      modify :entry_entity_id, references(:group_entities, on_delete: :nilify_all),
        from: references(:group_entities, on_delete: :nothing)
    end
  end
end
