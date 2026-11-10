defmodule PotokIdeWeb.GroupLive.GroupLocationSettingsTest do
  @moduledoc """
  The "Location" card of a group's settings: where the group stands on a map
  and the pin it shows there.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, GroupPins}

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("location-owner")
    %{conn: log_in_account(conn, account), owner: owner}
  end

  defp settings(conn, group), do: live(conn, ~p"/groups/#{group.id}/edit_group")

  defp save(lv, attrs) do
    lv |> form("#group-edit-form", %{"group" => attrs}) |> render_submit()
  end

  test "offers a map, the coordinates and every pin", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-edit-tab-location[aria-controls='group-edit-location']")

    assert has_element?(
             lv,
             "#group-location-map[phx-hook='LocationPicker'][data-tiles^='/tiles/']"
           )

    assert has_element?(lv, "#group-edit-latitude")
    assert has_element?(lv, "#group-edit-longitude")
    assert has_element?(lv, "#group-location-locate[hidden]")

    assert has_element?(lv, "#group-edit-pin-kind input[value=''][checked]")
    assert has_element?(lv, "#group-edit-pin-picture input[value='picture']")

    for {key, _icon, _tone} <- GroupPins.icons() do
      assert has_element?(lv, "#group-edit-pin-#{key} svg path")
    end
  end

  test "the picked pins show the group's kind in their corner, as on the map",
       %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    # A group of no kind has no mark, on its avatar or on its pin.
    refute has_element?(lv, "#group-edit-pins [data-pin-mark]")

    group |> Ecto.Changeset.change(preset: :chat) |> Repo.update!()
    {:ok, lv, _html} = settings(conn, group)

    refute has_element?(lv, "#group-edit-pin-kind [data-pin-mark]")
    assert has_element?(lv, "#group-edit-pin-picture [data-pin-mark]")
    assert has_element?(lv, "#group-edit-pin-shop [data-pin-mark]")
  end

  test "saves the place and the pin, and clears them again", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    save(lv, %{"latitude" => "44.817", "longitude" => "20.457", "pin_icon" => "school"})

    group = Repo.get!(Group, group.id)
    assert {group.latitude, group.longitude, group.pin_icon} == {44.817, 20.457, "school"}

    {:ok, lv, _html} = settings(conn, group)
    assert has_element?(lv, "#group-edit-pin-school input[checked]")

    save(lv, %{"latitude" => "", "longitude" => "", "pin_icon" => ""})

    group = Repo.get!(Group, group.id)
    assert {group.latitude, group.longitude, group.pin_icon} == {nil, nil, nil}
  end

  test "a wrong coordinate opens the card with the error", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [])
    {:ok, lv, _html} = settings(conn, group)

    save(lv, %{"latitude" => "95", "longitude" => "20"})

    assert has_element?(lv, "#group-edit-location:not(.hidden)")
    assert has_element?(lv, "#group-edit-tab-location[aria-selected='true']")
    assert Repo.get!(Group, group.id).latitude == nil
  end
end
