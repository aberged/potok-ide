defmodule PotokIdeWeb.GroupLive.LinkCardSettingsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("card-set-owner")
    %{conn: log_in_account(conn, account), owner: owner}
  end

  defp settings(conn, group), do: live(conn, ~p"/groups/#{group.id}/edit_group")

  test "a public group shows what a link to it looks like", %{conn: conn, owner: owner} do
    group =
      group_with_members!(owner, [], %{
        "name" => "Komšije",
        "description" => "Dogovaramo akcije.",
        "is_public" => true
      })

    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-edit-link-card", "Komšije")
    assert has_element?(lv, "#group-edit-link-card-description", "Dogovaramo akcije.")
    assert has_element?(lv, ~s(#group-edit-link-card-image[src*="/cards/group/#{group.id}.jpg"]))
    refute has_element?(lv, "#group-edit-link-card-add-description")
    refute has_element?(lv, "#group-edit-link-card-add-meta")
  end

  test "asks for a description the card can show", %{conn: conn, owner: owner} do
    group = group_with_members!(owner, [], %{"is_public" => true})

    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-edit-link-card-add-description")

    lv
    |> form("#group-edit-form", %{"group" => %{"description" => "Dogovaramo akcije."}})
    |> render_submit()

    assert has_element?(lv, "#group-edit-link-card-description", "Dogovaramo akcije.")
    refute has_element?(lv, "#group-edit-link-card-add-description")
  end

  test "tells an app how to describe itself", %{conn: conn, owner: owner} do
    group =
      group_with_members!(owner, [], %{
        "description" => "<div>app</div>",
        "uses_api" => true,
        "is_public" => true
      })

    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-edit-link-card-add-meta")
    refute has_element?(lv, "#group-edit-link-card-add-description")
  end

  test "an app that describes itself needs no advice", %{conn: conn, owner: owner} do
    group =
      group_with_members!(owner, [], %{
        "description" => ~s(<meta name="description" content="Igra pamćenja.">),
        "uses_api" => true,
        "is_public" => true
      })

    {:ok, lv, _html} = settings(conn, group)

    assert has_element?(lv, "#group-edit-link-card-description", "Igra pamćenja.")
    refute has_element?(lv, "#group-edit-link-card-add-meta")
  end

  test "a private group has no card to show", %{conn: conn, owner: owner} do
    {:ok, lv, _html} = settings(conn, group_with_members!(owner, []))

    assert has_element?(lv, "#group-edit-form")
    refute has_element?(lv, "#group-edit-link-card")
  end

  test "the card appears when the group opens up", %{conn: conn, owner: owner} do
    {:ok, lv, _html} = settings(conn, group_with_members!(owner, []))

    lv |> form("#group-edit-form", %{"group" => %{"is_public" => "true"}}) |> render_submit()

    assert has_element?(lv, "#group-edit-link-card")
  end
end
