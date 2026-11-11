defmodule PotokIde.Repo.Migrations.AddShapeToGroupEvents do
  use Ecto.Migration

  # An event's place of its own may also be an area or a route, as a group's
  # is: a border or a line on the map, which keeps the event's pin (inside the
  # area, at the route's start). Never both, and never without the pin.
  def change do
    execute "ALTER TABLE group_events ADD COLUMN area geometry(MultiPolygon, 4326)",
            "ALTER TABLE group_events DROP COLUMN area"

    execute "ALTER TABLE group_events ADD COLUMN route geometry(MultiLineString, 4326)",
            "ALTER TABLE group_events DROP COLUMN route"

    create constraint(:group_events, :group_events_shape_check,
             check: """
             (area IS NULL OR latitude IS NOT NULL) AND \
             (route IS NULL OR (latitude IS NOT NULL AND area IS NULL))\
             """
           )
  end
end
