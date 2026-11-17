defmodule PotokIdeWeb.GroupLive.GroupSidebarTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

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

  defp load(lv) do
    lv |> element("#group-sidebar") |> render_hook("group_sidebar_load", %{})
    lv
  end

  defp row_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#group-sidebar-list > li[id^=group-sidebar-row-]")
    |> Enum.map(&(LazyHTML.attribute(&1, "id") |> List.first()))
  end

  test "it waits for the browser before it loads, then lists the viewer's groups", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")

    assert has_element?(lv, "#group-sidebar #group-sidebar-loading")
    refute has_element?(lv, "#group-sidebar-list")

    load(lv)

    assert has_element?(lv, "#group-sidebar-row-#{ctx.lift.id}[aria-current=page]")
    assert has_element?(lv, "#group-sidebar-row-#{ctx.garden.id}", "side-garden")
    assert has_element?(lv, "#sidebar-group-last-value-#{ctx.garden.id}", "we plant on Sunday")
    assert has_element?(lv, "#sidebar-group-draft-#{ctx.garden.id}[phx-hook=DraftMark]")

    # The garden has something unread; the open lift was just read.
    assert has_element?(lv, "#sidebar-group-unread-badge-#{ctx.garden.id}:not([hidden])", "1")
    refute has_element?(lv, "#sidebar-group-unread-badge-#{ctx.lift.id}:not([hidden])")
    assert List.first(row_ids(lv)) == "group-sidebar-row-#{ctx.garden.id}"
  end

  test "a new value elsewhere counts and lifts its group's row", ctx do
    other = group_with_members!(ctx.owner, [ctx.member], %{"name" => "side-other"})
    Social.mark_group_values_read(ctx.member, ctx.garden)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)
    refute has_element?(lv, "#sidebar-group-unread-badge-#{other.id}:not([hidden])")

    {:ok, _} = Social.create_value(ctx.owner, other, %{"content" => "news from elsewhere"})
    _ = render(lv)
    _ = render(lv)

    assert has_element?(lv, "#sidebar-group-last-value-#{other.id}", "news from elsewhere")
    assert has_element?(lv, "#sidebar-group-unread-badge-#{other.id}:not([hidden])", "1")
    assert List.first(row_ids(lv)) == "group-sidebar-row-#{other.id}"
  end

  test "a silenced group counts in grey", ctx do
    {:ok, _until} = Social.set_group_mute(ctx.member, ctx.garden, "hour")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.lift.id}/values")
    load(lv)

    assert has_element?(
             lv,
             "#sidebar-group-muted-unread-badge-#{ctx.garden.id}:not([hidden])",
             "1"
           )

    assert has_element?(lv, "#sidebar-group-muted-#{ctx.garden.id}")
    refute has_element?(lv, "#sidebar-group-unread-badge-#{ctx.garden.id}:not([hidden])")
  end

  test "the root has no column: it is the list", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{Social.get_root_group!().id}")

    refute has_element?(lv, "#group-sidebar")
    refute has_element?(lv, "#group-sidebar-show")
  end
end
