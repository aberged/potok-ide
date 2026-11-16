defmodule PotokIde.Repo.Migrations.CreateGroupFields do
  use Ecto.Migration

  # Fields the processes drawn in a group keep for each other
  # (`PotokIde.Processes.GroupFields`): a step sets one, or adds to it, and
  # every process of the group reads it as `{{group.name}}`. Deleting the
  # group takes them along; the process that wrote one last may go first.
  def change do
    create table(:group_fields) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :value, :text, null: false, default: ""
      add :app_process_id, references(:app_processes, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_fields, [:group_id, :name])
    create index(:group_fields, [:app_process_id])

    create constraint(:group_fields, :group_fields_name_check,
             check: "char_length(name) BETWEEN 1 AND 40"
           )

    create constraint(:group_fields, :group_fields_value_check,
             check: "char_length(value) <= 1000"
           )
  end
end
