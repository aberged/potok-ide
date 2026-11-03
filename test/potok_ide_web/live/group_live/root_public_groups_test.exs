defmodule PotokIdeWeb.GroupLive.RootPublicGroupsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {_owner_account, owner} = account_with_profile!("rootpub-owner")
    {viewer_account, viewer} = account_with_profile!("rootpub-viewer")
    root = Social.get_root_group!()

    # Named so the folder view sorts them mine, way, open: LiveViewTest cannot
    # render a folder that moves and changes in one patch (it leaves the
    # template references of keyed `[old_index, diff]` entries unresolved),
    # which showing `open` before `mine` would do. Browsers render it.
    mine = group_with_members!(owner, [viewer], %{"name" => "rootpub-a-mine"})
    open = group_with_members!(owner, [], %{"name" => "rootpub-c-open", "is_public" => true})

    # Public and the viewer is not in it, but in a group below it.
    way = group_with_members!(owner, [], %{"name" => "rootpub-b-way", "is_public" => true})
    below = group_with_members!(owner, [viewer], %{parent: way})

    %{
      owner: owner,
      viewer_account: viewer_account,
      root: root,
      mine: mine,
      open: open,
      way: way,
      below: below
    }
  end

  defp live_as(account, path, connect_params \\ %{}) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(connect_params)
    |> live(path)
  end

  test "the root hides public groups the viewer is not in until shown", ctx do
    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/sub_groups")

    assert has_element?(lv, "#group-children-public-toggle[aria-pressed='false']")
    assert has_element?(lv, "#child-group-#{ctx.mine.id}")
    assert has_element?(lv, "#child-group-#{ctx.way.id}")
    refute has_element?(lv, "#child-group-#{ctx.open.id}")

    lv |> element("#group-children-public-toggle") |> render_click()

    # The browser keeps the choice for the next pages.
    assert_push_event(lv, "sub_groups_public", %{shown: true})
    assert has_element?(lv, "#group-children-public-toggle[aria-pressed='true']")
    assert has_element?(lv, "#child-group-#{ctx.open.id}")

    lv |> element("#group-children-public-toggle") |> render_click()

    assert_push_event(lv, "sub_groups_public", %{shown: false})
    refute has_element?(lv, "#child-group-#{ctx.open.id}")
  end

  test "the browser's last choice shows them from the start", ctx do
    {:ok, lv, _html} =
      live_as(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/sub_groups", %{
        "show_public_groups" => true
      })

    assert has_element?(lv, "#group-children-public-toggle[aria-pressed='true']")
    assert has_element?(lv, "#child-group-#{ctx.open.id}")
  end

  test "an empty root offers to show them", ctx do
    {newcomer_account, _newcomer} = account_with_profile!("rootpub-new")

    {:ok, lv, _html} = live_as(newcomer_account, ~p"/groups/#{ctx.root.id}/sub_groups")

    assert has_element?(lv, "#group-children-empty")
    refute has_element?(lv, "#child-group-#{ctx.open.id}")

    lv |> element("#group-children-show-public") |> render_click()

    assert_push_event(lv, "sub_groups_public", %{shown: true})
    assert has_element?(lv, "#child-group-#{ctx.open.id}")
    refute has_element?(lv, "#group-children-show-public")
  end

  test "the folder view hides them on every level", ctx do
    mine_open = group_with_members!(ctx.owner, [], %{:parent => ctx.mine, "is_public" => true})

    {:ok, lv, _html} =
      live_as(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/sub_groups?view=tree")

    assert has_element?(lv, "#sub-group-folder-#{ctx.mine.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.way.id}")
    refute has_element?(lv, "#sub-group-folder-#{ctx.open.id}")
    # Nothing left to open below the viewer's own group.
    refute has_element?(lv, "#sub-group-folder-toggle-#{ctx.mine.id}")

    lv |> element("#sub-group-folder-toggle-#{ctx.way.id}") |> render_click()
    assert has_element?(lv, "#sub-group-folder-#{ctx.way.id} #sub-group-folder-#{ctx.below.id}")

    lv |> element("#group-children-public-toggle") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.open.id}")
    lv |> element("#sub-group-folder-toggle-#{ctx.mine.id}") |> render_click()
    assert has_element?(lv, "#sub-group-folder-#{ctx.mine.id} #sub-group-folder-#{mine_open.id}")
  end

  test "other groups list their public sub-groups and have no switch", ctx do
    nested_open = group_with_members!(ctx.owner, [], %{:parent => ctx.mine, "is_public" => true})

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.mine.id}/sub_groups")

    refute has_element?(lv, "#group-children-public-toggle")
    assert has_element?(lv, "#child-group-#{nested_open.id}")
  end
end
