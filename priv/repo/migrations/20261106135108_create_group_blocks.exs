defmodule PotokIde.Repo.Migrations.CreateGroupBlocks do
  use Ecto.Migration

  def up do
    create table(:group_blocks) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :blocked_by_id, references(:profiles, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Leads with group_id, so it also serves listing a group's blocks.
    create unique_index(:group_blocks, [:group_id, :profile_id])
    create index(:group_blocks, [:profile_id])
    create index(:group_blocks, [:blocked_by_id])

    # The field meant nothing since it left the form, so a group may still hold
    # true from then. From now on it opens the chat, which only an admin does.
    # Direct conversations hold true and are never public, so they stay as they are.
    execute "UPDATE groups SET has_public_chat = false WHERE has_public_chat AND NOT is_direct"
  end

  def down do
    drop table(:group_blocks)
  end
end
