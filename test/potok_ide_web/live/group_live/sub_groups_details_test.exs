defmodule PotokIdeWeb.GroupLive.SubGroupsDetailsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("details-owner")
    {viewer_account, viewer} = account_with_profile!("details-viewer")
    parent = group_with_members!(owner, [viewer])

    %{
      owner_account: owner_account,
      owner: owner,
      viewer_account: viewer_account,
      viewer: viewer,
      parent: parent
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => zone()})
    |> live(path)
  end

  test "a sub-group shows when it was last active, its members and its sub-groups", ctx do
    child = group_with_members!(ctx.owner, [ctx.viewer], %{parent: ctx.parent})
    group_with_members!(ctx.owner, [ctx.viewer], %{parent: child})
    {:ok, _value} = Social.create_value(ctx.owner, child, %{"content" => "hello"})

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#child-group-last-value-#{child.id}[datetime]")
    assert has_element?(lv, "#child-group-members-#{child.id}", "2")
    assert has_element?(lv, "#child-group-sub-groups-#{child.id}", "1")
    refute has_element?(lv, "#child-group-not-member-#{child.id}")
  end

  test "a new value brings the time and keeps the counts", ctx do
    child = group_with_members!(ctx.owner, [ctx.viewer], %{parent: ctx.parent})
    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    refute has_element?(lv, "#child-group-last-value-#{child.id}")
    refute has_element?(lv, "#child-group-sub-groups-#{child.id}")

    {:ok, _value} = Social.create_value(ctx.owner, child, %{"content" => "news"})

    assert has_element?(lv, "#child-group-last-value-#{child.id}[datetime]")
    assert has_element?(lv, "#child-group-members-#{child.id}", "2")
  end

  test "public sub-groups the viewer has not joined say so", ctx do
    open = group_with_members!(ctx.owner, [], %{:parent => ctx.parent, "is_public" => true})

    joined =
      group_with_members!(ctx.owner, [ctx.viewer], %{:parent => ctx.parent, "is_public" => true})

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#child-group-not-member-#{open.id}")
    assert has_element?(lv, "#child-group-members-#{open.id}", "1")
    refute has_element?(lv, "#child-group-not-member-#{joined.id}")
  end
end
