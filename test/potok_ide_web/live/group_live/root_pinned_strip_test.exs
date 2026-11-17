defmodule PotokIdeWeb.GroupLive.RootPinnedStripTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("strip-owner")
    {member_account, member} = account_with_profile!("strip-member")
    lift = group_with_members!(owner, [member], %{"name" => "strip-lift"})
    garden = group_with_members!(owner, [member], %{"name" => "strip-garden"})
    {:ok, _} = Social.create_value(owner, garden, %{"content" => "we plant on Sunday"})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      lift: lift,
      garden: garden,
      root: Social.get_root_group!()
    }
  end

  defp live_root(ctx),
    do: build_conn() |> log_in_account(ctx.member_account) |> live(~p"/groups/#{ctx.root.id}")

  defp strip_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#root-pinned-list > li")
    |> LazyHTML.attribute("id")
  end

  test "no pins, no strip", ctx do
    {:ok, lv, _html} = live_root(ctx)

    assert has_element?(lv, "#group-children-list")
    refute has_element?(lv, "#root-pinned")
  end

  test "the pinned groups stand on top of the list, in the order they were pinned", ctx do
    building =
      group_with_members!(ctx.owner, [], %{"name" => "strip-building", "is_public" => true})

    entrance =
      group_with_members!(ctx.owner, [ctx.member], %{
        :parent => building,
        "name" => "strip-entrance"
      })

    :ok = Social.pin_group(ctx.member, entrance.id)
    :ok = Social.pin_group(ctx.member, ctx.garden.id)

    {:ok, lv, _html} = live_root(ctx)

    assert strip_ids(lv) == ["root-pinned-#{entrance.id}", "root-pinned-#{ctx.garden.id}"]

    assert has_element?(
             lv,
             ~s(#root-pinned-link-#{entrance.id}[href="/groups/#{entrance.id}"][title="strip-building › strip-entrance"]),
             "strip-entrance"
           )

    assert has_element?(
             lv,
             ~s(#root-pinned-link-#{entrance.id} img[src^="/avatar/group/#{entrance.id}?"])
           )

    # The garden has something unread; the entrance has not.
    assert has_element?(lv, "#root-pinned-unread-#{ctx.garden.id}:not([hidden])", "1")
    assert has_element?(lv, "#root-pinned-unread-#{entrance.id}[hidden]")
  end

  test "a pinned group counts what is unread below it, a silenced one in grey", ctx do
    building =
      group_with_members!(ctx.owner, [], %{"name" => "strip-building", "is_public" => true})

    entrance =
      group_with_members!(ctx.owner, [ctx.member], %{
        :parent => building,
        "name" => "strip-entrance"
      })

    {:ok, _} = Social.create_value(ctx.owner, entrance, %{"content" => "the door is open"})
    :ok = Social.pin_group(ctx.member, building.id)
    :ok = Social.pin_group(ctx.member, ctx.garden.id)
    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.garden, "hour")

    {:ok, lv, _html} = live_root(ctx)

    assert has_element?(lv, "#root-pinned-unread-#{building.id}:not([hidden])", "1")
    assert has_element?(lv, "#root-pinned-muted-unread-#{ctx.garden.id}:not([hidden])", "1")
    refute has_element?(lv, "#root-pinned-unread-#{ctx.garden.id}:not([hidden])")
  end

  test "pinning from a row's menu shows at once, and so does unpinning elsewhere", ctx do
    {:ok, lv, _html} = live_root(ctx)
    refute has_element?(lv, "#root-pinned")

    lv |> element("#group-row-menu-button-#{ctx.lift.id}") |> render_click()
    lv |> element("#group-row-pin") |> render_click()

    assert has_element?(lv, "#root-pinned-#{ctx.lift.id}", "strip-lift")

    :ok = Social.pin_group(ctx.member, ctx.garden.id)

    assert strip_ids(lv) == ["root-pinned-#{ctx.lift.id}", "root-pinned-#{ctx.garden.id}"]
    assert has_element?(lv, "#root-pinned-unread-#{ctx.garden.id}:not([hidden])", "1")

    :ok = Social.unpin_group(ctx.member, ctx.lift.id)

    assert strip_ids(lv) == ["root-pinned-#{ctx.garden.id}"]
  end

  test "the strip steps aside for the conversations and for a search", ctx do
    :ok = Social.pin_group(ctx.member, ctx.garden.id)
    {:ok, lv, _html} = live_root(ctx)
    assert has_element?(lv, "#root-pinned")

    lv
    |> form("#group-children-search-form", %{"children_search" => %{"q" => "lift"}})
    |> render_change()

    refute has_element?(lv, "#root-pinned")

    lv
    |> form("#group-children-search-form", %{"children_search" => %{"q" => ""}})
    |> render_change()

    assert has_element?(lv, "#root-pinned")

    lv |> element("#group-sub-groups-kind-direct") |> render_click()
    refute has_element?(lv, "#root-pinned")
  end

  test "the folder view keeps it on top", ctx do
    :ok = Social.pin_group(ctx.member, ctx.garden.id)
    {:ok, lv, _html} = live_root(ctx)

    lv |> element("#group-children-view-tree") |> render_click()

    assert has_element?(lv, "#group-children-tree")
    assert has_element?(lv, "#root-pinned-#{ctx.garden.id}")
  end
end
