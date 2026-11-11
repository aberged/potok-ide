defmodule PotokIde.Repo.Migrations.AddContentFoldedToValues do
  use Ecto.Migration

  # A chat value's text as a search compares it (`potok_fold/1`: lower-case
  # Latin without diacritics), kept with the row by Postgres. Folding in each
  # search cost ~40 µs a value, 2 s for a group of 100,000; read from here, a
  # search that finds nothing in such a group took ~30 ms, and one that finds
  # enough stops at the newest. App data values are not searched and keep it
  # empty.
  def up do
    execute """
    ALTER TABLE values
      ADD COLUMN content_folded text
      GENERATED ALWAYS AS (CASE WHEN is_data THEN NULL ELSE potok_fold(content) END) STORED
    """
  end

  def down do
    alter table(:values) do
      remove :content_folded
    end
  end
end
