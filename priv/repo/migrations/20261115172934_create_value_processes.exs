defmodule PotokIde.Repo.Migrations.CreateValueProcesses do
  use Ecto.Migration

  # An instance of an app's process, one per value of its collection
  # (`PotokIde.Processes.ValueProcess`): the graph it started with, where it
  # stands in it, and when the scheduler wakes it next. Deleting the process
  # or the value takes the instance along; what it wrote stays.
  def change do
    create table(:value_processes) do
      add :app_process_id, references(:app_processes, on_delete: :delete_all), null: false
      add :value_id, references(:values, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "running"
      add :element, :string, null: false
      add :graph, :map, null: false
      add :groups, :map, null: false, default: %{}
      add :started_by_id, references(:profiles, on_delete: :nilify_all)
      # Who set off the step it is on: the value's author, whoever finished a
      # task, or nobody after a timer.
      add :triggered_by_id, references(:profiles, on_delete: :nilify_all)
      add :wake_at, :utc_datetime
      add :steps, :integer, null: false, default: 0
      add :error, :map
      add :log, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    # One instance of a process per value.
    create unique_index(:value_processes, [:app_process_id, :value_id])
    create index(:value_processes, [:value_id])
    create index(:value_processes, [:started_by_id])
    create index(:value_processes, [:triggered_by_id])

    # What the scheduler looks for: the instances due to run.
    create index(:value_processes, [:wake_at], where: "status IN ('running', 'waiting')")

    create constraint(:value_processes, :value_processes_status_check,
             check: "status IN ('running', 'waiting', 'done', 'failed', 'cancelled')"
           )
  end
end
