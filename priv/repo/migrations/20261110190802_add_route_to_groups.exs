defmodule PotokIde.Repo.Migrations.AddRouteToGroups do
  use Ecto.Migration

  # A group's place may be a route: a line on the map (one or more parts), as
  # a walk, a race or a bike path runs. Its pin stands at its start, so every
  # query about places still works by the pin. A place is a point, an area or
  # a route, never an area and a route at once.
  #
  # What maps ask of a route, its length, box and width on a map, Postgres
  # keeps with the row, as it does for an area: generated in one statement, so
  # the table is rewritten once.
  def up do
    execute "ALTER TABLE groups ADD COLUMN route geometry(MultiLineString, 4326)"

    execute """
    ALTER TABLE groups
      ADD COLUMN route_length double precision GENERATED ALWAYS AS (ST_Length(route::geography)) STORED,
      ADD COLUMN route_west double precision GENERATED ALWAYS AS (ST_XMin(route)) STORED,
      ADD COLUMN route_south double precision GENERATED ALWAYS AS (ST_YMin(route)) STORED,
      ADD COLUMN route_east double precision GENERATED ALWAYS AS (ST_XMax(route)) STORED,
      ADD COLUMN route_north double precision GENERATED ALWAYS AS (ST_YMax(route)) STORED,
      ADD COLUMN route_span double precision GENERATED ALWAYS AS (
        GREATEST(
          ST_XMax(route) - ST_XMin(route),
          (ST_YMax(route) - ST_YMin(route)) / cos(radians(latitude))
        )
      ) STORED
    """

    create constraint(:groups, :groups_route_check,
             check: "route IS NULL OR (latitude IS NOT NULL AND area IS NULL)"
           )

    # Which routes a map's box shows, and which routes pass through an area.
    execute "CREATE INDEX groups_route_index ON groups USING gist (route) WHERE route IS NOT NULL"

    # Which routes are long enough to draw at a zoom: few at a low one.
    execute "CREATE INDEX groups_route_span_index ON groups (route_span) WHERE route IS NOT NULL"
  end

  def down do
    execute "DROP INDEX groups_route_span_index"
    execute "DROP INDEX groups_route_index"
    drop constraint(:groups, :groups_route_check)

    alter table(:groups) do
      remove :route_span
      remove :route_north
      remove :route_east
      remove :route_south
      remove :route_west
      remove :route_length
      remove :route
    end
  end
end
