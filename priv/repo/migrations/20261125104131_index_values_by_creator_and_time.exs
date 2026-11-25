defmodule PotokIde.Repo.Migrations.IndexValuesByCreatorAndTime do
  use Ecto.Migration

  # Built and dropped concurrently, so writes go on meanwhile.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # A profile reads what it wrote, the newest first (`PotokIde.Activity`), over
  # all groups: without the time in the index Postgres reads all of it and
  # sorts (11 ms for an author of 3,000 values on dev, and so on up). The group
  # is there to leave out what the author does not read any more without
  # fetching it.
  #
  # It takes the place of the one on `creator_id`, its leading column, so a
  # value is written into as many indexes as before; none of these columns
  # ever changes, so updates stay HOT.
  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS values_creator_id_is_data_inserted_at_id_index"

    execute """
    CREATE INDEX CONCURRENTLY values_creator_id_is_data_inserted_at_id_index
    ON "values" (creator_id, is_data, inserted_at, id) INCLUDE (group_id)
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS values_creator_id_index"
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS values_creator_id_index"
    execute ~s|CREATE INDEX CONCURRENTLY values_creator_id_index ON "values" (creator_id)|
    execute "DROP INDEX CONCURRENTLY IF EXISTS values_creator_id_is_data_inserted_at_id_index"
  end
end
