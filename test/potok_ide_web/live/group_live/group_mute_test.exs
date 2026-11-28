defmodule PotokIdeWeb.GroupLive.GroupMuteTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("mute-owner")
    {member_account, member} = account_with_profile!("mute-member")
    parent = group_with_members!(owner, [member], %{"name" => "mute-parent"})
    child = group_with_members!(owner, [member], %{:parent => parent, "name" => "mute-child"})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      parent: parent,
      child: child
    }
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  test "a member mutes the open group from its menu and turns it on again", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.child.id}/values")
    open_group_menu(lv)

    assert has_element?(lv, "#group-mute")
    refute has_element?(lv, "#group-muted-#{ctx.child.id}")

    lv |> element("#group-mute-hour") |> render_click()

    assert has_element?(lv, "#group-muted-#{ctx.child.id}")
    assert has_element?(lv, "#group-unmute")
    assert has_element?(lv, "#group-muted-until")
    assert Social.group_muted_until(ctx.member, ctx.child)

    lv |> element("#group-unmute") |> render_click()

    refute has_element?(lv, "#group-muted-#{ctx.child.id}")
    assert has_element?(lv, "#group-mute")
    refute Social.group_muted_until(ctx.member, ctx.child)
  end

  test "until turned on, the menu says so", ctx do
    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.child, "forever")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.child.id}/values")
    open_group_menu(lv)

    assert has_element?(lv, "#group-unmute")
    refute has_element?(lv, "#group-muted-until")
  end

  test "a silenced group's row counts in grey, out of the badge", ctx do
    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.child, "hour")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#group-muted-#{ctx.child.id}")

    {:ok, _} = Social.create_value(ctx.owner, ctx.child, %{"content" => "quietly"})
    _ = render(lv)

    assert has_element?(lv, "#group-muted-unread-badge-#{ctx.child.id}", "1")
    refute has_element?(lv, "#group-unread-badge-#{ctx.child.id}")
    assert has_element?(lv, "#nav-root-group-unread-badge[hidden]")
  end

  test "a row's menu mutes its group", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    lv |> element("#group-row-menu-button-#{ctx.child.id}") |> render_click()
    lv |> element("#group-row-mute-week") |> render_click()

    assert Social.group_muted_until(ctx.member, ctx.child)
    assert has_element?(lv, "#group-muted-#{ctx.child.id}")
  end

  test "a thread follows its conversation and offers no mute of its own", ctx do
    {:ok, value} = Social.create_value(ctx.owner, ctx.child, %{"content" => "start"})

    {:ok, thread} =
      Social.get_or_create_value_thread(ctx.owner, ctx.child, value, %{"name" => "nit"})

    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.child, "hour")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{thread.id}/values")
    open_group_menu(lv)

    assert has_element?(lv, "#group-muted-#{thread.id}")
    refute has_element?(lv, "#group-mute")
    refute has_element?(lv, "#group-unmute")
  end

  test "someone outside the group is offered no mute", ctx do
    {:ok, public} =
      Social.create_group(ctx.owner, ctx.parent, %{
        "name" => "mute-public",
        "description" => "",
        "is_public" => true
      })

    {stranger_account, _stranger} = account_with_profile!("mute-stranger")
    {:ok, lv, _html} = live_as(stranger_account, ~p"/groups/#{public.id}/group_home")
    open_group_menu(lv)

    refute has_element?(lv, "#group-mute")
  end
end
