defmodule PotokIdeWeb.GroupLive.GroupRouteSettingsTest do
  @moduledoc """
  A route on the "Location" card: the third mode next to a point and an area,
  the line sent on its own (`edit_group_route`) and checked at once, with its
  start and length, saved with the form in the area's place, and the areas
  it passes through.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas, GroupRoutes}

  @ns {45.25, 19.85}

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("route-card-owner")
    %{conn: log_in_account(conn, account), owner: owner}
  end

  # A walk west to east along 45.25° N, from `from` to `to`.
  defp walk(from, to) do
    %{
      "type" => "LineString",
      "coordinates" => [[from, 45.25], [(from + to) / 2, 45.26], [to, 45.25]]
    }
  end

  defp square({lat, lng}, half) do
    %{
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
    }
  end

  defp settings(conn, group), do: live(conn, ~p"/groups/#{group.id}/edit_group")

  defp send_route(lv, geojson) do
    render_hook(lv, "edit_group_route", %{"route" => geojson})
    assert_reply(lv, reply)
    reply
  end

  defp save(lv, attrs \\ %{}) do
    lv |> form("#group-edit-form", %{"group" => attrs}) |> render_submit()
  end

  test "a route is the third mode, with its own tools and hint", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-location-map[data-route='null']")
    assert has_element?(lv, "#group-route-tools.hidden")
    refute has_element?(lv, "#group-route-hint")

    lv |> element("#group-location-mode-route") |> render_click()

    assert_push_event(lv, "location_mode", %{mode: "route"})
    assert has_element?(lv, "#group-location-mode-route[aria-checked='true']")
    assert has_element?(lv, "#group-route-tools:not(.hidden)")
    assert has_element?(lv, "#group-area-tools.hidden")
    assert has_element?(lv, "#group-route-hint")
    assert has_element?(lv, "#group-route-reverse")
  end

  test "a drawn route gets its pin at its start and its length, and is saved", %{
    conn: conn,
    owner: owner
  } do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-route") |> render_click()

    assert %{ok: true, lat: 45.25, lng: 19.8, length: length, length_text: text} =
             send_route(lv, walk(19.8, 19.9))

    assert_in_delta length, 8_000, 300
    assert text =~ "km"
    assert has_element?(lv, "#group-edit-save-bar")

    save(lv, %{"latitude" => "1", "longitude" => "1"})

    group = Social.load_area(Repo.get!(Group, group.id))
    assert %Geo.MultiLineString{coordinates: [points]} = group.route
    assert length(points) == 3
    assert {group.latitude, group.longitude} == {45.25, 19.8}

    {:ok, lv, _html} = settings(conn, group)
    assert has_element?(lv, "#group-location-mode-route[aria-checked='true']")

    assert has_element?(
             lv,
             "#group-location-map[data-mode='route'][data-route*='MultiLineString'][data-route-length]"
           )
  end

  test "a line of one point is refused, and so is the save", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-route") |> render_click()

    assert %{ok: false, error: error} =
             send_route(lv, %{"type" => "LineString", "coordinates" => [[19.8, 45.25]]})

    assert is_binary(error)
    assert has_element?(lv, "#group-route-error")

    save(lv)
    assert Social.load_area(Repo.get!(Group, group.id)).route == nil
    assert has_element?(lv, "#group-edit-location:not(.hidden)")
  end

  test "a route drawn over a saved area takes its place", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, area} = GroupAreas.decode(square(@ns, 0.05))
    {:ok, group} = Social.update_group(owner, group, %{"area" => area})

    {:ok, lv, _html} = settings(conn, group)
    assert has_element?(lv, "#group-location-mode-area[aria-checked='true']")

    lv |> element("#group-location-mode-route") |> render_click()
    send_route(lv, walk(19.8, 19.9))
    save(lv)

    saved = Social.load_area(Repo.get!(Group, group.id))
    assert saved.area == nil
    assert %Geo.MultiLineString{} = saved.route
  end

  test "switching from an area to a route drops the area, drawn or not", %{
    conn: conn,
    owner: owner
  } do
    group = group_with_members!(owner, [])
    {:ok, area} = GroupAreas.decode(square(@ns, 0.05))
    {:ok, group} = Social.update_group(owner, group, %{"area" => area})

    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-route") |> render_click()
    save(lv)

    saved = Social.load_area(Repo.get!(Group, group.id))
    assert saved.area == nil
    assert saved.route == nil
    # The pin stays where the area had it.
    assert {saved.latitude, saved.longitude} == {group.latitude, group.longitude}
  end

  test "going back to a point keeps the pin at the route's start", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, route} = GroupRoutes.decode(walk(19.8, 19.9))
    {:ok, group} = Social.update_group(owner, group, %{"route" => route})

    {:ok, lv, _html} = settings(conn, group)
    assert has_element?(lv, "#group-location-mode-route[aria-checked='true']")

    lv |> element("#group-location-mode-point") |> render_click()
    save(lv)

    saved = Social.load_area(Repo.get!(Group, group.id))
    assert saved.route == nil
    assert {saved.latitude, saved.longitude} == {45.25, 19.8}
  end

  test "discarding puts the saved route back on the map", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-route") |> render_click()
    send_route(lv, walk(19.8, 19.9))

    lv |> element("#group-edit-discard") |> render_click()

    assert_push_event(lv, "location_reset", %{route: nil, area: nil, mode: "point"})
    save(lv)
    assert Social.load_area(Repo.get!(Group, group.id)).route == nil
  end

  test "the card says which areas the route passes through", %{conn: conn, owner: owner} do
    {_account, other} = account_with_profile!("route-card-other")
    {:ok, city_area} = GroupAreas.decode(square(@ns, 0.1))
    city = group_with_members!(other, [], %{"name" => "Grad", "is_public" => true})
    {:ok, city} = Social.update_group(other, city, %{"area" => city_area})

    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-route") |> render_click()

    # It starts west of the city and runs through it.
    send_route(lv, walk(19.5, 19.85))
    assert has_element?(lv, "#group-location-within-#{city.id}", "Grad")
    assert has_element?(lv, "#group-location-within", "Passes through")

    send_route(lv, walk(19.4, 19.5))
    refute has_element?(lv, "#group-location-within")
  end
end
