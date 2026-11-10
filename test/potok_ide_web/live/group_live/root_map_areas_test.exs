defmodule PotokIdeWeb.GroupLive.RootMapAreasTest do
  @moduledoc """
  Areas on the root's map (`RootMapState`, `GroupAreas`): drawn under the pins
  whatever the filters, their borders asked for once, two layers, a tap that
  lists the areas there, a filter by area, `?area=` links, and the strip that
  says where a group lies.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.GroupAreas

  @serbia [18.8, 41.8, 23.1, 46.2]
  # Novi Sad's middle.
  @ns {45.25, 19.85}

  defp square({lat, lng}, half) do
    {:ok, area} =
      GroupAreas.decode(%{
        "type" => "Polygon",
        "coordinates" => [
          [
            [lng - half, lat - half],
            [lng + half, lat - half],
            [lng + half, lat + half],
            [lng - half, lat + half],
            [lng - half, lat - half]
          ]
        ]
      })

    area
  end

  defp area_group!(owner, members, area, attrs) do
    group = group_with_members!(owner, members, attrs)
    {:ok, group} = Social.update_group(owner, group, %{"area" => area})
    group
  end

  setup do
    {_owner_account, owner} = account_with_profile!("rmarea-owner")
    {viewer_account, viewer} = account_with_profile!("rmarea-viewer")
    root = Social.get_root_group!()
    {lat, lng} = @ns

    # A public city the viewer is not in, a quarter inside it the viewer is
    # in, and a closed area the viewer does not see.
    city =
      area_group!(owner, [], square(@ns, 0.2), %{"name" => "Grad Novi Sad", "is_public" => true})

    quarter = area_group!(owner, [viewer], square(@ns, 0.05), %{"name" => "Liman"})
    closed = area_group!(owner, [], square(@ns, 0.03), %{"name" => "Zatvoreno područje"})

    shop =
      group_with_members!(owner, [viewer], %{
        "name" => "Pekara",
        "latitude" => lat + 0.01,
        "longitude" => lng + 0.01
      })

    far =
      group_with_members!(owner, [viewer], %{
        "name" => "Daleko",
        "latitude" => 43.32,
        "longitude" => 21.9
      })

    %{
      owner: owner,
      viewer: viewer,
      viewer_account: viewer_account,
      root: root,
      city: city,
      quarter: quarter,
      closed: closed,
      shop: shop,
      far: far
    }
  end

  # With the public groups shown: the city is public and the viewer not in it.
  defp live_map(account, path, connect_params \\ %{"show_public_groups" => true}) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(Map.merge(%{"time_zone" => "Europe/Belgrade"}, connect_params))
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

  test "the view names the areas wide enough to draw, and their borders come when asked", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    # The city is public and old enough for no time frame to matter: areas
    # are what the map stands on, whatever the filters.
    reply = view(lv, 12)
    assert ids(reply.areas) == [ctx.city.id, ctx.quarter.id]
    assert [%{name: "Grad Novi Sad", bbox: [_, _, _, _], v: v} | _] = reply.areas
    assert is_integer(v)
    assert reply.chosen == []

    # Far out the quarter is too small to draw; it is a pin like any other.
    assert ids(view(lv, 7).areas) == [ctx.city.id]

    render_hook(lv, "root_map_shapes", %{ids: [ctx.city.id, ctx.closed.id], zoom: 12})
    assert_reply(lv, %{ok: true, level: 12, shapes: [shape]})
    assert shape.id == ctx.city.id

    assert %{"type" => "MultiPolygon", "coordinates" => [[_ring]]} =
             shape.geojson |> Jason.encode!() |> Jason.decode!()
  end

  test "an area drawn as a border leaves the pins, and with areas off it is a pin again", ctx do
    # Public groups hidden: the city's pin would stand on the quarter's.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map", %{})

    reply = view(lv, 12)
    assert ctx.shop.id in ids(reply.places)
    refute ctx.quarter.id in ids(reply.places)

    lv |> element("#root-map-layer-areas") |> render_click()
    assert_push_event(lv, "root_map_layers", %{places: true, areas: false})
    assert_push_event(lv, "root_map_data", data)
    assert data.areas == []
    assert ctx.quarter.id in ids(data.places)
    assert has_element?(lv, "#root-map-layer-areas[aria-checked='false']")

    # Places off: only the areas, and the count says so.
    reply = view(lv, 12, %{places: false, areas: true})
    assert reply.places == [] and reply.clusters == []
    assert ids(reply.areas) == [ctx.quarter.id]
    assert reply.total == 1
  end

  test "an area too small to draw is a pin, which the filters leave out like any", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    # Far out the quarter is too small for a border: with places off it is
    # the only pin, the city a border.
    reply = view(lv, 7, %{places: false, areas: true})
    assert ids(reply.areas) == [ctx.city.id]
    assert ids(reply.places) == [ctx.quarter.id]

    # The viewer made none of them: the filter leaves out pins and borders.
    view(lv, 7, %{places: true, areas: true})
    lv |> element("#root-map-relation-option-creator") |> render_click()
    assert_push_event(lv, "root_map_data", %{places: [], areas: [], clusters: []})

    # A name finds an area as it finds any group, in any script.
    lv |> element("#root-map-relation-option-all") |> render_click()
    assert_push_event(lv, "root_map_data", _data)
    lv |> form("#root-map-search-form", root_map_search: %{q: "лиман"}) |> render_change()
    assert_push_event(lv, "root_map_data", data)
    assert ids(data.places) == [ctx.quarter.id]
    assert data.areas == []
  end

  test "a pin filter keeps the places and areas showing those pins, and the chosen areas", ctx do
    {:ok, _} = Social.update_group(ctx.owner, ctx.city, %{"pin_icon" => "municipality"})
    {:ok, _} = Social.update_group(ctx.owner, ctx.quarter, %{"pin_icon" => "local_community"})
    {:ok, _} = Social.update_group(ctx.owner, ctx.shop, %{"pin_icon" => "food"})
    {lat, lng} = @ns

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    view(lv, 12)

    lv |> element("#root-map-pin-option-municipality") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert ids(data.areas) == [ctx.city.id]
    assert data.places == []
    assert has_element?(lv, "#root-map-pin-option-municipality[aria-checked='true']")
    assert has_element?(lv, "#root-map-pin-option-all[aria-checked='false']")
    assert has_element?(lv, "#root-map-pin-toggle", "Municipality")
    # Phones show no text on the button: its label names the pin.
    assert has_element?(lv, "#root-map-pin-toggle[aria-label='Pins on the map: Municipality']")

    # A tap lists only the areas the map shows.
    render_hook(lv, "root_map_here", %{lat: lat + 0.02, lng: lng, zoom: 12})
    assert_reply(lv, %{ids: [city_id]})
    assert city_id == ctx.city.id

    # Far out, an area too small for a border is a pin only with its pin picked.
    refute ctx.quarter.id in ids(view(lv, 7).places)

    lv |> element("#root-map-pin-option-local_community") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert ctx.quarter.id in ids(data.places)
    assert has_element?(lv, "#root-map-pin-toggle", "2")

    # A chosen area stays outlined whatever its pin; the city is no group
    # inside the quarter.
    lv |> element("#root-map-pin-option-local_community") |> render_click()
    assert_push_event(lv, "root_map_data", _data)
    view(lv, 12)
    lv |> element("#root-map-area-option-#{ctx.quarter.id}") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert [%{ctx: true, id: quarter_id}] = data.areas
    assert quarter_id == ctx.quarter.id

    # A pin no group shows empties the map, and clearing the filters brings
    # every pin back.
    lv |> element("#root-map-area-option-all") |> render_click()
    assert_push_event(lv, "root_map_data", _data)
    lv |> element("#root-map-pin-option-municipality") |> render_click()
    assert_push_event(lv, "root_map_data", _data)
    lv |> element("#root-map-pin-option-help") |> render_click()
    assert_push_event(lv, "root_map_data", %{places: [], areas: []})
    assert has_element?(lv, "#root-map-empty")

    lv |> element("#root-map-clear-filters") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert ids(data.areas) == [ctx.city.id, ctx.quarter.id]
    assert has_element?(lv, "#root-map-pin-option-all[aria-checked='true']")

    # A key that is no pin changes nothing.
    render_click(lv, "root_map_pin", %{"pin" => "bogus"})
    assert has_element?(lv, "#root-map-pin-option-all[aria-checked='true']")
  end

  test "a tap lists the areas there, smallest first, and the card acts on them", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    view(lv, 12)
    {lat, lng} = @ns

    render_hook(lv, "root_map_here", %{lat: lat + 0.02, lng: lng, zoom: 12})
    assert_reply(lv, %{ids: ids})
    assert ids == [ctx.quarter.id, ctx.city.id]
    assert has_element?(lv, "#root-map-here #root-map-here-title", "Liman")

    lv |> element("#root-map-here-pick-#{ctx.city.id}") |> render_click()
    assert_push_event(lv, "root_map_select_area", %{id: city_id})
    assert city_id == ctx.city.id
    assert has_element?(lv, "#root-map-here-title", "Grad Novi Sad")

    # Only inside the city: the shop, not the far place nor the city itself,
    # which stays an outline. The filters changed, so the card closes.
    lv |> element("#root-map-here-filter") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert data.chosen == [ctx.city.id]
    assert [[_, _], [_, _]] = data.fit
    assert ctx.shop.id in ids(data.places)
    refute ctx.far.id in ids(data.places)
    refute ctx.city.id in ids(data.places)
    assert [%{ctx: true} = city] = Enum.filter(data.areas, &(&1.id == ctx.city.id))
    assert city.bbox == [19.65, 45.05, 20.05, 45.45]
    assert has_element?(lv, "#root-map-area-toggle", "Grad Novi Sad")
    refute has_element?(lv, "#root-map-here")

    # Inside it, the quarter; its card fits the map to it.
    render_hook(lv, "root_map_here", %{lat: lat + 0.02, lng: lng, zoom: 12})
    assert_reply(lv, %{ids: [quarter_id]})
    assert quarter_id == ctx.quarter.id
    lv |> element("#root-map-here-fit") |> render_click()
    assert_push_event(lv, "root_map_fit", %{bounds: [[_, _], [_, _]]})

    # Only inside the quarter instead: one area at a time.
    lv |> element("#root-map-here-filter") |> render_click()
    assert_push_event(lv, "root_map_data", %{chosen: [^quarter_id]})

    # Where no area stands, the card closes.
    render_hook(lv, "root_map_here", %{lat: 43.0, lng: 21.0, zoom: 12})
    assert_reply(lv, %{ids: []})
    refute has_element?(lv, "#root-map-here")
  end

  test "the area menu finds areas by name and narrows the map", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    view(lv, 12)

    assert has_element?(lv, "#root-map-area-option-#{ctx.city.id}")
    assert has_element?(lv, "#root-map-area-option-#{ctx.quarter.id}")
    refute has_element?(lv, "#root-map-area-option-#{ctx.closed.id}")

    lv
    |> form("#root-map-area-search-form", %{"root_map_area" => %{"q" => "grad"}})
    |> render_change()

    assert has_element?(lv, "#root-map-area-option-#{ctx.city.id}")
    refute has_element?(lv, "#root-map-area-option-#{ctx.quarter.id}")

    lv |> element("#root-map-area-option-#{ctx.city.id}") |> render_click()
    assert_push_event(lv, "root_map_data", %{chosen: [city_id]})
    assert city_id == ctx.city.id
    assert has_element?(lv, "#root-map-area-option-#{ctx.city.id}[aria-checked='true']")

    lv |> element("#root-map-area-option-all") |> render_click()
    assert_push_event(lv, "root_map_data", %{chosen: []})

    # An area the viewer does not see stays out.
    render_click(lv, "root_map_area", %{"id" => ctx.closed.id})
    refute has_element?(lv, "#root-map-area-option-#{ctx.closed.id}")
  end

  test "an area link opens the map on it, from any time", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[area: ctx.quarter.id]}")

    reply = view(lv, 10)
    assert reply.chosen == [ctx.quarter.id]
    assert [[south, _west], [north, _east]] = reply.fit
    assert_in_delta south, 45.2, 1.0e-6
    assert_in_delta north, 45.3, 1.0e-6
    assert ids(reply.places) == [ctx.shop.id]
    assert has_element?(lv, "#root-map-time-option-any[aria-checked='true']")

    # Once only: the next view keeps where the viewer moved.
    refute Map.has_key?(view(lv, 10), :fit)

    # A chosen area that holds nothing says so, and steps aside when closed,
    # the area still chosen.
    {:ok, _} = Social.update_group(ctx.owner, ctx.shop, %{"latitude" => "", "longitude" => ""})
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[area: ctx.quarter.id]}")
    assert has_element?(lv, "#root-map-empty")
    refute has_element?(lv, "#root-map-area-clear")

    lv |> element("#root-map-empty-close") |> render_click()
    refute has_element?(lv, "#root-map-empty")
    assert view(lv, 10).chosen == [ctx.quarter.id]

    # A public area the viewer is not in works the same.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[area: ctx.city.id]}")
    assert view(lv, 10).chosen == [ctx.city.id]
    assert has_element?(lv, "#root-map-area-option-#{ctx.city.id}[aria-checked='true']")

    # An area the viewer cannot see changes nothing.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[area: ctx.closed.id]}")
    assert view(lv, 10).chosen == []
  end

  test "a group says which areas it lies in, and an area leads to its map", ctx do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.viewer_account)
      |> live(~p"/groups/#{ctx.shop.id}/group_home")

    assert has_element?(lv, "#group-location-area-#{ctx.quarter.id}", "Liman")
    assert has_element?(lv, "#group-location-area-#{ctx.city.id}", "Grad Novi Sad")
    refute has_element?(lv, "#group-location-area-#{ctx.closed.id}")
    refute has_element?(lv, "#group-location-map")

    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.viewer_account)
      |> live(~p"/groups/#{ctx.quarter.id}/group_home")

    assert has_element?(lv, "#group-location-area-#{ctx.city.id}")

    assert has_element?(
             lv,
             ~s{#group-location-map[href="/groups/#{ctx.root.id}/map?area=#{ctx.quarter.id}"]}
           )

    # Over the map, the sheet says the same.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")
    render_click(lv, "root_map_open", %{"id" => ctx.shop.id})
    [sheet] = Enum.filter(live_children(lv), &String.starts_with?(&1.id, "group-sheet-lv-"))
    assert has_element?(sheet, "#sheet-location-area-#{ctx.quarter.id}")

    # A group without a place shows nothing of the kind.
    plain = group_with_members!(ctx.owner, [ctx.viewer], %{"home_page" => :description})

    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.viewer_account)
      |> live(~p"/groups/#{plain.id}/group_home")

    refute has_element?(lv, "#group-location")
  end
end
