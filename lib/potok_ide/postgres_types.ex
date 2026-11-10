# The Postgres types the repo knows: Ecto's, plus PostGIS geometries as `Geo`
# structs (`Group.area`). A database without PostGIS simply has no such type.
Postgrex.Types.define(
  PotokIde.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
