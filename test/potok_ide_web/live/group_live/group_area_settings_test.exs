defmodule PotokIdeWeb.GroupLive.GroupAreaSettingsTest do
  @moduledoc """
  An area on the "Location" card: a point or an area, the border sent on its
  own (`edit_group_area`) and checked at once, saved with the form, and the
  areas the card's pin lies in.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas}

  @ns {45.25, 19.85}

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("area-card-owner")
    %{conn: log_in_account(conn, account), owner: owner}
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

  defp send_area(lv, geojson) do
    render_hook(lv, "edit_group_area", %{"area" => geojson})
    assert_reply(lv, reply)
    reply
  end

  defp save(lv, attrs \\ %{}) do
    lv |> form("#group-edit-form", %{"group" => attrs}) |> render_submit()
  end

  test "a point by default, an area on a tap, with its tools", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-location-mode-point[aria-checked='true']")
    assert has_element?(lv, "#group-location-map[data-mode='point'][data-area='null']")
    assert has_element?(lv, "#group-area-tools.hidden")

    lv |> element("#group-location-mode-area") |> render_click()

    assert_push_event(lv, "location_mode", %{mode: "area"})
    assert has_element?(lv, "#group-location-mode-area[aria-checked='true']")
    assert has_element?(lv, "#group-area-tools:not(.hidden)")
    assert has_element?(lv, "#group-area-hint")
  end

  test "a drawn border gets its pin at once and is saved with the form", %{
    conn: conn,
    owner: owner
  } do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-area") |> render_click()

    assert %{ok: true, lat: lat, lng: lng} = send_area(lv, square(@ns, 0.05))
    assert_in_delta lat, 45.25, 0.01
    assert_in_delta lng, 19.85, 0.01

    # The save bar knows of a border that went outside the form.
    assert has_element?(lv, "#group-edit-save-bar")

    save(lv, %{"latitude" => "1", "longitude" => "1"})

    group = Social.load_area(Repo.get!(Group, group.id))
    assert %Geo.MultiPolygon{coordinates: [[ring]]} = group.area
    assert length(ring) == 5
    assert_in_delta group.latitude, 45.25, 0.01

    {:ok, lv, _html} = settings(conn, group)
    assert has_element?(lv, "#group-location-mode-area[aria-checked='true']")
    assert has_element?(lv, "#group-location-map[data-mode='area'][data-area*='MultiPolygon']")
  end

  test "a border that crosses itself is refused, and so is the save", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-area") |> render_click()

    bowtie = %{
      "type" => "Polygon",
      "coordinates" => [[[19.0, 45.0], [19.2, 45.2], [19.2, 45.0], [19.0, 45.2], [19.0, 45.0]]]
    }

    assert %{ok: false, error: error} = send_area(lv, bowtie)
    assert is_binary(error)
    assert has_element?(lv, "#group-area-error")

    save(lv)
    assert Social.load_area(Repo.get!(Group, group.id)).area == nil
    assert has_element?(lv, "#group-edit-location:not(.hidden)")
  end

  test "going back to a point removes the area when saved", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, area} = GroupAreas.decode(square(@ns, 0.05))
    {:ok, group} = Social.update_group(owner, group, %{"area" => area})

    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-point") |> render_click()
    assert_push_event(lv, "location_mode", %{mode: "point"})

    save(lv)

    saved = Social.load_area(Repo.get!(Group, group.id))
    assert saved.area == nil
    # The pin stays where the area had it.
    assert {saved.latitude, saved.longitude} == {group.latitude, group.longitude}
  end

  test "discarding puts the saved border back on the map", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)
    lv |> element("#group-location-mode-area") |> render_click()
    send_area(lv, square(@ns, 0.05))

    lv |> element("#group-edit-discard") |> render_click()

    assert_push_event(lv, "location_reset", %{area: nil, mode: "point"})
    save(lv)
    assert Social.load_area(Repo.get!(Group, group.id)).area == nil
  end

  test "the card says which areas its pin lies in", %{conn: conn, owner: owner} do
    {_account, other} = account_with_profile!("area-card-other")
    {:ok, city_area} = GroupAreas.decode(square(@ns, 0.2))
    city = group_with_members!(other, [], %{"name" => "Grad", "is_public" => true})
    {:ok, city} = Social.update_group(other, city, %{"area" => city_area})

    {lat, lng} = @ns
    group = group_with_members!(owner, [], %{"latitude" => lat, "longitude" => lng})
    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-location-within-#{city.id}", "Grad")

    render_hook(lv, "edit_group_point_areas", %{"lat" => 43.0, "lng" => 21.0})
    refute has_element?(lv, "#group-location-within")

    render_hook(lv, "edit_group_point_areas", %{"lat" => lat, "lng" => lng})
    assert has_element?(lv, "#group-location-within-#{city.id}")

    # A drawn area bigger than the city does not lie in it.
    lv |> element("#group-location-mode-area") |> render_click()
    send_area(lv, square(@ns, 0.5))
    refute has_element?(lv, "#group-location-within")

    send_area(lv, square(@ns, 0.05))
    assert has_element?(lv, "#group-location-within-#{city.id}")
  end
end
