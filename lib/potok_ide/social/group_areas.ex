defmodule PotokIde.Social.GroupAreas do
  @moduledoc """
  Areas on a map (`Group.area`): a group whose place is an area rather than a
  point, as a local community covers its streets. An area is a border of one
  or more polygons, each of which may have holes, in WGS 84 (PostGIS).

  An area keeps a pin, a point well inside it (`pin_inside/1`), so whatever
  works on pins works on areas too, and an area holds a group when it holds
  the group's pin: a point, or for another area the point inside that one,
  as long as that other area is the smaller one (a city's pin may well fall
  inside one of its quarters, which does not hold the city).

  An area is seen by whoever may see its group (`Visibility`): its members
  and, for a public group, every signed-in profile. On the root's map an area
  is only the shape of its group: the filters keep it or leave it out like
  any group (the user's choice, 2026-11-10).

  What maps ask of an area most, its size, box and width on a map, Postgres
  keeps with the row (`Group.area_size` and the rest), so no query reads a
  whole border for them.

  A route (`GroupRoutes`) lies in every area it passes through, not only in
  the one its pin, its start, stands in (the user's choice, 2026-11-10):
  `areas_along/3`. Maps get the lines of routes here too (`shapes/4`), as
  they get borders.
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{AreaShapes, Group, NameSearch, Profile, Visibility}

  # Big enough for an official border; a drawn one stays far below.
  @max_points 10_000
  @max_parts 100
  # Web Mercator ends here, as a map does.
  @max_lat 85.0511287798

  # An area is drawn as a border once it is this wide on the screen, two pins
  # wide, so that its border shows around the pin; below it, only its pin.
  # Its pin stays among the others either way.
  @drawn_px 64

  # The levels of detail a map asks borders at: a border simplified for level
  # z stays within ~0.75 px of the real one at zoom z.
  @levels [6, 8, 10, 12, 14, 16]

  # What a pin needs (`GroupPins`), as `Social.list_visible_placed_children/3`
  # loads it.
  @fields [
    :id,
    :parent_id,
    :name,
    :latitude,
    :longitude,
    :pin_icon,
    :preset,
    :uses_api,
    :is_public,
    :inherits_members,
    :updated_at
  ]

  ## A border

  @doc """
  A border from GeoJSON (a decoded `Polygon` or `MultiPolygon`), as
  `normalize/1` keeps it, or `{:error, reason}`.
  """
  def decode(%{"type" => "Polygon", "coordinates" => rings}), do: from_lists([rings])
  def decode(%{"type" => "MultiPolygon", "coordinates" => polygons}), do: from_lists(polygons)
  def decode(_other), do: {:error, :invalid}

  defp from_lists(polygons) when is_list(polygons) do
    polygons
    |> Enum.map(&lists_polygon/1)
    |> collect()
    |> case do
      {:ok, polygons} -> normalize(%Geo.MultiPolygon{coordinates: polygons, srid: 4326})
      :error -> {:error, :invalid}
    end
  end

  defp from_lists(_other), do: {:error, :invalid}

  defp lists_polygon(rings) when is_list(rings) do
    rings |> Enum.map(&lists_ring/1) |> collect()
  end

  defp lists_polygon(_other), do: :error

  defp lists_ring(points) when is_list(points) do
    points
    |> Enum.map(fn
      [x, y | _] when is_number(x) and is_number(y) -> {:ok, {x, y}}
      _other -> :error
    end)
    |> collect()
  end

  defp lists_ring(_other), do: :error

  defp collect(results) do
    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(results, fn {:ok, value} -> value end)},
      else: :error
  end

  @doc """
  A border as it is kept: a `MultiPolygon` in WGS 84, each ring closed, with
  at least three corners and no point twice in a row, coordinates rounded to
  six decimals like a pin's, at most #{@max_points} points in #{@max_parts}
  polygons, narrower than half the world (so it never crosses the
  antimeridian). `{:ok, area}` or `{:error, reason}`; whether its rings cross
  is for the database to say (`pin_inside/1`).
  """
  def normalize(%Geo.Polygon{coordinates: rings}),
    do: normalize(%Geo.MultiPolygon{coordinates: [rings]})

  def normalize(%Geo.MultiPolygon{coordinates: [_ | _] = polygons}) do
    with true <- length(polygons) <= @max_parts || {:error, :too_many_parts},
         {:ok, polygons} <- polygons |> Enum.map(&polygon/1) |> collect_or_invalid(),
         true <- point_count(polygons) <= @max_points || {:error, :too_many_points},
         true <- narrow?(polygons) || {:error, :too_wide} do
      {:ok, %Geo.MultiPolygon{coordinates: polygons, srid: 4326}}
    end
  end

  def normalize(_other), do: {:error, :invalid}

  defp collect_or_invalid(results) do
    case collect(results) do
      {:ok, values} -> {:ok, values}
      :error -> {:error, :invalid}
    end
  end

  defp polygon([_ | _] = rings), do: rings |> Enum.map(&ring/1) |> collect()
  defp polygon(_other), do: :error

  defp ring(points) when is_list(points) do
    points =
      points
      |> Enum.map(&point/1)
      |> Enum.dedup()

    cond do
      Enum.any?(points, &(&1 == :error)) -> :error
      true -> close(points)
    end
  end

  defp ring(_other), do: :error

  defp point({x, y}) when is_number(x) and is_number(y) and abs(x) <= 180 and abs(y) <= @max_lat,
    do: {Float.round(x * 1.0, 6), Float.round(y * 1.0, 6)}

  defp point(_other), do: :error

  defp close([first | _] = points) do
    points = if List.last(points) == first, do: points, else: points ++ [first]
    # Three corners and the first one again.
    if length(points) >= 4 and length(Enum.uniq(points)) >= 3, do: {:ok, points}, else: :error
  end

  defp close([]), do: :error

  defp point_count(polygons),
    do: polygons |> Enum.flat_map(& &1) |> Enum.map(&length/1) |> Enum.sum()

  defp narrow?(polygons) do
    {min, max} =
      polygons
      |> Enum.flat_map(fn rings -> Enum.flat_map(rings, & &1) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.min_max()

    max - min < 180
  end

  @doc "The border as a GeoJSON map, for a browser."
  def to_geojson(%Geo.MultiPolygon{coordinates: polygons}) do
    %{
      "type" => "MultiPolygon",
      "coordinates" =>
        for rings <- polygons do
          for ring <- rings, do: for({x, y} <- ring, do: [x, y])
        end
    }
  end

  def to_geojson(nil), do: nil

  @doc """
  A point well inside the area, where its pin stands: the centre of the
  biggest circle that fits in it, so even a long or bent area gets a point
  inside rather than its middle. `{:ok, {lat, lng}}`, or `{:error,
  :crosses_itself}` for a border PostGIS does not take as valid (its lines
  cross, or its parts overlap).
  """
  def pin_inside(%Geo.MultiPolygon{} = area) do
    case Repo.query!("SELECT ST_IsValid($1::geometry)", [area]).rows do
      [[true]] ->
        [[lng, lat]] =
          Repo.query!(
            """
            SELECT ST_X(c), ST_Y(c)
            FROM (SELECT (ST_MaximumInscribedCircle($1::geometry)).center AS c) s
            """,
            [area]
          ).rows

        {:ok, {Float.round(lat, 6), Float.round(lng, 6)}}

      _invalid ->
        {:error, :crosses_itself}
    end
  end

  @doc """
  Puts the pin inside the area a group's changeset holds, when the area or
  the pin changes: an area's pin is always its own point inside it, whatever
  the form sent. A border PostGIS does not take gets an error instead.
  """
  def put_pin(%Ecto.Changeset{valid?: true} = changeset) do
    area = Ecto.Changeset.get_field(changeset, :area)
    touched? = Enum.any?([:area, :latitude, :longitude], &Map.has_key?(changeset.changes, &1))

    if area && touched? do
      case pin_inside(area) do
        {:ok, {lat, lng}} ->
          changeset
          |> Ecto.Changeset.put_change(:latitude, lat)
          |> Ecto.Changeset.put_change(:longitude, lng)

        {:error, reason} ->
          Ecto.Changeset.add_error(changeset, :area, Group.area_error(reason))
      end
    else
      changeset
    end
  end

  def put_pin(changeset), do: changeset

  ## Which areas

  # The areas a profile may see (`Visibility`): its groups' and the public
  # groups' (the root has no place at all).
  defp visible(%Profile{} = profile) do
    Visibility.plain_groups(profile)
    |> where([g], not is_nil(g.area) and not g.is_root)
  end

  @doc "What a pin needs of a group, as maps load it."
  def fields, do: @fields

  @doc "The fields of an area's box, kept by Postgres (`Group.area_west` and so on)."
  def box_fields, do: [:area_west, :area_south, :area_east, :area_north]

  @doc "An area group's box, `[west, south, east, north]`, when loaded with `box_fields/0`."
  def bbox(%Group{area_west: west, area_south: south, area_east: east, area_north: north}),
    do: [west, south, east, north]

  @doc """
  How wide (in degrees of longitude, as `Group.area_span` measures it) an area
  must be to be drawn as a border at `zoom` rather than as a pin.
  """
  def min_span(zoom) when is_integer(zoom),
    do: @drawn_px * 360.0 / (256.0 * Integer.pow(2, zoom |> max(0) |> min(24)))

  @doc """
  The areas the profile may see that cover the point, smallest first, as
  groups with what a pin needs. Options: `:except` leaves one group out,
  `:zoom` keeps only the areas drawn as borders at that zoom (`min_span/1`),
  `:larger_than` only those bigger than an area of that size (`size/1`), as
  only a bigger area holds another, `:limit` (10).
  """
  def areas_at(%Profile{} = profile, lat, lng, opts \\ [])
      when is_number(lat) and is_number(lng) do
    visible(profile)
    |> where(
      [g],
      fragment(
        "ST_Intersects(?, ST_SetSRID(ST_MakePoint(?::float8, ?::float8), 4326))",
        g.area,
        ^(lng * 1.0),
        ^(lat * 1.0)
      )
    )
    |> except_id(opts[:except])
    |> drawn_at(opts[:zoom])
    |> larger_than(opts[:larger_than])
    |> order_by([g], asc: g.area_size, asc: g.id)
    |> limit(^Keyword.get(opts, :limit, 10))
    |> select([g], struct(g, ^@fields))
    |> Repo.all()
  end

  defp except_id(query, nil), do: query
  defp except_id(query, id), do: where(query, [g], g.id != ^id)

  defp drawn_at(query, nil), do: query
  defp drawn_at(query, zoom), do: where(query, [g], g.area_span >= ^min_span(zoom))

  defp larger_than(query, nil), do: query
  defp larger_than(query, size), do: where(query, [g], g.area_size > ^(size * 1.0))

  @doc """
  How big an area is, in square degrees: enough to tell which of two areas
  is the bigger one, which is all it is used for (`Group.area_size` keeps it
  for a saved one).
  """
  def size(%Geo.MultiPolygon{} = area) do
    [[size]] = Repo.query!("SELECT ST_Area($1::geometry)", [area]).rows
    size
  end

  @doc """
  What kind of place the group has: `:none`, `:point`, `{:area, size}` with
  its size (`size/1`), or `{:route, meters}` with its length.
  """
  def place_kind(%Group{id: id} = group) do
    if Group.placed?(group) do
      from(g in Group, where: g.id == ^id, select: {g.area_size, g.route_length})
      |> Repo.one()
      |> case do
        {size, _length} when is_number(size) -> {:area, size}
        {_size, meters} when is_number(meters) -> {:route, meters}
        _point -> :point
      end
    else
      :none
    end
  end

  @doc """
  The areas the profile may see that hold the group, smallest first: where
  the group is. A point or an area lies in the areas that hold its pin (a
  bigger one, for an area), a route in the areas it passes through. None for
  a group without a place. `kind` is the group's `place_kind/1`, when known.
  """
  def containing(%Profile{} = profile, %Group{} = group, kind \\ nil) do
    case kind || place_kind(group) do
      :none ->
        []

      :point ->
        areas_at(profile, group.latitude, group.longitude, except: group.id)

      {:area, size} ->
        areas_at(profile, group.latitude, group.longitude, except: group.id, larger_than: size)

      {:route, _meters} ->
        areas_along(profile, group, except: group.id)
    end
  end

  @doc """
  The areas the profile may see that a route passes through, smallest first,
  as groups with what a pin needs: a route not yet saved
  (`%Geo.MultiLineString{}`), or a saved route group, whose line is never
  loaded for it. Options: `:except` leaves one group out, `:limit` (10).
  """
  def areas_along(profile, route, opts \\ [])

  def areas_along(%Profile{} = profile, %Geo.MultiLineString{} = route, opts) do
    visible(profile)
    |> where([g], fragment("ST_Intersects(?, ?)", g.area, type(^route, Geo.PostGIS.Geometry)))
    |> along(opts)
  end

  def areas_along(%Profile{} = profile, %Group{id: id}, opts) do
    visible(profile)
    |> join(:inner, [g], r in Group,
      on: r.id == ^id and fragment("ST_Intersects(?, ?)", g.area, r.route)
    )
    |> along(opts)
  end

  defp along(query, opts) do
    query
    |> except_id(opts[:except])
    |> order_by([g], asc: g.area_size, asc: g.id)
    |> limit(^Keyword.get(opts, :limit, 10))
    |> select([g], struct(g, ^@fields))
    |> Repo.all()
  end

  @doc "The level of detail (`@levels`) a map at `zoom` asks borders at."
  def level(zoom) when is_integer(zoom), do: Enum.find(@levels, 16, &(&1 >= zoom))

  @doc """
  What a map of `places` (groups the profile was already given) needs of
  their shapes: the box of each area among them, the box and length of each
  route, and for each place the areas among them that hold it, smallest
  first, by the rule of `containing/2` (a route lies in the areas it passes
  through). `%{boxes: %{id => [west, south, east, north]}, routes: %{id =>
  %{bbox, length}}, holders: %{id => [area id]}}`.
  """
  def among(places) when is_list(places) do
    ids = Enum.map(places, & &1.id)

    boxes =
      from(g in Group,
        where: g.id in ^ids and not is_nil(g.area),
        select: {g.id, [g.area_west, g.area_south, g.area_east, g.area_north]}
      )
      |> Repo.all()
      |> Map.new()

    routes =
      from(g in Group,
        where: g.id in ^ids and not is_nil(g.route),
        select:
          {g.id,
           %{
             bbox: [g.route_west, g.route_south, g.route_east, g.route_north],
             length: g.route_length
           }}
      )
      |> Repo.all()
      |> Map.new()

    holders =
      if boxes == %{} do
        %{}
      else
        area_ids = Map.keys(boxes)

        from(p in Group,
          join: a in Group,
          on:
            a.id in ^area_ids and a.id != p.id and
              fragment(
                """
                CASE WHEN ? IS NOT NULL THEN ST_Intersects(?, ?)
                ELSE ST_Intersects(?, ST_SetSRID(ST_MakePoint(?, ?), 4326)) END
                """,
                p.route,
                a.area,
                p.route,
                a.area,
                p.longitude,
                p.latitude
              ) and
              (is_nil(p.area_size) or a.area_size > p.area_size),
          where: p.id in ^ids,
          order_by: [asc: p.id, asc: a.area_size, asc: a.id],
          select: {p.id, a.id}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      end

    %{boxes: boxes, routes: routes, holders: holders}
  end

  @doc """
  The shapes of the areas and routes `ids` the profile may see, simplified
  for the level of detail of `zoom` (`level/1`), as GeoJSON text: a
  `MultiPolygon` border for an area, a `MultiLineString` line for a route.
  `[%{id, version, geojson}]`, where `version` changes whenever the group
  does. `:parent_id` keeps only the groups right under that group, as a map
  app shows. Shapes come from `AreaShapes`, which keeps the ones already made.
  """
  def shapes(%Profile{} = profile, ids, zoom, opts \\ [])
      when is_list(ids) and is_integer(zoom) do
    level = level(zoom)

    Visibility.plain_groups(profile)
    |> where([g], (not is_nil(g.area) or not is_nil(g.route)) and not g.is_root)
    |> where([g], g.id in ^ids)
    |> under(opts[:parent_id])
    # A size tells two edits in the same second apart: an area's, or a route's length.
    |> select([g], %{
      id: g.id,
      updated_at: g.updated_at,
      size: fragment("COALESCE(?, ?)", g.area_size, g.route_length)
    })
    |> Repo.all()
    |> AreaShapes.fetch(level, &simplified(&1, level))
    |> Enum.map(fn {area, geojson} ->
      %{id: area.id, version: version(area.updated_at), geojson: geojson}
    end)
  end

  # The shapes of `ids` simplified for `level`: within ~0.75 px of the real
  # one at that zoom, with no more decimals than that needs. A border keeps
  # its topology (rings that do not cross); a line may cross itself anyway,
  # and keeps a part that would collapse (a short loop), so no route vanishes.
  # Either way the ends stay, so a map finds where a route ends.
  defp simplified(ids, level) do
    tolerance = 0.75 * 360.0 / (256.0 * Integer.pow(2, level))

    digits =
      cond do
        level <= 8 -> 3
        level <= 12 -> 4
        true -> 5
      end

    from(g in Group,
      where: g.id in ^ids,
      select:
        {g.id,
         fragment(
           """
           ST_AsGeoJSON(
             CASE WHEN ? IS NOT NULL THEN ST_Multi(ST_SimplifyPreserveTopology(?, ?::float8))
             ELSE ST_Multi(ST_Simplify(?, ?::float8, true)) END,
             ?::int
           )
           """,
           g.area,
           g.area,
           ^tolerance,
           g.route,
           ^tolerance,
           ^digits
         )}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp under(query, nil), do: query
  defp under(query, parent_id), do: where(query, [g], g.parent_id == ^parent_id)

  @doc "What a group's area is known by in a browser's cache: it changes with the group."
  def version(%DateTime{} = updated_at), do: DateTime.to_unix(updated_at)

  @doc """
  The areas the profile may see whose name holds `term` (`NameSearch`; all
  for a blank one), by name, at most `limit`: what a filter offers.
  """
  def search(%Profile{} = profile, term, limit) when is_integer(limit) do
    visible(profile)
    |> NameSearch.where_matches(NameSearch.term(to_string(term)))
    |> order_by([g], asc: fragment("lower(?)", g.name), asc: g.id)
    |> limit(^limit)
    |> select([g], struct(g, ^@fields))
    |> Repo.all()
  end

  @doc """
  The areas `ids` the profile may see, in the order of `ids`, with their
  boxes (`bbox/1`).
  """
  def get_visible(%Profile{} = profile, ids) when is_list(ids) do
    by_id =
      visible(profile)
      |> where([g], g.id in ^ids)
      |> select([g], struct(g, ^(@fields ++ box_fields())))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, &List.wrap(by_id[&1]))
  end

  @doc """
  The box around the areas `ids` the profile may see, `[[south, west],
  [north, east]]`, or nil for none.
  """
  def extent(%Profile{} = profile, ids) when is_list(ids) do
    visible(profile)
    |> where([g], g.id in ^ids)
    |> select([g], [min(g.area_south), min(g.area_west), max(g.area_north), max(g.area_east)])
    |> Repo.one()
    |> case do
      [south, west, north, east] when is_number(south) -> [[south, west], [north, east]]
      _none -> nil
    end
  end
end
