defmodule PotokIde.Repo.Migrations.AddFilenameFoldedToValueAttachments do
  use Ecto.Migration

  # A file's name as the files tab's search compares it (`potok_fold/1`:
  # lower-case Latin without diacritics), kept with the row by Postgres.
  # Folding in each search cost ~25-60 µs a file: a search that found nothing
  # among the 3,051 files of the dev database took 74-188 ms, where reading
  # the files without it took 0.1-1 ms.
  def up do
    execute """
    ALTER TABLE value_attachments
      ADD COLUMN filename_folded text GENERATED ALWAYS AS (potok_fold(filename)) STORED
    """
  end

  def down do
    alter table(:value_attachments) do
      remove :filename_folded
    end
  end
end
