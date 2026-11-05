defmodule PotokIde.Repo.Migrations.CreateGroupReactions do
  use Ecto.Migration

  def change do
    create table(:group_reactions) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Leads with group_id, so it also serves loading a group's reactions.
    create unique_index(:group_reactions, [:group_id, :profile_id, :emoji],
             name: :group_reactions_group_id_profile_id_emoji_index
           )

    create index(:group_reactions, [:profile_id])
  end
end
