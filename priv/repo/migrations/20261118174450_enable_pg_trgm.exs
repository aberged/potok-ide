defmodule PotokIde.Repo.Migrations.EnablePgTrgm do
  use Ecto.Migration

  # Trigrams, so a search by any part of a name can use an index
  # (`AddTrigramIndexes`). On Fly Managed Postgres the extension is enabled
  # beforehand (`fly mpg databases extensions enable <cluster> pg_trgm -d
  # <db>`), as PostGIS was; here it is then already there.
  def up, do: execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

  # Left in place: other databases on the cluster may use it.
  def down, do: :ok
end
