defmodule PotokIde.Repo.Migrations.AddAreaToGroups do
  use Ecto.Migration

  # A group's place may be an area: a border on the map (one or more polygons).
  # It keeps its pin, a point inside the area, so every query about places
  # still works by the pin, and an area holds a group when it holds its pin.
  #
  # In production PostGIS is turned on for the database beforehand (Fly's
  # Managed Postgres does it from its dashboard), and this line finds it.
  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"

    execute "ALTER TABLE groups ADD COLUMN area geometry(MultiPolygon, 4326)"

    create constraint(:groups, :groups_area_check, check: "area IS NULL OR latitude IS NOT NULL")

    # Which areas cover a point, and which areas a map's box shows.
    execute "CREATE INDEX groups_area_index ON groups USING gist (area) WHERE area IS NOT NULL"

    # Which pins lie inside an area.
    execute """
    CREATE INDEX groups_pin_index ON groups
    USING gist ((ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)))
    WHERE latitude IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX groups_pin_index"
    execute "DROP INDEX groups_area_index"
    drop constraint(:groups, :groups_area_check)

    alter table(:groups) do
      remove :area
    end
  end
end
