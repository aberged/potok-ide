defmodule PotokIde.Repo.Migrations.CreateProfileBlocks do
  use Ecto.Migration

  # A profile that blocked another (`PotokIde.Social.ProfileBlock`): neither
  # writes in their direct conversation any more, nor opens a new one. A
  # profile is never deleted, so a deleted account removes its rows itself
  # (`PotokIde.Accounts.Deletion`). History never follows this table: it is
  # one person's choice, not a group's.
  def change do
    create table(:profile_blocks) do
      add :blocker_id, references(:profiles, on_delete: :delete_all), null: false
      add :blocked_id, references(:profiles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Leads with blocker_id, so it also lists whom a profile blocked.
    create unique_index(:profile_blocks, [:blocker_id, :blocked_id])
    create index(:profile_blocks, [:blocked_id])

    create constraint(:profile_blocks, :profile_blocks_not_self,
             check: "blocker_id <> blocked_id"
           )
  end
end
