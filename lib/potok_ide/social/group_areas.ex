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

  An area is seen by whoever may see its group: its members and, for a public
  group, every signed-in profile. Areas do not follow the root map's filters:
  they are what a map stands on, and the filters choose its pins (the user's
  choice, 2026-11-10).
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, GroupMembership, Profile}

  # Big enough for an official border; a drawn one stays far below.
  @max_points 10_000
  @max_parts 100
  # Web Mercator ends here, as a map does.
  @max_lat 85.0511287798

  # An area is drawn as a border once it is this wide on the screen; below it,
  # it is a pin like any other.
  @drawn_px 28

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

  # The areas a profile sees: its groups' and the public groups', never a
  # thread's or a direct conversation's (the root has no place at all).
  defp visible(%Profile{id: profile_id}) do
    from(g in Group,
      as: :group,
      where:
        not is_nil(g.area) and not g.is_root and is_nil(g.parent_value_id) and
          g.is_direct == false,
      where:
        g.is_public or
          exists(
            from(m in GroupMembership,
              where: m.group_id == parent_as(:group).id and m.profile_id == ^profile_id
            )
          )
    )
  end

  # How wide an area is in degrees of longitude, its height counted as a
  # Mercator map stretches it at its pin.
  defmacrop span(area, lat) do
    quote do
      fragment(
        "GREATEST(ST_XMax(?) - ST_XMin(?), (ST_YMax(?) - ST_YMin(?)) / cos(radians(?)))",
        unquote(area),
        unquote(area),
        unquote(area),
        unquote(area),
        unquote(lat)
      )
    end
  end

  @doc """
  How wide (in degrees of longitude, as `span` measures it) an area must be to
  be drawn as a border at `zoom` rather than as a pin.
  """
  def min_span(zoom) when is_integer(zoom),
    do: @drawn_px * 360.0 / (256.0 * Integer.pow(2, zoom |> max(0) |> min(24)))

  @doc """
  The areas the profile sees that cover the point, smallest first, as groups
  with what a pin needs. Options: `:except` leaves one group out, `:zoom`
  keeps only the areas drawn as borders at that zoom (`min_span/1`),
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
    |> order_by([g], asc: fragment("ST_Area(?)", g.area), asc: g.id)
    |> limit(^Keyword.get(opts, :limit, 10))
    |> select([g], struct(g, ^@fields))
    |> Repo.all()
  end

  defp except_id(query, nil), do: query
  defp except_id(query, id), do: where(query, [g], g.id != ^id)

  defp drawn_at(query, nil), do: query
  defp drawn_at(query, zoom), do: where(query, [g], span(g.area, g.latitude) >= ^min_span(zoom))

  defp larger_than(query, nil), do: query

  defp larger_than(query, size),
    do: where(query, [g], fragment("ST_Area(?) > ?::float8", g.area, ^(size * 1.0)))

  @doc """
  How big an area is, in square degrees: enough to tell which of two areas
  is the bigger one, which is all it is used for.
  """
  def size(%Geo.MultiPolygon{} = area) do
    [[size]] = Repo.query!("SELECT ST_Area($1::geometry)", [area]).rows
    size
  end

  defp size_of(%Group{id: id}) do
    from(g in Group,
      where: g.id == ^id and not is_nil(g.area),
      select: fragment("ST_Area(?)", g.area)
    )
    |> Repo.one()
  end

  @doc "Whether the group's place is an area."
  def area?(%Group{area: %Geo.MultiPolygon{}}), do: true

  def area?(%Group{id: id} = group) do
    Group.placed?(group) and
      Repo.exists?(from(g in Group, where: g.id == ^id and not is_nil(g.area)))
  end

  @doc """
  The areas the profile sees that hold the group's pin, smallest first: where
  the group is. None for a group without a place.
  """
  def containing(%Profile{} = profile, %Group{} = group) do
    if Group.placed?(group) do
      areas_at(profile, group.latitude, group.longitude,
        except: group.id,
        larger_than: size_of(group)
      )
    else
      []
    end
  end

  @doc """
  The areas a map draws as borders in its box at `zoom`: those the profile
  sees that reach into the box and are wide enough there (`min_span/1`),
  biggest first so that smaller ones lie on top, at most `limit`. Each is
  `%{group, bbox: [west, south, east, north]}`. `ranges` is the box as
  `Social.map_bbox_params/1` gives it.
  """
  def list_drawable(%Profile{} = profile, [south, north, west, east, west2, east2], zoom, limit)
      when is_integer(zoom) and is_integer(limit) do
    box =
      dynamic(
        [g],
        fragment(
          "? && ST_MakeEnvelope(?::float8, ?::float8, ?::float8, ?::float8, 4326)",
          g.area,
          ^west,
          ^south,
          ^east,
          ^north
        )
      )

    box =
      if west2 do
        dynamic(
          [g],
          ^box or
            fragment(
              "? && ST_MakeEnvelope(?::float8, ?::float8, ?::float8, ?::float8, 4326)",
              g.area,
              ^west2,
              ^south,
              ^east2,
              ^north
            )
        )
      else
        box
      end

    visible(profile)
    |> where(^box)
    |> drawn_at(zoom)
    |> order_by([g], desc: fragment("ST_Area(?)", g.area), asc: g.id)
    |> limit(^limit)
    |> select([g], {
      struct(g, ^@fields),
      fragment("ST_XMin(?)", g.area),
      fragment("ST_YMin(?)", g.area),
      fragment("ST_XMax(?)", g.area),
      fragment("ST_YMax(?)", g.area)
    })
    |> Repo.all()
    |> Enum.map(fn {group, w, s, e, n} -> %{group: group, bbox: [w, s, e, n]} end)
  end

  @doc "The level of detail (`@levels`) a map at `zoom` asks borders at."
  def level(zoom) when is_integer(zoom), do: Enum.find(@levels, 16, &(&1 >= zoom))

  @doc """
  The borders of the areas `ids` the profile sees, simplified for the level
  of detail of `zoom` (`level/1`), as GeoJSON text: `[%{id, version, geojson}]`,
  where `version` changes whenever the group does.
  """
  def shapes(%Profile{} = profile, ids, zoom) when is_list(ids) and is_integer(zoom) do
    level = level(zoom)
    tolerance = 0.75 * 360.0 / (256.0 * Integer.pow(2, level))

    digits =
      cond do
        level <= 8 -> 4
        level <= 12 -> 5
        true -> 6
      end

    visible(profile)
    |> where([g], g.id in ^ids)
    |> select([g], %{
      id: g.id,
      updated_at: g.updated_at,
      geojson:
        fragment(
          "ST_AsGeoJSON(ST_Multi(ST_SimplifyPreserveTopology(?, ?::float8)), ?::int)",
          g.area,
          ^tolerance,
          ^digits
        )
    })
    |> Repo.all()
    |> Enum.map(&%{id: &1.id, version: version(&1.updated_at), geojson: &1.geojson})
  end

  @doc "What a group's area is known by in a browser's cache: it changes with the group."
  def version(%DateTime{} = updated_at), do: DateTime.to_unix(updated_at)

  @doc """
  The areas the profile sees whose name holds `term` (all for a blank one), by
  name, at most `limit`: what a filter offers.
  """
  def search(%Profile{} = profile, term, limit) when is_integer(limit) do
    term = term |> to_string() |> String.trim() |> String.slice(0, 120)

    visible(profile)
    |> then(fn query ->
      if term == "",
        do: query,
        else: where(query, [g], ilike(g.name, ^"%#{escape_like(term)}%"))
    end)
    |> order_by([g], asc: fragment("lower(?)", g.name), asc: g.id)
    |> limit(^limit)
    |> select([g], struct(g, ^@fields))
    |> Repo.all()
  end

  defp escape_like(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))

  @doc "The areas `ids` the profile sees, in the order of `ids`."
  def get_visible(%Profile{} = profile, ids) when is_list(ids) do
    by_id =
      visible(profile)
      |> where([g], g.id in ^ids)
      |> select([g], struct(g, ^@fields))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, &List.wrap(by_id[&1]))
  end

  @doc """
  The box around the areas `ids` the profile sees, `[[south, west], [north,
  east]]`, or nil for none.
  """
  def extent(%Profile{} = profile, ids) when is_list(ids) do
    visible(profile)
    |> where([g], g.id in ^ids)
    |> select([g], [
      fragment("ST_YMin(ST_Extent(?))", g.area),
      fragment("ST_XMin(ST_Extent(?))", g.area),
      fragment("ST_YMax(ST_Extent(?))", g.area),
      fragment("ST_XMax(ST_Extent(?))", g.area)
    ])
    |> Repo.one()
    |> case do
      [south, west, north, east] when is_number(south) -> [[south, west], [north, east]]
      _none -> nil
    end
  end
end
