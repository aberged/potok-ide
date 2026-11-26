defmodule PotokIdeWeb.GroupLive.PushClearTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  @chat_kinds ["message", "mention", "reply", "reaction"]

  setup do
    {owner_account, owner} = account_with_profile!("clear-owner")
    {member_account, member} = account_with_profile!("clear-member")
    parent = group_with_members!(owner, [member], %{"name" => "clear-parent"})
    child = group_with_members!(owner, [member], %{:parent => parent, "name" => "clear-child"})

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

  test "opening a chat clears its notifications from the device", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.child.id}/values")

    assert_push_event(lv, "push:clear", %{group_id: group_id, kinds: @chat_kinds})
    assert group_id == ctx.child.id
  end

  test "a chat read on another page of the profile is cleared here too", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.parent.id}/sub_groups")
    {:ok, _value} = Social.create_value(ctx.owner, ctx.child, %{"content" => "news"})

    :ok = Social.mark_group_values_read(ctx.member, ctx.child)
    # The broadcast is in the page's mailbox: a render waits until it is handled.
    _ = render(lv)

    child_id = ctx.child.id
    assert_push_event(lv, "push:clear", %{group_id: ^child_id, kinds: @chat_kinds})
  end

  test "writing in a chat on another page clears it, another profile's reading does not", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.parent.id}/sub_groups")
    child_id = ctx.child.id

    {:ok, _value} = Social.create_value(ctx.member, ctx.child, %{"content" => "mine"})
    _ = render(lv)
    assert_push_event(lv, "push:clear", %{group_id: ^child_id})

    {:ok, _value} = Social.create_value(ctx.owner, ctx.child, %{"content" => "news"})
    :ok = Social.mark_group_values_read(ctx.owner, ctx.child)
    _ = render(lv)

    refute_push_event(lv, "push:clear", %{group_id: ^child_id})
  end
end
