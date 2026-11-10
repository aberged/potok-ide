defmodule PotokIde.Social.GroupRoutes do
  @moduledoc """
  Routes on a map (`Group.route`): a group whose place is a line rather than a
  point or an area, as a walk, a race, a march or a bike path runs. A route is
  one or more parts, each an open line of at least two points, in WGS 84
  (PostGIS). It may cross itself or end where it starts, as a loop does.

  A route keeps a pin at its start, the first point of its first part, where
  people meet for a walk or a race (the user's choice, 2026-11-10), so
  whatever works on pins works on routes too. Its end is the last point of its
  last part.

  An area holds a route that passes through it, not only the one that starts
  in it (`GroupAreas.areas_along/3`), and a group has an area or a route,
  never both (`Group.update_changeset/2`, `groups_route_check`).

  What maps ask of a route most, its length in metres, box and width on a
  map, Postgres keeps with the row (`Group.route_length` and the rest).
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, GroupAreas, Profile, Visibility}

  # As for a border: a long track from a watch stays within it once a browser
  # has simplified it; a drawn one stays far below.
  @max_points 10_000
  @max_parts 100
  # Web Mercator ends here, as a map does.
  @max_lat 85.0511287798

  ## A line

  @doc """
  A route from GeoJSON (a decoded `LineString` or `MultiLineString`), as
  `normalize/1` keeps it, or `{:error, reason}`.
  """
  def decode(%{"type" => "LineString", "coordinates" => points}), do: from_lists([points])
  def decode(%{"type" => "MultiLineString", "coordinates" => lines}), do: from_lists(lines)
  def decode(_other), do: {:error, :invalid}

  defp from_lists(lines) when is_list(lines) do
    lines
    |> Enum.map(&lists_line/1)
    |> collect()
    |> case do
      {:ok, lines} -> normalize(%Geo.MultiLineString{coordinates: lines, srid: 4326})
      :error -> {:error, :invalid}
    end
  end

  defp from_lists(_other), do: {:error, :invalid}

  defp lists_line(points) when is_list(points) do
    points
    |> Enum.map(fn
      [x, y | _] when is_number(x) and is_number(y) -> {:ok, {x, y}}
      _other -> :error
    end)
    |> collect()
  end

  defp lists_line(_other), do: :error

  defp collect(results) do
    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, fn {:ok, value} -> value end)},
      else: :error
  end

  @doc """
  A route as it is kept: a `MultiLineString` in WGS 84, each part with at
  least two points and no point twice in a row, coordinates rounded to six
  decimals like a pin's, at most #{@max_points} points in #{@max_parts} parts,
  narrower than half the world (so it never crosses the antimeridian).
  `{:ok, route}` or `{:error, reason}`.
  """
  def normalize(%Geo.LineString{coordinates: points}),
    do: normalize(%Geo.MultiLineString{coordinates: [points]})

  def normalize(%Geo.MultiLineString{coordinates: [_ | _] = lines}) do
    with true <- length(lines) <= @max_parts || {:error, :too_many_parts},
         {:ok, lines} <- lines |> Enum.map(&line/1) |> collect_or_invalid(),
         true <- point_count(lines) <= @max_points || {:error, :too_many_points},
         true <- narrow?(lines) || {:error, :too_wide} do
      {:ok, %Geo.MultiLineString{coordinates: lines, srid: 4326}}
    end
  end

  def normalize(_other), do: {:error, :invalid}

  defp collect_or_invalid(results) do
    case collect(results) do
      {:ok, values} -> {:ok, values}
      :error -> {:error, :invalid}
    end
  end

  defp line(points) when is_list(points) do
    points = points |> Enum.map(&point/1) |> Enum.dedup()

    cond do
      Enum.any?(points, &(&1 == :error)) -> :error
      # With no point twice in a row, two points are two places.
      length(points) >= 2 -> {:ok, points}
      true -> :error
    end
  end

  defp line(_other), do: :error

  defp point({x, y}) when is_number(x) and is_number(y) and abs(x) <= 180 and abs(y) <= @max_lat,
    do: {Float.round(x * 1.0, 6), Float.round(y * 1.0, 6)}

  defp point(_other), do: :error

  defp point_count(lines), do: lines |> Enum.map(&length/1) |> Enum.sum()

  defp narrow?(lines) do
    {min, max} = lines |> Enum.flat_map(& &1) |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    max - min < 180
  end

  @doc "The route as a GeoJSON map, for a browser."
  def to_geojson(%Geo.MultiLineString{coordinates: lines}) do
    %{
      "type" => "MultiLineString",
      "coordinates" => for(line <- lines, do: for({x, y} <- line, do: [x, y]))
    }
  end

  def to_geojson(nil), do: nil

  @doc "Where the route starts, `{lat, lng}`: the first point of its first part."
  def start(%Geo.MultiLineString{coordinates: [[{lng, lat} | _] | _]}), do: {lat, lng}

  @doc """
  Puts the pin at the start of the route a group's changeset holds, when the
  route or the pin changes: a route's pin is always its start, whatever the
  form sent.
  """
  def put_pin(%Ecto.Changeset{valid?: true} = changeset) do
    route = Ecto.Changeset.get_field(changeset, :route)
    touched? = Enum.any?([:route, :latitude, :longitude], &Map.has_key?(changeset.changes, &1))

    if route && touched? do
      {lat, lng} = start(route)

      changeset
      |> Ecto.Changeset.put_change(:latitude, lat)
      |> Ecto.Changeset.put_change(:longitude, lng)
    else
      changeset
    end
  end

  def put_pin(changeset), do: changeset

  @doc """
  How long a route is, in metres along the Earth's surface, as
  `Group.route_length` keeps it for a saved one.
  """
  def meters(%Geo.MultiLineString{} = route) do
    [[meters]] = Repo.query!("SELECT ST_Length($1::geometry::geography)", [route]).rows
    meters
  end

  ## Which routes

  @doc "The fields of a route's box, kept by Postgres (`Group.route_west` and so on)."
  def box_fields, do: [:route_west, :route_south, :route_east, :route_north]

  @doc "A route group's box, `[west, south, east, north]`, when loaded with `box_fields/0`."
  def bbox(%Group{route_west: west, route_south: south, route_east: east, route_north: north}),
    do: [west, south, east, north]

  @doc "A route group's box as a map fits to it, `[[south, west], [north, east]]`."
  def bounds(%Group{} = group) do
    [west, south, east, north] = bbox(group)
    [[south, west], [north, east]]
  end

  @doc """
  The route group `id` if the profile may see it (`Visibility`), with what a
  pin needs, its box (`bbox/1`) and its length; nil otherwise.
  """
  def get_visible(%Profile{} = profile, id) when is_integer(id) do
    Visibility.plain_groups(profile)
    |> where([g], g.id == ^id and not is_nil(g.route) and not g.is_root)
    |> select([g], struct(g, ^(GroupAreas.fields() ++ box_fields() ++ [:route_length])))
    |> Repo.one()
  end
end
