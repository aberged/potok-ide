defmodule PotokIde.Repo.Migrations.AddTextFoldedToGroups do
  use Ecto.Migration

  # A group's description as a search compares it (`potok_fold/1` of its text,
  # without HTML comments and tags, spaces run together), kept with the row by
  # Postgres, as a site's search box looks through its articles
  # (`Social.search_visible_children/4`). Folding in each search took 9.7 s
  # for 2,000 articles of 10 KB; read from here, 3 to 24 ms. A save pays it
  # once, some 5 ms for such an article. A group that is an app keeps it empty:
  # its description is code.
  def up do
    execute """
    ALTER TABLE groups
      ADD COLUMN text_folded text
      GENERATED ALWAYS AS (
        CASE WHEN uses_api THEN NULL ELSE
          potok_fold(
            regexp_replace(
              regexp_replace(
                regexp_replace(coalesce(description, ''), '<!--.*?-->', ' ', 'g'),
                '<[^>]*>', ' ', 'g'
              ),
              '\\s+', ' ', 'g'
            )
          )
        END
      ) STORED
    """
  end

  def down do
    alter table(:groups) do
      remove :text_folded
    end
  end
end
