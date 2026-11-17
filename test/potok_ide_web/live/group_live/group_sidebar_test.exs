defmodule PotokIdeWeb.GroupLive.GroupSidebarTest do
  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.{Notices, Repo, Social}
  alias PotokIde.Social.Group

  setup do
    {owner_account, owner} = account_with_profile!("side-owner")
    {member_account, member} = account_with_profile!("side-member")
    lift = group_with_members!(owner, [member], %{"name" => "side-lift"})
    garden = group_with_members!(owner, [member], %{"name" => "side-garden"})
    {:ok, _} = Social.create_value(owner, lift, %{"content" => "the lift is stuck"})
    {:ok, _} = Social.create_value(owner, garden, %{"content" => "we plant on Sunday"})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      lift: lift,
      garden: garden
    }
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp load(lv, params \\ %{}) do
    lv |> element("#group-sidebar") |> render_hook("group_sidebar_load", params)
    lv
  end

  # A public building the member is not in, with an entrance the member is in.
  defp building(ctx) do
    building =
      group_with_members!(ctx.owner, [], %{"name" => "side-building", "is_public" => true})

    entrance =
      group_with_members!(ctx.owner, [ctx.member], %{
        :parent => building,
        "name" => "side-entrance"
      })

    {:ok, _} = Social.create_value(ctx.owner, entrance, %{"content" => "the door is open"})
    {building, entrance}
  end

  test "it waits for the browser before it loads, then shows the viewer's groups", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")

    assert has_element?(lv, "#group-sidebar #group-sidebar-loading")
    refute has_element?(lv, "#group-sidebar-tree")

    load(lv)

    assert has_element?(lv, "#group-sidebar-link-#{ctx.lift.id}[aria-current=page]")
    assert has_element?(lv, "#group-sidebar-node-#{ctx.garden.id}", "side-garden")

    # Each row shows the group's own avatar.
    assert has_element?(
             lv,
             ~s(#group-sidebar-link-#{ctx.garden.id} img[src^="/avatar/group/#{ctx.garden.id}?"])
           )

    # The garden has something unread; the open lift was just read.
    assert has_element?(lv, "#group-sidebar-unread-#{ctx.garden.id}:not([hidden])", "1")
    refute has_element?(lv, "#group-sidebar-unread-#{ctx.lift.id}:not([hidden])")
  end

  test "a folder on the way to a membership counts its sub-tree until it opens", ctx do
    {building, entrance} = building(ctx)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    # Not a member of the building: a folder on the way, closed, with the
    # entrance's unread value on it.
    assert has_element?(lv, "#group-sidebar-node-#{building.id}[aria-expanded=false]")
    assert has_element?(lv, "#group-sidebar-unread-#{building.id}:not([hidden])", "1")
    refute has_element?(lv, "#group-sidebar-node-#{entrance.id}")

    lv |> element("#group-sidebar-toggle-#{building.id}") |> render_click()

    assert_push_event(lv, "group_sidebar_open", %{ids: [building_id]})
    assert building_id == building.id
    assert has_element?(lv, "#group-sidebar-node-#{building.id}[aria-expanded=true]")
    assert has_element?(lv, "#group-sidebar-node-#{entrance.id}", "side-entrance")
    assert has_element?(lv, "#group-sidebar-link-#{entrance.id} img[src*='v=']")
    assert has_element?(lv, "#group-sidebar-unread-#{entrance.id}:not([hidden])", "1")
    refute has_element?(lv, "#group-sidebar-unread-#{building.id}:not([hidden])")

    lv |> element("#group-sidebar-toggle-#{building.id}") |> render_click()
    assert_push_event(lv, "group_sidebar_open", %{ids: []})
  end

  test "the way to the page's group comes open, and so do the folders the browser keeps", ctx do
    {building, entrance} = building(ctx)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{entrance.id}/values")
    load(lv)

    assert has_element?(lv, "#group-sidebar-node-#{building.id}[aria-expanded=true]")
    assert has_element?(lv, "#group-sidebar-link-#{entrance.id}[aria-current=page]")

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv, %{"open" => [building.id, "not-an-id", -3]})

    assert has_element?(lv, "#group-sidebar-node-#{entrance.id}")
  end

  test "a followed public group stands in the tree, a public group not followed does not",
       ctx do
    followed = group_with_members!(ctx.owner, [], %{"name" => "side-news", "is_public" => true})
    other = group_with_members!(ctx.owner, [], %{"name" => "side-other", "is_public" => true})
    {:ok, _follow} = Notices.follow(ctx.member, followed)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    assert has_element?(lv, "#group-sidebar-node-#{followed.id}", "side-news")
    refute has_element?(lv, "#group-sidebar-node-#{other.id}")
  end

  test "a search shows the matches with the way to them, and clearing it brings the tree back",
       ctx do
    {building, entrance} = building(ctx)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    lv
    |> form("#group-sidebar-search-form", %{"group_sidebar_search" => %{"q" => "ENTRANCE"}})
    |> render_change()

    assert has_element?(lv, "#group-sidebar-node-#{building.id}[aria-expanded=true]")
    assert has_element?(lv, "#group-sidebar-link-#{entrance.id}", "side-entrance")
    refute has_element?(lv, "#group-sidebar-node-#{ctx.garden.id}")

    lv
    |> form("#group-sidebar-search-form", %{"group_sidebar_search" => %{"q" => "nothing-here"}})
    |> render_change()

    assert has_element?(lv, "#group-sidebar-no-match")

    lv |> element("#group-sidebar-search-reset") |> render_click()

    assert has_element?(lv, "#group-sidebar-node-#{ctx.garden.id}")
    assert has_element?(lv, "#group-sidebar-node-#{building.id}[aria-expanded=false]")
    refute has_element?(lv, "#group-sidebar-no-match")
  end

  test "direct conversations stand apart, with their newest message", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
    {:ok, _} = Social.create_value(ctx.owner, direct, %{"content" => "are you home?"})

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    assert has_element?(lv, "#group-sidebar-directs #group-sidebar-direct-#{direct.id}")
    assert has_element?(lv, "#sidebar-group-last-value-#{direct.id}", "are you home?")
    assert has_element?(lv, "#sidebar-group-unread-badge-#{direct.id}:not([hidden])", "1")
    refute has_element?(lv, "#group-sidebar-tree #group-sidebar-node-#{direct.id}")
  end

  test "a new value elsewhere counts on its row", ctx do
    Social.mark_group_values_read(ctx.member, ctx.garden)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)
    refute has_element?(lv, "#group-sidebar-unread-#{ctx.garden.id}:not([hidden])")

    {:ok, _} = Social.create_value(ctx.owner, ctx.garden, %{"content" => "news from the garden"})
    _ = render(lv)
    _ = render(lv)

    assert has_element?(lv, "#group-sidebar-unread-#{ctx.garden.id}:not([hidden])", "1")
  end

  test "a silenced group counts in grey", ctx do
    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.garden, "hour")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    assert has_element?(lv, "#group-sidebar-muted-unread-#{ctx.garden.id}:not([hidden])", "1")
    assert has_element?(lv, "#group-sidebar-muted-#{ctx.garden.id}")
    refute has_element?(lv, "#group-sidebar-unread-#{ctx.garden.id}:not([hidden])")
  end

  test "the records an app keeps as groups stay out of the tree", ctx do
    log = group_with_members!(ctx.owner, [ctx.member], %{"name" => "side-log"})

    record =
      group_with_members!(ctx.owner, [ctx.member], %{:parent => log, "name" => "side-record"})

    loose = group_with_members!(ctx.owner, [ctx.member], %{"name" => "side-loose-record"})

    from(g in Group, where: g.id in ^[record.id, loose.id])
    |> Repo.update_all(set: [external_key: "accident"])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv, %{"open" => [log.id]})

    # The log is no folder any more: nothing but records is below it.
    assert has_element?(lv, "#group-sidebar-node-#{log.id}", "side-log")
    refute has_element?(lv, "#group-sidebar-toggle-#{log.id}")
    refute has_element?(lv, "#group-sidebar-node-#{record.id}")
    refute has_element?(lv, "#group-sidebar-node-#{loose.id}")

    lv
    |> form("#group-sidebar-search-form", %{"group_sidebar_search" => %{"q" => "record"}})
    |> render_change()

    assert has_element?(lv, "#group-sidebar-no-match")
  end

  test "the root has no column: it is the list", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{Social.get_root_group!().id}")

    refute has_element?(lv, "#group-sidebar")
    refute has_element?(lv, "#group-sidebar-show")
  end

  describe "pinned groups" do
    test "the group's menu pins it on top of the column, with the way to it", ctx do
      {building, entrance} = building(ctx)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{entrance.id}/values")
      load(lv)
      refute has_element?(lv, "#group-sidebar-pinned")

      lv |> element("#group-pin") |> render_click()

      assert render(lv) =~ "The group is pinned to your groups."
      assert has_element?(lv, "#group-sidebar-pin-#{entrance.id}", "side-entrance")
      assert has_element?(lv, "#group-sidebar-pin-link-#{entrance.id} img")
      assert has_element?(lv, "#group-sidebar-pin-path-#{entrance.id}", "side-building")
      assert has_element?(lv, "#group-sidebar-pin-link-#{entrance.id}[aria-current=page]")
      assert has_element?(lv, "#group-sidebar-pin-unread-#{entrance.id}[hidden]")
      assert has_element?(lv, "#group-unpin")
      refute has_element?(lv, "#group-sidebar-pin-#{building.id}")

      lv |> element("#group-sidebar-unpin-#{entrance.id}") |> render_click()

      refute has_element?(lv, "#group-sidebar-pinned")
      assert has_element?(lv, "#group-pin")
    end

    test "a row's menu pins too, and a pin on another page shows here", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
      load(lv)

      :ok = Social.pin_group(ctx.member, ctx.garden.id)

      assert has_element?(lv, "#group-sidebar-pin-#{ctx.garden.id}")
      assert has_element?(lv, "#group-sidebar-pin-unread-#{ctx.garden.id}:not([hidden])", "1")

      {:ok, root_lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{Social.get_root_group!().id}/sub_groups")

      root_lv |> element("#group-row-menu-button-#{ctx.lift.id}") |> render_click()
      root_lv |> element("#group-row-pin") |> render_click()

      assert has_element?(lv, "#group-sidebar-pin-#{ctx.lift.id}")
    end

    test "says when the pins are full", ctx do
      for n <- 1..Social.PinnedGroups.max() do
        group = group_with_members!(ctx.owner, [ctx.member], %{"name" => "side-pin-#{n}"})
        :ok = Social.pin_group(ctx.member, group.id)
      end

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
      lv |> element("#group-pin") |> render_click()

      assert render(lv) =~ "You can pin up to 20 groups."
      refute Social.group_pinned?(ctx.member, ctx.lift.id)
    end

    test "a search keeps the pinned groups whose name holds it", ctx do
      :ok = Social.pin_group(ctx.member, ctx.garden.id)
      :ok = Social.pin_group(ctx.member, ctx.lift.id)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
      load(lv)

      lv
      |> form("#group-sidebar-search-form", %{"group_sidebar_search" => %{"q" => "garden"}})
      |> render_change()

      assert has_element?(lv, "#group-sidebar-pin-#{ctx.garden.id}")
      refute has_element?(lv, "#group-sidebar-pin-#{ctx.lift.id}")
    end
  end
end
