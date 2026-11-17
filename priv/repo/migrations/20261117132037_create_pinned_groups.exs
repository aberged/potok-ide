defmodule PotokIde.Repo.Migrations.CreatePinnedGroups do
  use Ecto.Migration

  # The groups a profile keeps at the top of its column beside a group's page
  # (`PotokIde.Social.PinnedGroups`), in the order it pinned them.
  def change do
    create table(:pinned_groups) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:pinned_groups, [:profile_id, :group_id])
    create index(:pinned_groups, [:group_id])
  end
end
