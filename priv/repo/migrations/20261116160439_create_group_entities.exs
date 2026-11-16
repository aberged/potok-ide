defmodule PotokIde.Repo.Migrations.CreateGroupEntities do
  use Ecto.Migration

  # The entities a group's editors define for the processes drawn in it
  # (`PotokIde.Processes.GroupEntities`): a name, once in the group in any
  # letter case, and its attributes, each with the type of what it holds.
  # Deleting the group takes them along.
  def change do
    create table(:group_entities) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :attributes, :map, null: false, default: fragment("'[]'::jsonb")
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_entities, [:group_id, "lower(name)"],
             name: :group_entities_group_id_name_index
           )

    create constraint(:group_entities, :group_entities_name_check,
             check: "char_length(name) BETWEEN 1 AND 40"
           )

    create constraint(:group_entities, :group_entities_attributes_check,
             check: "jsonb_typeof(attributes) = 'array'"
           )
  end
end
