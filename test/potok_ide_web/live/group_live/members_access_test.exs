defmodule PotokIdeWeb.GroupLive.MembersAccessTest do
  @moduledoc """
  Members of a group, with their roles, are shown to its members only. The bar
  of sections never offered the tab to others, and the address no longer opens
  it for them.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("ma-owner")
    {visitor_account, _visitor} = account_with_profile!("ma-visitor")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "ma-group",
        "description" => "The text",
        "description_format" => :markdown,
        "is_public" => true
      })

    %{owner_account: owner_account, owner: owner, visitor_account: visitor_account, group: group}
  end

  test "a member opens the Members tab", ctx do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.owner_account)
      |> live(~p"/groups/#{ctx.group.id}/members")

    assert has_element?(lv, "#group-panel-members")
    assert has_element?(lv, "#group-members-list", ctx.owner.username)
  end

  test "someone outside a public group gets its first tab at the Members address", ctx do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(ctx.visitor_account)
      |> live(~p"/groups/#{ctx.group.id}/members")

    refute has_element?(lv, "#group-panel-members")
    refute has_element?(lv, "#group-members-list")
    refute has_element?(lv, "#group-members-summary")
  end
end
