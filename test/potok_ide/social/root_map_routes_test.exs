defmodule PotokIde.Social.RootMapRoutesTest do
  @moduledoc """
  Routes on the root's map (`Social.list_map_cells/4` and its kin): a route
  is drawn as a line once it is wide enough, its pin stays among the pins,
  it follows every filter like any group, and the area filter keeps a route
  that passes through an area.
  """
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupAreas, GroupRoutes}

  @box [19.0, 44.5, 20.7, 46.0]

  setup do
    {_account, owner} = account_with_profile!("map-route-owner")
    {_account, outsider} = account_with_profile!("map-route-out")
    public = %{"is_public" => true}

    # A quarter of Novi Sad, a route from west of it through it, one far
    # north that misses it, and a shop inside it.
    quarter = area_group!(owner, square({45.25, 19.85}, 0.05), public)
    through = route_group!(owner, [[19.6, 45.25], [19.86, 45.26], [19.95, 45.25]], public)
    north = route_group!(owner, [[19.7, 45.6], [19.8, 45.6]], public)

    shop =
      group_with_members!(
        owner,
        [],
        Map.merge(public, %{"latitude" => 45.26, "longitude" => 19.84})
      )

    %{
      owner: owner,
      outsider: outsider,
      quarter: quarter,
      through: through,
      north: north,
      shop: shop
    }
  end

  defp square({lat, lng}, half) do
    [
      [lng - half, lat - half],
      [lng + half, lat - half],
      [lng + half, lat + half],
      [lng - half, lat + half],
      [lng - half, lat - half]
    ]
  end

  defp area_group!(owner, ring, attrs) do
    {:ok, area} = GroupAreas.decode(%{"type" => "Polygon", "coordinates" => [ring]})
    group = group_with_members!(owner, [], attrs)
    {:ok, group} = Social.update_group(owner, group, %{"area" => area})
    group
  end

  defp route_group!(owner, points, attrs) do
    {:ok, route} = GroupRoutes.decode(%{"type" => "LineString", "coordinates" => points})
    group = group_with_members!(owner, [], attrs)
    {:ok, group} = Social.update_group(owner, group, %{"route" => route})
    group
  end

  defp view(profile, filters, box \\ @box, zoom) do
    {:ok, view} = Social.list_map_cells(profile, Map.merge(%{public?: true}, filters), box, zoom)
    view
  end

  defp pin_ids(view), do: view.places |> Enum.map(& &1.id) |> Enum.sort()
  defp ids(groups), do: groups |> Enum.map(& &1.id) |> Enum.sort()

  test "a route is drawn as a line once wide enough, and its pin stays among the pins", ctx do
    lines = %{routes?: true}
    # About 23 px wide at zoom 7 (not drawn), 750 px at zoom 12.
    assert view(ctx.outsider, lines, 7).routes == []

    drawn = view(ctx.outsider, lines, 12)
    assert ids(drawn.routes) == ids([ctx.through, ctx.north])
    assert ctx.through.id in pin_ids(drawn)

    # Lines come with their boxes and lengths.
    route = Enum.find(drawn.routes, &(&1.id == ctx.through.id))
    assert GroupRoutes.bbox(route) == [19.6, 45.25, 19.95, 45.26]
    assert route.route_length > 27_000

    # Without the layer, no lines, and the pins stay.
    assert view(ctx.outsider, %{}, 12).routes == []
    assert ctx.through.id in pin_ids(view(ctx.outsider, %{}, 12))
  end

  test "a line that reaches into the view is counted though its pin is outside", ctx do
    # Only the route's eastern end: its pin, at 19.6, is out of this box.
    east = [19.9, 45.2, 20.0, 45.3]

    drawn = view(ctx.outsider, %{routes?: true}, east, 12)
    assert ids(drawn.routes) == [ctx.through.id]
    refute ctx.through.id in pin_ids(drawn)
    assert drawn.total == 1

    # Without the layer it is a pin, and out of the box.
    assert view(ctx.outsider, %{}, east, 12).total == 0
  end

  test "without places, only the shapes whose layer is on", ctx do
    only = %{places?: false}
    routes = ids([ctx.through, ctx.north])

    assert pin_ids(view(ctx.outsider, Map.put(only, :routes?, true), 7)) == routes
    assert pin_ids(view(ctx.outsider, Map.put(only, :shapes?, true), 7)) == [ctx.quarter.id]

    assert pin_ids(view(ctx.outsider, Map.merge(only, %{shapes?: true, routes?: true}), 7)) ==
             Enum.sort([ctx.quarter.id | routes])

    refute ctx.shop.id in pin_ids(view(ctx.outsider, Map.put(only, :routes?, true), 7))
  end

  test "the area filter keeps a route that passes through, not one that misses", ctx do
    inside = %{areas: [ctx.quarter.id], routes?: true}

    # The shop by its pin, the route by its line though it starts outside.
    assert pin_ids(view(ctx.outsider, inside, 18)) == ids([ctx.shop, ctx.through])
    assert ids(view(ctx.outsider, inside, 12).routes) == [ctx.through.id]

    # Counted once, though both its pin rule and its line could have kept it.
    assert {:ok, %{count: 2}} =
             Social.map_extent(ctx.outsider, %{public?: true, areas: [ctx.quarter.id]})

    zoomed_out = view(ctx.outsider, inside, 7)
    shown = length(zoomed_out.places) + Enum.sum(Enum.map(zoomed_out.clusters, & &1.count))
    assert shown == 2
  end

  test "filters leave a route out like any group", ctx do
    lines = %{routes?: true}
    later = %{from: DateTime.add(DateTime.utc_now(), 1, :day)}

    assert view(ctx.outsider, Map.merge(lines, later), 12).routes == []
    assert view(ctx.outsider, Map.put(lines, :search, "nothing like it"), 12).routes == []
    assert view(ctx.outsider, Map.put(lines, :pins, ["shop"]), 12).routes == []

    {:ok, _} = Social.update_group(ctx.owner, ctx.north, %{"pin_icon" => "route"})
    assert ids(view(ctx.outsider, Map.put(lines, :pins, ["route"]), 12).routes) == [ctx.north.id]

    # The public switch too, for public groups one is not in.
    {:ok, view} = Social.list_map_cells(ctx.outsider, lines, @box, 12)
    assert view.routes == []
  end

  test "the box around the map takes the whole line, not only its pin", ctx do
    assert {:ok, %{count: 4, bounds: [[south, west], [north, east]]}} =
             Social.map_extent(ctx.outsider, %{public?: true})

    assert_in_delta west, 19.6, 1.0e-6
    assert_in_delta east, 19.95, 1.0e-6
    assert_in_delta south, 45.2, 1.0e-6
    assert_in_delta north, 45.6, 1.0e-6
  end

  test "routes come widest first, with a budget of their own", ctx do
    # 150 more copies of the northern route: 152 lines to draw.
    Repo.query!(
      """
      INSERT INTO groups (name, description_format, is_public, creator_id, parent_id,
        inserted_at, updated_at, latitude, longitude, route)
      SELECT 'Staza ' || n, description_format, is_public, creator_id, parent_id,
        inserted_at, updated_at, latitude, longitude, route
      FROM groups, generate_series(1, 150) n
      WHERE id = $1
      """,
      [ctx.north.id]
    )

    view = view(ctx.outsider, %{routes?: true, shapes?: true}, 12)

    assert length(view.routes) == 150
    assert hd(view.routes).id == ctx.through.id
    assert ids(view.areas) == [ctx.quarter.id]
    assert view.total == 154
  end
end
