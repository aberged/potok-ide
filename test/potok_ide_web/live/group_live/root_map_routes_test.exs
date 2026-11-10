defmodule PotokIdeWeb.GroupLive.RootMapRoutesTest do
  @moduledoc """
  Routes on the root's map (`RootMapState`, `GroupRoutes`): lines once wide
  enough, asked for like borders, a layer of their own, `?route=` links that
  show one route whatever the filters, and the strip that says how long a
  route is and which areas it passes through.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{GroupAreas, GroupRoutes}

  @serbia [18.8, 41.8, 23.1, 46.2]

  defp line(points) do
    {:ok, route} = GroupRoutes.decode(%{"type" => "LineString", "coordinates" => points})
    route
  end

  defp route_group!(owner, members, route, attrs) do
    group = group_with_members!(owner, members, attrs)
    {:ok, group} = Social.update_group(owner, group, %{"route" => route})
    group
  end

  setup do
    {_owner_account, owner} = account_with_profile!("rmroute-owner")
    {viewer_account, viewer} = account_with_profile!("rmroute-viewer")
    root = Social.get_root_group!()

    {:ok, city_area} =
      GroupAreas.decode(%{
        "type" => "Polygon",
        "coordinates" => [
          [[19.75, 45.2], [19.95, 45.2], [19.95, 45.3], [19.75, 45.3], [19.75, 45.2]]
        ]
      })

    city = group_with_members!(owner, [], %{"name" => "Grad Novi Sad", "is_public" => true})
    {:ok, city} = Social.update_group(owner, city, %{"area" => city_area})

    # A walk from west of the city through it, which the viewer is in, and a
    # closed route the viewer does not see.
    walk =
      route_group!(owner, [viewer], line([[19.6, 45.25], [19.8, 45.26], [19.9, 45.25]]), %{
        "name" => "Šetnja"
      })

    closed = route_group!(owner, [], line([[20.0, 44.8], [20.3, 44.8]]), %{"name" => "Zatvorena"})

    %{
      owner: owner,
      viewer: viewer,
      viewer_account: viewer_account,
      root: root,
      city: city,
      walk: walk,
      closed: closed
    }
  end

  defp live_map(account, path) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => "Europe/Belgrade"})
      |> live(path)

    lv
  end

  defp view(lv, zoom, layers \\ nil) do
    params = %{bbox: @serbia, zoom: zoom}
    params = if layers, do: Map.put(params, :layers, layers), else: params
    render_hook(lv, "root_map_view", params)
    assert_reply(lv, reply)
    reply
  end

  defp ids(list), do: Enum.map(list, & &1.id)

  test "the view names the routes wide enough to draw, and their lines come when asked", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    reply = view(lv, 12)
    assert ids(reply.routes) == [ctx.walk.id]
    assert [%{name: "Šetnja", bbox: [19.6, 45.25, 19.9, 45.26], v: v}] = reply.routes
    assert is_integer(v)
    assert ctx.walk.id in ids(reply.places)

    # Far out the walk is too short for a line: only its pin.
    assert view(lv, 7).routes == []

    render_hook(lv, "root_map_shapes", %{ids: [ctx.walk.id, ctx.closed.id], zoom: 12})
    assert_reply(lv, %{ok: true, level: 12, shapes: [shape]})
    assert shape.id == ctx.walk.id

    assert %{"type" => "MultiLineString", "coordinates" => [[[19.6, 45.25] | _]]} =
             shape.geojson |> Jason.encode!() |> Jason.decode!()
  end

  test "routes have a layer of their own, remembered by the browser", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    assert has_element?(lv, "#root-map-layer-routes[aria-checked='true']")

    view(lv, 12)
    lv |> element("#root-map-layer-routes") |> render_click()

    assert_push_event(lv, "root_map_layers", %{places: true, areas: true, routes: false})
    assert_push_event(lv, "root_map_data", data)
    assert data.routes == []
    assert ctx.walk.id in ids(data.places)
    assert has_element?(lv, "#root-map-layer-routes[aria-checked='false']")

    # A browser that remembers no routes, from before they were a layer,
    # keeps the routes as they are.
    assert view(lv, 12, %{places: true, areas: true}).routes == []
    assert ids(view(lv, 12, %{places: true, areas: true, routes: true}).routes) == [ctx.walk.id]

    # Only routes: the walk and nothing else.
    reply = view(lv, 12, %{places: false, areas: false, routes: true})
    assert ids(reply.places) == [ctx.walk.id]
    assert reply.areas == []
  end

  test "the area filter keeps a route that passes through, though it starts outside", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[area: ctx.city.id]}")

    reply = view(lv, 12)
    assert ids(reply.routes) == [ctx.walk.id]
    assert ids(reply.places) == [ctx.walk.id]
  end

  test "a route link opens the map on it, from any time, and shows it whatever the filters",
       ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[route: ctx.walk.id]}")

    reply = view(lv, 7)
    assert reply.fit == [[45.25, 19.6], [45.26, 19.9]]
    # Drawn at a zoom where it would be only a pin, as the link names it.
    assert [%{id: id, ctx: true}] = reply.routes
    assert id == ctx.walk.id
    assert has_element?(lv, "#root-map-time-option-any[aria-checked='true']")

    # A search that leaves it out still shows its line, once.
    lv
    |> form("#root-map-search-form", %{"root_map_search" => %{"q" => "nothing"}})
    |> render_change()

    assert_push_event(lv, "root_map_data", data)
    assert data.places == []
    assert [%{ctx: true}] = data.routes

    # A route the viewer cannot see changes nothing.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[route: ctx.closed.id]}")
    reply = view(lv, 12)
    refute Map.has_key?(reply, :fit)
    refute ctx.closed.id in ids(reply.routes)
  end

  test "a route says how long it is, which areas it passes through, and leads to the map", ctx do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.viewer_account)
      |> live(~p"/groups/#{ctx.walk.id}/group_home")

    assert has_element?(lv, "#group-location-route", "km")
    assert has_element?(lv, "#group-location", "Passes through")
    assert has_element?(lv, "#group-location-area-#{ctx.city.id}", "Grad Novi Sad")

    assert has_element?(
             lv,
             ~s{#group-location-map[href="/groups/#{ctx.root.id}/map?route=#{ctx.walk.id}"]}
           )

    # Over the map, the sheet says the same.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    render_click(lv, "root_map_open", %{"id" => ctx.walk.id})
    [sheet] = Enum.filter(live_children(lv), &String.starts_with?(&1.id, "group-sheet-lv-"))
    assert has_element?(sheet, "#sheet-location-route")
    assert has_element?(sheet, "#sheet-location-map")
  end
end
