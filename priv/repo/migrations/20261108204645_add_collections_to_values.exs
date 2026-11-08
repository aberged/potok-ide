defmodule PotokIde.Repo.Migrations.AddCollectionsToValues do
  use Ecto.Migration

  # Collections of app data values and the rules over them
  # (`PotokIde.Social.AppData`). Every column is nullable or has a constant
  # default, so the table is not rewritten and older code keeps working.
  def change do
    alter table(:values) do
      # The collection of an app's data value; nil for chat values and for
      # app values written without one, which keep the old behaviour.
      add :collection, :string, size: 40
      # Set when the collection was anonymous at the time of writing, and never
      # changed, so turning anonymity off later reveals nobody.
      add :anonymous, :boolean, null: false, default: false
      # Optimistic lock of in-place updates, given to apps as `revision`.
      add :lock_version, :integer, null: false, default: 0
      # What the server and the app's editors add to a value: a quiz score
      # and grades. The author never writes it.
      add :managed, :map
    end

    # Added without a scan of the table; the next migration validates it.
    create constraint(:values, :values_collection_check,
             check: "collection IS NULL OR (is_data AND collection ~ '^[a-z][a-z0-9_-]{0,39}$')",
             validate: false
           )
  end
end
