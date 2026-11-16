defmodule PotokIde.Repo.Migrations.AddProcessCalls do
  use Ecto.Migration

  # Processes drawn in Potok talk to each other (`PotokIde.Processes.Engine`):
  # one calls another and may wait for it, or sends a signal that wakes those
  # waiting for it and starts those that start on it. A run another process
  # started is one level deeper than that one (`depth`), so a loop stops; it
  # may share its subject with the run that started it, so a value or a
  # sub-group has at most one instance of each process only among the runs
  # nothing but their trigger started. `awaiting_id` is the run a caller
  # waits for, and `results` what its waits brought back, by element.
  def up do
    alter table(:value_processes) do
      add :awaiting_id, references(:value_processes, on_delete: :nilify_all)
      add :depth, :integer, null: false, default: 0
      add :results, :map, null: false, default: %{}
    end

    create constraint(:value_processes, :value_processes_depth_check, check: "depth >= 0")
    create index(:value_processes, [:awaiting_id], where: "awaiting_id IS NOT NULL")

    # The unique index below no longer covers every row, so the lists and
    # counts of a process's instances get an index of their own.
    create index(:value_processes, [:app_process_id, :status])

    drop index(:value_processes, [:app_process_id, :value_id])

    drop index(:value_processes, [:app_process_id, :subject_group_id],
           where: "subject_group_id IS NOT NULL"
         )

    create unique_index(:value_processes, [:app_process_id, :value_id], where: "depth = 0")

    create unique_index(:value_processes, [:app_process_id, :subject_group_id],
             where: "depth = 0"
           )

    drop constraint(:app_processes, :app_processes_trigger_check)

    create constraint(:app_processes, :app_processes_trigger_check,
             check:
               "trigger IN ('value', 'message', 'subgroup', 'schedule', 'manual', 'process', 'signal')"
           )
  end

  def down do
    execute "DELETE FROM app_processes WHERE trigger IN ('process', 'signal')"
    execute "DELETE FROM value_processes WHERE depth > 0"

    drop constraint(:app_processes, :app_processes_trigger_check)

    create constraint(:app_processes, :app_processes_trigger_check,
             check: "trigger IN ('value', 'message', 'subgroup', 'schedule', 'manual')"
           )

    drop index(:value_processes, [:app_process_id, :subject_group_id])
    drop index(:value_processes, [:app_process_id, :value_id])

    create unique_index(:value_processes, [:app_process_id, :subject_group_id],
             where: "subject_group_id IS NOT NULL"
           )

    create unique_index(:value_processes, [:app_process_id, :value_id])

    drop index(:value_processes, [:app_process_id, :status])
    drop index(:value_processes, [:awaiting_id])
    drop constraint(:value_processes, :value_processes_depth_check)

    alter table(:value_processes) do
      remove :results
      remove :depth
      remove :awaiting_id
    end
  end
end
