defmodule PotokIde.Repo.Migrations.CreateGroupShortcuts do
  use Ecto.Migration

  # A shortcut stands in a group (`parent_id`) as one of its sub-groups and
  # opens another group (`target_id`), wherever that one stands in the tree,
  # as a shortcut does on a computer. It is not a group: it has no members,
  # values or counts of its own. Deleting either group takes it away.
  def change do
    create table(:group_shortcuts) do
      add :parent_id, references(:groups, on_delete: :delete_all), null: false
      add :target_id, references(:groups, on_delete: :delete_all), null: false
      add :creator_id, references(:profiles, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # One shortcut to a group in each group; the lists read it by its parent.
    create unique_index(:group_shortcuts, [:parent_id, :target_id])
    # Deleting or changing a group finds the groups that hold its shortcuts.
    create index(:group_shortcuts, [:target_id])
    create index(:group_shortcuts, [:creator_id])

    create constraint(:group_shortcuts, :group_shortcuts_not_self_check,
             check: "parent_id <> target_id"
           )
  end
end
