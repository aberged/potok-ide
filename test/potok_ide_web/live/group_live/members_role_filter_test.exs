defmodule PotokIdeWeb.GroupLive.MembersRoleFilterTest do
  @moduledoc """
  The Members tab narrowed to those who hold one role (`?role=`), which the
  access overview links to.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.Access

  setup do
    {owner_account, owner} = account_with_profile!("mrf-owner")
    {_member_account, member} = account_with_profile!("mrf-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "mrf-group",
        "description" => "",
        "description_format" => :markdown
      })

    add_member!(owner, group, member)
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, _} = Social.assign_group_member_role(owner, group, member.id, role.key)

    %{owner_account: owner_account, owner: owner, member: member, group: group, role: role}
  end

  defp open(ctx, query) do
    build_conn()
    |> log_in_account(ctx.owner_account)
    |> live(~p"/groups/#{ctx.group.id}/members?#{query}")
  end

  test "a role narrows the list to those who hold it", ctx do
    {:ok, lv, _html} = open(ctx, role: ctx.role.key)

    assert has_element?(lv, "#group-members-list", ctx.member.username)
    refute has_element?(lv, "#group-members-list", ctx.owner.username)
    assert has_element?(lv, "#group-members-count", "1 member holds the role")

    # Admin is a role like any other: the owner holds it, the member does not.
    {:ok, lv, _html} = open(ctx, role: "admin")
    assert has_element?(lv, "#group-members-list", ctx.owner.username)
    refute has_element?(lv, "#group-members-list", ctx.member.username)
  end

  test "the menu of roles patches the address, and All members brings everyone back", ctx do
    {:ok, lv, _html} = open(ctx, [])
    assert has_element?(lv, "#group-members-count", "2 members")

    lv |> element("#group-members-role-option-#{ctx.role.key}") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/members?#{[role: ctx.role.key]}")
    refute has_element?(lv, "#group-members-list", ctx.owner.username)

    lv |> element("#group-members-role-option-all") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/members")
    assert has_element?(lv, "#group-members-list", ctx.owner.username)
    assert has_element?(lv, "#group-members-list", ctx.member.username)
  end

  test "a member whose role is taken away leaves the narrowed list", ctx do
    {:ok, lv, _html} = open(ctx, role: ctx.role.key)
    assert has_element?(lv, "#member-#{ctx.member.id}")

    lv |> element("#member-#{ctx.member.id}-role-#{ctx.role.key}") |> render_click()

    refute has_element?(lv, "#member-#{ctx.member.id}")
  end

  test "a key the manifest lacks, or Everyone, narrows nothing", ctx do
    for key <- ["no-such-role", "everyone"] do
      {:ok, lv, _html} = open(ctx, role: key)
      assert has_element?(lv, "#group-members-list", ctx.owner.username)
      assert has_element?(lv, "#group-members-list", ctx.member.username)
    end
  end

  test "a role nobody holds says so", ctx do
    {:ok, other} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "nobody"})
    {:ok, lv, _html} = open(ctx, role: other.key)

    assert has_element?(lv, "#group-members-empty", "Nobody holds this role.")
    assert Social.count_group_members(ctx.group, role: other.key) == 0
    assert Social.count_group_members(ctx.group, role: ctx.role.key) == 1
    assert Access.role_member_counts(ctx.group)[ctx.role.key] == 1
  end
end
