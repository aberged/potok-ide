defmodule PotokIde.Repo.Migrations.GeneralizeProcessTriggers do
  use Ecto.Migration

  # A process drawn in Potok may start on more than a new value of an app's
  # collection (`PotokIde.Processes.Triggers`): a chat message, a new
  # sub-group, a schedule, or someone starting it by hand. Only a process on
  # a collection has one; an app's own process always does. An instance's
  # subject is then a value, a group, or nothing, and `data` keeps the fields
  # its texts read.
  def up do
    alter table(:app_processes) do
      add :trigger, :string, null: false, default: "value"
      add :trigger_config, :map, null: false, default: %{}
      # When a scheduled process starts next; nil for every other trigger.
      add :next_run_at, :utc_datetime
      modify :collection, :string, null: true, from: {:string, null: false}
    end

    create constraint(:app_processes, :app_processes_trigger_check,
             check: "trigger IN ('value', 'message', 'subgroup', 'schedule', 'manual')"
           )

    create constraint(:app_processes, :app_processes_trigger_collection_check,
             check: "(trigger = 'value') = (collection IS NOT NULL)"
           )

    create index(:app_processes, [:group_id, :trigger],
             where: "drawn AND active",
             name: :app_processes_drawn_trigger_index
           )

    create index(:app_processes, [:next_run_at], where: "next_run_at IS NOT NULL")

    alter table(:value_processes) do
      modify :value_id, :bigint, null: true, from: {:bigint, null: false}
      # The new sub-group that set it going, for a process on new sub-groups.
      add :subject_group_id, references(:groups, on_delete: :delete_all)
      # The fields its texts and conditions read when the subject is no value
      # of a collection: a message's text, a form's title, a scheduled date.
      add :data, :map, null: false, default: %{}
    end

    create unique_index(:value_processes, [:app_process_id, :subject_group_id],
             where: "subject_group_id IS NOT NULL"
           )

    create index(:value_processes, [:subject_group_id], where: "subject_group_id IS NOT NULL")
  end

  def down do
    execute "DELETE FROM value_processes WHERE value_id IS NULL"
    execute "DELETE FROM app_processes WHERE trigger <> 'value'"

    drop index(:value_processes, [:subject_group_id], where: "subject_group_id IS NOT NULL")
    drop index(:value_processes, [:app_process_id, :subject_group_id])

    alter table(:value_processes) do
      remove :data
      remove :subject_group_id
      modify :value_id, :bigint, null: false, from: {:bigint, null: true}
    end

    drop index(:app_processes, [:next_run_at])
    drop index(:app_processes, [:group_id, :trigger], name: :app_processes_drawn_trigger_index)
    drop constraint(:app_processes, :app_processes_trigger_collection_check)
    drop constraint(:app_processes, :app_processes_trigger_check)

    alter table(:app_processes) do
      modify :collection, :string, null: false, from: {:string, null: true}
      remove :next_run_at
      remove :trigger_config
      remove :trigger
    end
  end
end
