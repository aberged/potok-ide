defmodule PotokIde.Repo.Migrations.AddPublishedAtToGroups do
  use Ecto.Migration

  def change do
    # When a closed group last opened up. Empty otherwise, and then its
    # `inserted_at` is what counts.
    alter table(:groups) do
      add :published_at, :utc_datetime
    end
  end
end
