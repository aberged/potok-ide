defmodule PotokIdeWeb.GroupLive.AccessTabTest do
  @moduledoc """
  The access overview on a group's page: every member sees it whole and sees
  it as any roles; someone outside a public group sees only what they may do
  and how one comes in, with no names; nothing the viewer does not see is
  told.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("at-owner")
    {member_account, member} = account_with_profile!("at-member")
    {visitor_account, _visitor} = account_with_profile!("at-visitor")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "at-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    add_member!(owner, group, member)
    {:ok, _} = Social.create_own_group_manifest(owner, group)
    {:ok, savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, muted} = Social.create_group_role(owner, group, %{"name" => "muted"})
    {:ok, _} = Social.set_group_role_permission(owner, group, savet.key, :delete_values, :allow)
    {:ok, _} = Social.set_group_role_permission(owner, group, muted.key, :post_values, :deny)
    {:ok, _} = Social.assign_group_member_role(owner, group, member.id, savet.key)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      group: Social.get_group!(group.id),
      savet: savet,
      muted: muted
    }
  end

  defp open(account, group) do
    build_conn() |> log_in_account(account) |> live(~p"/groups/#{group.id}/access")
  end

  test "a member sees the whole overview, from the group's menu too", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    assert has_element?(lv, "#group-panel-access")
    assert has_element?(lv, "#group-tab-access")
    assert has_element?(lv, "#access-view-presets")
    assert has_element?(lv, "#access-table")
    assert has_element?(lv, "#access-power-delete_values", "2 people")
    assert has_element?(lv, "#access-statute")
    assert has_element?(lv, "#access-changes")
    # Themselves first: savet lets them delete others' messages.
    assert has_element?(lv, "#access-view-label", "You")
    assert has_element?(lv, ~s(#access-row-delete_values[data-ok="true"]))

    # Who holds a role leads to the Members tab narrowed to it.
    assert has_element?(
             lv,
             ~s(#access-role-#{ctx.savet.key}-members[href="/groups/#{ctx.group.id}/members?role=#{ctx.savet.key}"])
           )
  end

  test "roles picked together: a denial wins over what another role allows", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    lv
    |> form("#access-view-roles-form", %{"roles" => [ctx.savet.key, ctx.muted.key]})
    |> render_change()

    assert has_element?(lv, "#access-view-label", "savet + muted")
    assert has_element?(lv, ~s(#access-row-post[data-ok="false"]), "Denied by muted")
    assert has_element?(lv, ~s(#access-row-delete_values[data-ok="true"]))

    lv |> element("#access-view-preset-outsider") |> render_click()
    assert has_element?(lv, "#access-view-label", "Someone outside the group")
    assert has_element?(lv, ~s(#access-row-read_chat[data-ok="false"]))
    assert has_element?(lv, ~s(#access-row-ask[data-ok="true"]))

    lv |> element("#access-view-preset-self") |> render_click()
    assert has_element?(lv, "#access-view-label", "You")
  end

  test "the table holds every role and the outsiders of a public group", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    assert has_element?(lv, ~s(#access-cell-delete_values-#{ctx.savet.key}[data-ok="true"]))
    assert has_element?(lv, ~s(#access-cell-post-#{ctx.muted.key}[data-ok="false"]))
    assert has_element?(lv, ~s(#access-cell-post-everyone[data-ok="true"]))
    assert has_element?(lv, ~s(#access-cell-read_chat-outsider[data-ok="false"]))
    assert has_element?(lv, "#access-col-guest")
  end

  test "someone outside sees what they may do and how one comes in, with no names", ctx do
    {:ok, lv, html} = open(ctx.visitor_account, ctx.group)

    assert has_element?(lv, "#group-panel-access")
    assert has_element?(lv, "#access-rows")
    assert has_element?(lv, ~s(#access-row-ask[data-ok="true"]))
    assert has_element?(lv, "#access-join-rule")
    refute has_element?(lv, "#access-view-presets")
    refute has_element?(lv, "#access-table")
    refute has_element?(lv, "#access-power")
    refute has_element?(lv, "#access-role-#{ctx.savet.key}-members")

    panel = lv |> element("#group-panel-access") |> render()
    refute panel =~ ctx.owner.username
    refute panel =~ ctx.member.username
    assert html =~ "at-group"
  end

  test "a sub-group or a description the viewer does not see is not told", ctx do
    {:ok, closed} =
      Social.create_group(ctx.owner, ctx.group, %{
        "name" => "at-closed-sub",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false,
        "inherits_members" => false
      })

    {:ok, open_sub} =
      Social.create_group(ctx.owner, ctx.group, %{
        "name" => "at-open-sub",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    assert has_element?(lv, "#access-child-#{open_sub.id}")
    refute has_element?(lv, "#access-child-#{closed.id}")
    refute render(lv) =~ "at-closed-sub"
  end

  test "a private group is seen by its members only, and so is its overview", ctx do
    {:ok, private} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "at-private",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    assert {:error, {:live_redirect, %{to: "/groups"}}} = open(ctx.visitor_account, private)

    {:ok, lv, _html} = open(ctx.owner_account, private)
    assert has_element?(lv, "#group-panel-access")
    refute has_element?(lv, "#access-view-preset-outsider")
    assert has_element?(lv, "#access-join-rule", "invitation")
  end
end
