defmodule PotokIdeWeb.GroupLive.LeaveGroupTest do
  @moduledoc """
  "Leave the group" in the group's menu: a member leaves a private group for
  its parent, stays on a public one as an outsider, and hears why when they
  may not leave.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("lvg-owner")
    {member_account, member} = account_with_profile!("lvg-member")
    private = group_with_members!(owner, [member])
    public = group_with_members!(owner, [member], %{"is_public" => true})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      private: private,
      public: public
    }
  end

  defp open(account, group) do
    build_conn() |> log_in_account(account) |> live(~p"/groups/#{group.id}")
  end

  test "a member leaves a private group and lands on its parent", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ctx.private)

    assert has_element?(lv, "#group-leave[data-confirm]", "Leave the group")

    assert {:error, {:live_redirect, %{to: to}}} =
             render_click(lv, "group_leave", %{"id" => to_string(ctx.private.id)})

    assert to == ~p"/groups/#{ctx.private.parent_id}"
    refute Social.member_of_group?(ctx.member, ctx.private)
  end

  test "a member who leaves a public group stays on its page", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ctx.public)

    assert {:error, {:live_redirect, %{to: to}}} =
             render_click(lv, "group_leave", %{"id" => to_string(ctx.public.id)})

    assert to == ~p"/groups/#{ctx.public.id}"
    refute Social.member_of_group?(ctx.member, ctx.public)
  end

  test "the last admin hears why they cannot leave", ctx do
    {:ok, lv, _html} = open(ctx.owner_account, ctx.private)

    assert render_click(lv, "group_leave", %{"id" => to_string(ctx.private.id)}) =~
             "A group must keep at least one admin."

    assert Social.member_of_group?(ctx.owner, ctx.private)
  end

  test "the root offers no leaving", ctx do
    {:ok, lv, _html} = open(ctx.member_account, Social.get_root_group!())
    refute has_element?(lv, "#group-leave")
  end
end
