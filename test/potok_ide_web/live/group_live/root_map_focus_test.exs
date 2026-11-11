defmodule PotokIdeWeb.GroupLive.RootMapFocusTest do
  @moduledoc """
  Links that open the root's map on one place (`RootMapState`): `?place=` for
  a group with a place, `?event=` for a calendar event's place with the
  event's card, both in focus whatever the filters and only when the viewer
  may see them.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Social
  alias PotokIde.Social.{GroupAreas, GroupRoutes}

  @serbia [18.8, 41.8, 23.1, 46.2]

  setup do
    {_owner_account, owner} = account_with_profile!("rmfocus-owner")
    {viewer_account, viewer} = account_with_profile!("rmfocus-viewer")
    root = Social.get_root_group!()

    bakery =
      group_with_members!(owner, [viewer], %{
        "name" => "Pekara",
        "latitude" => 45.25,
        "longitude" => 19.85
      })

    closed =
      group_with_members!(owner, [], %{
        "name" => "Zatvorena",
        "latitude" => 45.26,
        "longitude" => 19.86
      })

    {:ok, area} =
      GroupAreas.decode(%{
        "type" => "Polygon",
        "coordinates" => [[[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.3], [19.8, 45.2]]]
      })

    quarter = group_with_members!(owner, [viewer], %{"name" => "Liman"})
    {:ok, quarter} = Social.update_group(owner, quarter, %{"area" => area})

    {:ok, line} =
      GroupRoutes.decode(%{
        "type" => "LineString",
        "coordinates" => [[20.0, 44.8], [20.3, 44.81]]
      })

    walk = group_with_members!(owner, [viewer], %{"name" => "Šetnja"})
    {:ok, walk} = Social.update_group(owner, walk, %{"route" => line})

    calendar = group_with_members!(owner, [viewer], %{"name" => "Savet"})

    %{
      owner: owner,
      viewer: viewer,
      viewer_account: viewer_account,
      root: root,
      bakery: bakery,
      closed: closed,
      quarter: quarter,
      walk: walk,
      calendar: calendar,
      date: Date.add(today(), 6)
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

  defp view(lv, zoom) do
    render_hook(lv, "root_map_view", %{bbox: @serbia, zoom: zoom})
    assert_reply(lv, reply)
    reply
  end

  defp ctx_ids(list), do: for(%{ctx: true, id: id} <- list, do: id)

  test "a group's link puts its pin in focus, from any time and whatever the filters", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[place: ctx.bakery.id]}")

    reply = view(lv, 7)
    assert reply.fit == [[45.25, 19.85], [45.25, 19.85]]
    assert %{id: id, event: false, lat: 45.25, lng: 19.85} = reply.focus
    assert id == ctx.bakery.id
    assert has_element?(lv, "#root-map-time-option-any[aria-checked='true']")
    # A group has no card: its pin opens it as always.
    refute has_element?(lv, "#root-map-focus")

    # A search that leaves it out still shows it.
    lv
    |> form("#root-map-search-form", %{"root_map_search" => %{"q" => "nothing"}})
    |> render_change()

    assert_push_event(lv, "root_map_data", data)
    assert data.places == []
    assert data.focus.id == ctx.bakery.id
    refute has_element?(lv, "#root-map-empty")

    # Without the link, no focus.
    render_patch(lv, ~p"/groups/#{ctx.root.id}/map")
    assert_push_event(lv, "root_map_data", data)
    assert data.focus == nil
  end

  test "an area or a route in focus is outlined once, fitted to its box", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[place: ctx.quarter.id]}")

    reply = view(lv, 12)
    assert reply.fit == [[45.2, 19.8], [45.3, 19.9]]
    assert ctx_ids(reply.areas) == [ctx.quarter.id]
    assert Enum.count(reply.areas, &(&1.id == ctx.quarter.id)) == 1
    assert reply.focus.id == ctx.quarter.id

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[place: ctx.walk.id]}")

    reply = view(lv, 7)
    assert reply.fit == [[44.8, 20.0], [44.81, 20.3]]
    assert ctx_ids(reply.routes) == [ctx.walk.id]
    assert Enum.count(reply.routes, &(&1.id == ctx.walk.id)) == 1
  end

  test "a group the viewer cannot see changes nothing", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[place: ctx.closed.id]}")

    reply = view(lv, 7)
    refute Map.has_key?(reply, :fit)
    assert reply.focus == nil
  end

  test "an event's link shows its place with the event's card", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{
          "title" => "Sastanak saveta",
          "location" => "Kod česme",
          "latitude" => "45.1",
          "longitude" => "19.9"
        })
      )

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: event.id]}")

    reply = view(lv, 7)
    assert reply.fit == [[45.1, 19.9], [45.1, 19.9]]
    assert %{id: nil, pin: "event", event: true, name: "Sastanak saveta"} = reply.focus

    assert has_element?(lv, "#root-map-focus-title", "Sastanak saveta")
    assert has_element?(lv, "#root-map-focus-place", "Kod česme")
    refute has_element?(lv, "#root-map-focus-group")

    assert has_element?(
             lv,
             "#root-map-focus-open[href='/groups/#{ctx.calendar.id}/calendar?event=#{event.id}&on=#{ctx.date}']"
           )

    lv |> element("#root-map-focus-close") |> render_click()
    refute has_element?(lv, "#root-map-focus")
    render_hook(lv, "root_map_focus_show", %{})
    assert has_element?(lv, "#root-map-focus")
  end

  test "an event's own area or route is fitted to and sent once, when the map asks", ctx do
    {:ok, area} =
      GroupAreas.decode(%{
        "type" => "Polygon",
        "coordinates" => [[[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.3], [19.8, 45.2]]]
      })

    event =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{"latitude" => "45.25", "longitude" => "19.85"})
        |> Map.put("area", area)
      )

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: event.id]}")

    reply = view(lv, 12)
    assert reply.fit == [[45.2, 19.8], [45.3, 19.9]]
    assert %{pin: "event", shape: %{kind: "area", key: key}} = reply.focus
    # The shape is not in the view's own lists.
    assert ctx_ids(reply.areas) == []

    render_hook(lv, "root_map_focus_shape", %{})
    assert_reply(lv, %{ok: true, key: ^key, kind: "area", geojson: %{"type" => "MultiPolygon"}})

    {:ok, line} =
      GroupRoutes.decode(%{
        "type" => "LineString",
        "coordinates" => [[20.0, 44.8], [20.3, 44.81]]
      })

    {:ok, _event} = Events.update_event(ctx.owner, event, %{"route" => line})
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: event.id]}")

    reply = view(lv, 7)
    assert reply.fit == [[44.8, 20.0], [44.81, 20.3]]
    assert %{shape: %{kind: "route"}} = reply.focus
    render_hook(lv, "root_map_focus_shape", %{})
    assert_reply(lv, %{ok: true, kind: "route", geojson: %{"type" => "MultiLineString"}})

    # A group's place sends nothing of the kind.
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[place: ctx.bakery.id]}")
    view(lv, 7)
    render_hook(lv, "root_map_focus_shape", %{})
    assert_reply(lv, %{ok: false})
  end

  test "an event at a group shows the group's place and opens it from the card", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{"location" => "", "place_group_id" => "#{ctx.bakery.id}"})
      )

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: event.id]}")

    reply = view(lv, 7)
    assert %{id: id, event: true} = reply.focus
    assert id == ctx.bakery.id
    assert has_element?(lv, "#root-map-focus-place", "Pekara")

    lv |> element("#root-map-focus-group") |> render_click()
    assert Enum.any?(live_children(lv), &String.starts_with?(&1.id, "group-sheet-lv-"))
  end

  test "an event at a group the viewer cannot see, or a cancelled one, shows nothing", ctx do
    hidden =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{"place_group_id" => "#{ctx.closed.id}"})
      )

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: hidden.id]}")
    assert view(lv, 7).focus == nil
    refute has_element?(lv, "#root-map-focus")

    cancelled =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{"latitude" => "45.1", "longitude" => "19.9"})
      )

    {:ok, _cancelled} = Events.cancel_event(ctx.owner, cancelled)
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map?#{[event: cancelled.id]}")
    reply = view(lv, 7)
    refute Map.has_key?(reply, :fit)
    assert reply.focus == nil
  end

  test "the calendar's own event link leaves the map alone", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.calendar,
        event_attrs(ctx.date, %{"latitude" => "45.1", "longitude" => "19.9"})
      )

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}")
    render_patch(lv, ~p"/groups/#{ctx.root.id}/calendar?#{[event: event.id]}")
    assert has_element?(lv, "#calendar-event-detail")

    render_click(lv, "switch_tab", %{"tab" => "map"})
    reply = view(lv, 7)
    refute Map.has_key?(reply, :fit)
    assert reply.focus == nil
  end
end
