defmodule PotokIde.Repo.Migrations.CreateGroupTemplates do
  use Ecto.Migration

  # Templates of a group's own for descriptions (`PotokIde.Social.GroupTemplate`):
  # a form's fields and an HTML template. They serve the group and every group
  # below it, and go with the group.
  def change do
    create table(:group_templates) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      add :name, :string, null: false
      add :purpose, :string, null: false, default: ""
      add :fields, {:array, :map}, null: false, default: []
      add :html, :text, null: false, default: ""
      # Grows with every save, so a post says which version made it.
      add :rev, :integer, null: false, default: 1
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:group_templates, [:group_id, :position])
    create index(:group_templates, [:creator_id])

    create unique_index(:group_templates, [:group_id, "lower(name)"],
             name: :group_templates_group_id_lower_name_index
           )
  end
end
