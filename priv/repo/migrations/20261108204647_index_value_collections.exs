defmodule PotokIde.Repo.Migrations.IndexValueCollections do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Validating takes no lock that stops writes, unlike adding a checked constraint.
    execute ~s(ALTER TABLE "values" VALIDATE CONSTRAINT values_collection_check)

    # The values of one collection of one app, newest or oldest first, and the
    # newest config of an app.
    create index(:values, [:group_id, :collection, :alt_description_id, :id],
             where: "collection IS NOT NULL",
             name: :values_collection_id_index,
             concurrently: true
           )

    # The hourly sweep of files apps took in that no value claimed.
    create index(:values, [:inserted_at],
             where: "collection = 'files'",
             name: :values_app_files_inserted_at_index,
             concurrently: true
           )
  end

  def down do
    drop index(:values, [:inserted_at],
           name: :values_app_files_inserted_at_index,
           concurrently: true
         )

    drop index(:values, [:group_id, :collection, :alt_description_id, :id],
           name: :values_collection_id_index,
           concurrently: true
         )
  end
end
