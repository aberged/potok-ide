defmodule PotokIde.Repo.Migrations.AddAsksToValueProcesses do
  use Ecto.Migration

  # Whom a run asks while it waits on a step a person finishes
  # (`PotokIde.Processes.Engine`): the people of a role (`asks_role`), for a
  # decision or a form, or one person (`asks_profile_id`), for a form that
  # whoever started the run fills in. Both are written on every entry into a
  # wait, empty for a wait no person ends, and say nothing in any other
  # state. So a group's page counts what waits for its viewer without reading
  # the graph of every waiting run.
  def up do
    alter table(:value_processes) do
      add :asks_role, :string
      add :asks_profile_id, references(:profiles, on_delete: :nilify_all)
    end

    create index(:value_processes, [:app_process_id, :asks_role, :asks_profile_id],
             name: :value_processes_asks_index,
             where:
               "status = 'waiting' AND (asks_role IS NOT NULL OR asks_profile_id IS NOT NULL)"
           )

    create index(:value_processes, [:asks_profile_id], where: "asks_profile_id IS NOT NULL")

    # The decisions that wait already.
    execute """
    UPDATE value_processes AS i
    SET asks_role =
      jsonb_path_query_first(
        i.graph,
        '$.nodes[*] ? (@.id == $e && @.type == "userTask")',
        jsonb_build_object('e', i.element)
      ) ->> 'role'
    WHERE i.status = 'waiting'
    """
  end

  def down do
    drop index(:value_processes, [:asks_profile_id])

    drop index(:value_processes, [:app_process_id, :asks_role, :asks_profile_id],
           name: :value_processes_asks_index
         )

    alter table(:value_processes) do
      remove :asks_profile_id
      remove :asks_role
    end
  end
end
