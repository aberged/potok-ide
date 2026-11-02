defmodule PotokIdeWeb.ProfileLive.EditTagsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Tags
  alias PotokIde.Tags.Tag

  test "a profile puts public tags on itself from its edit page", %{conn: conn} do
    {account, profile} = account_with_profile!("ptag-owner")
    {_account, other} = account_with_profile!("ptag-other")
    {:ok, _private} = Tags.add_tag(profile, :profile, profile.id, "note to self", :private)

    {:ok, lv, _html} = conn |> log_in_account(account) |> live(~p"/profiles/#{profile.id}/edit")

    # Only public tags show here.
    assert has_element?(lv, "#profile-tags-empty")

    lv |> element("#profile-tags-edit") |> render_click()
    assert has_element?(lv, "#tag-editor-public-note")
    refute has_element?(lv, "#tag-editor-visibility")

    lv |> form("#tag-editor-form", tag: %{name: "Gardening"}) |> render_submit()

    assert [%Tag{owner_id: nil} = tag] =
             Tags.tags_for(other, :profile, [profile.id]) |> Map.fetch!(profile.id)

    assert has_element?(lv, "#profile-tag-list-#{tag.id}", "Gardening")
    assert has_element?(lv, "#tag-editor-tag-#{tag.id}")

    lv |> element("#tag-editor-remove-#{tag.id}") |> render_click()
    refute has_element?(lv, "#profile-tag-list-#{tag.id}")
    assert has_element?(lv, "#profile-tags-empty")
  end
end
