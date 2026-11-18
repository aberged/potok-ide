defmodule PotokIde.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  # Oban's table of background jobs (push deliveries), at the schema version
  # of the Oban this release uses.
  def up, do: Oban.Migration.up(version: 14)

  def down, do: Oban.Migration.down(version: 1)
end
