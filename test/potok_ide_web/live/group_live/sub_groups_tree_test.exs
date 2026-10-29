defmodule PotokIdeWeb.GroupLive.SubGroupsTreeTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  setup %{conn: conn} do
    {account, profile} = account_with_profile!("tree-owner")
    group = group!(profile, Social.get_root_group!(), "tree-group")
    child = group!(profile, group, "child-folder")
    grandchild = group!(profile, child, "grandchild")
    sibling = group!(profile, group, "sibling-folder")

    %{
      conn: log_in_account(conn, account),
      profile: profile,
      group: group,
      child: child,
      grandchild: grandchild,
      sibling: sibling
    }
  end

  test "switches to folders and back, keeping the view in the URL", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    assert has_element?(lv, "#group-children-list #child-group-#{ctx.child.id}")
    refute has_element?(lv, "#group-children-tree")
    assert has_element?(lv, "#group-children-view-flip[phx-value-view=tree]")

    lv |> element("#group-children-view-tree") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")
    assert has_element?(lv, "#group-children-view-flip[phx-value-view=list]")

    assert has_element?(
             lv,
             "#group-children-tree #sub-group-folder-#{ctx.child.id} #sub-group-folder-#{ctx.grandchild.id}"
           )

    assert has_element?(lv, "#sub-group-folder-#{ctx.sibling.id}")
    refute has_element?(lv, "#sub-group-folder-#{ctx.child.id}[open]")
    refute has_element?(lv, "#group-children-list")

    assert has_element?(
             lv,
             "#sub-group-folder-link-#{ctx.grandchild.id}[href='/groups/#{ctx.grandchild.id}']"
           )

    lv |> element("#group-children-view-list") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/sub_groups")

    assert has_element?(lv, "#group-children-list #child-group-#{ctx.child.id}")
    refute has_element?(lv, "#group-children-tree")
  end

  test "a search opens the folders on the way to the matches", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

    assert has_element?(lv, "#group-children-tree")

    lv
    |> form("#group-children-search-form", %{"children_search" => %{"q" => "grand"}})
    |> render_change()

    assert has_element?(lv, "#sub-group-search-folder-#{ctx.child.id}[open]")
    assert has_element?(lv, "#sub-group-search-folder-#{ctx.grandchild.id}")
    assert has_element?(lv, "#sub-group-folder-link-#{ctx.grandchild.id} .bg-yellow-300", "grand")
    refute has_element?(lv, "#sub-group-search-folder-#{ctx.sibling.id}")

    lv
    |> form("#group-children-search-form", %{"children_search" => %{"q" => "no-match"}})
    |> render_change()

    assert has_element?(lv, "#group-children-empty")
    refute has_element?(lv, "#group-children-tree")

    lv |> element("#group-children-search-reset") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.child.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.sibling.id}")
  end

  test "shows unread values on the folders that hold them", ctx do
    {_other_account, other} = account_with_profile!("tree-poster")
    {:ok, invitation} = Social.invite_profile_to_group(ctx.profile, ctx.grandchild, other)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, other)
    {:ok, _value} = Social.create_value(other, ctx.grandchild, %{"content" => "news"})

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

    assert has_element?(lv, "#sub-group-folder-unread-#{ctx.child.id}", "1")
    assert has_element?(lv, "#sub-group-folder-unread-#{ctx.grandchild.id}", "1")
    refute has_element?(lv, "#sub-group-folder-unread-#{ctx.sibling.id}")
  end

  test "the threads switch hides threads anywhere in the tree", ctx do
    {:ok, value} = Social.create_value(ctx.profile, ctx.child, %{"content" => "thread start"})

    {:ok, thread} =
      Social.get_or_create_value_thread(ctx.profile, ctx.child, value, %{"name" => "talk"})

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

    assert has_element?(lv, "#sub-group-folder-#{ctx.child.id} #sub-group-folder-#{thread.id}")

    lv |> element("#group-children-threads-toggle") |> render_click()

    refute has_element?(lv, "#sub-group-folder-#{thread.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.grandchild.id}")
  end

  test "direct conversations on the root group stay a list", %{conn: conn} do
    root_group = Social.get_root_group!()

    {:ok, lv, _html} =
      live(conn, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=direct&view=tree")

    refute has_element?(lv, "#group-children-view")
    refute has_element?(lv, "#group-children-view-flip")
    refute has_element?(lv, "#group-children-tree")

    lv |> element("#group-sub-groups-kind-other") |> render_click()
    assert_patch(lv, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=other")

    assert has_element?(lv, "#group-children-view")
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {Accounts.get_account!(account.id), profile}
  end

  defp group!(profile, parent, name) do
    {:ok, group} =
      Social.create_group(profile, parent, %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    group
  end
end
