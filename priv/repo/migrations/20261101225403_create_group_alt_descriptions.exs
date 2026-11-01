defmodule PotokIde.Repo.Migrations.CreateGroupAltDescriptions do
  use Ecto.Migration

  def change do
    # A group's default description stays on `groups`; these are the extra
    # ones (text or apps) shown next to it.
    create table(:group_alt_descriptions) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :description_format, :string, null: false, default: "markdown"
      add :uses_api, :boolean, null: false, default: false
      # Empty: visible to everyone who sees the group's description.
      add :visible_role_keys, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      add :creator_id, references(:profiles, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:group_alt_descriptions, [:group_id, :position])
    create index(:group_alt_descriptions, [:creator_id])

    create unique_index(:group_alt_descriptions, [:group_id, "lower(name)"],
             name: :group_alt_descriptions_group_id_lower_name_index
           )

    # Target of the composite reference from `values`, which keeps an app's
    # data in the app's own group.
    create unique_index(:group_alt_descriptions, [:id, :group_id])

    create constraint(:group_alt_descriptions, :group_alt_descriptions_description_format_check,
             check: "description_format IN ('markdown', 'html')"
           )
  end
end
