defmodule PotokIde.Repo.Migrations.AddTrigramIndexes do
  use Ecto.Migration

  # Built concurrently, so writes go on while they are built.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Searches across a whole table by any part of a name, from three
  # characters on (`Social.NameSearch.wide_term/1`): people to invite and to
  # mention by username; groups by their folded name (shortcuts, the root's
  # map, places, the area menu); public tags by name.
  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS profiles_username_trgm_index
    ON profiles USING gin (username gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS groups_name_folded_trgm_index
    ON groups USING gin (name_folded gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS tags_public_name_trgm_index
    ON tags USING gin (lower(name) gin_trgm_ops)
    WHERE owner_id IS NULL
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS tags_public_name_trgm_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS groups_name_folded_trgm_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS profiles_username_trgm_index"
  end
end
