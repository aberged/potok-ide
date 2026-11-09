defmodule PotokIdeWeb.GroupLive.RootMapTest do
  @moduledoc """
  The root's map tab (`RootMapState`, `RootMapTab`): every group with a place
  the viewer sees, the sub-groups' filters and a time frame, and a tap on a pin
  opening the group's sheet at any depth.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group

  @serbia [18.8, 41.8, 23.1, 46.2]

  setup do
    {_owner_account, owner} = account_with_profile!("rmap-owner")
    {viewer_account, viewer} = account_with_profile!("rmap-viewer")
    root = Social.get_root_group!()

    folder = group_with_members!(owner, [viewer], %{"name" => "rmap-folder"})

    shop =
      group_with_members!(owner, [viewer], %{
        "name" => "Pekara",
        "latitude" => 44.81,
        "longitude" => 20.46,
        "description" => "Sveže **svako** jutro.",
        "home_page" => :description,
        parent: folder
      })

    open =
      group_with_members!(owner, [], %{
        "name" => "Javna bašta",
        "is_public" => true,
        "latitude" => 45.26,
        "longitude" => 19.83
      })

    closed =
      group_with_members!(owner, [], %{
        "name" => "Zatvoreno",
        "latitude" => 43.32,
        "longitude" => 21.9
      })

    %{
      owner: owner,
      viewer: viewer,
      viewer_account: viewer_account,
      root: root,
      folder: folder,
      shop: shop,
      open: open,
      closed: closed
    }
  end

  defp live_map(account, path, connect_params \\ %{}) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(Map.merge(%{"time_zone" => "Europe/Belgrade"}, connect_params))
      |> live(path)

    lv
  end

  defp view(lv, zoom \\ 18) do
    render_hook(lv, "root_map_view", %{bbox: @serbia, zoom: zoom})
    assert_reply(lv, reply)
    reply
  end

  defp place_ids(reply), do: reply.places |> Enum.map(& &1.id) |> Enum.sort()

  test "the root leads to its map, other groups have none", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}")

    assert has_element?(lv, "#group-map-summary")
    assert has_element?(lv, "#group-tab-map")

    lv |> element("#group-map-summary") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.root.id}/map")
    assert has_element?(lv, "#root-map[phx-hook='RootMap'][data-pins]")

    other = live_map(ctx.viewer_account, ~p"/groups/#{ctx.folder.id}/map")
    refute has_element?(other, "#root-map")
    refute has_element?(other, "#group-map-summary")
  end

  test "the map holds the viewer's groups at any depth, and public ones when asked", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    reply = view(lv)
    assert reply.ok
    assert place_ids(reply) == [ctx.shop.id]
    assert [%{name: "Pekara", kind: "none", pin: nil, is_public: false}] = reply.places
    assert has_element?(lv, "#root-map-total")
    assert has_element?(lv, "#root-map-fit")

    lv |> element("#root-map-public-toggle") |> render_click()

    # The same switch as the sub-groups', kept by the browser.
    assert_push_event(lv, "sub_groups_public", %{shown: true})
    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == Enum.sort([ctx.shop.id, ctx.open.id])
    refute ctx.closed.id in place_ids(data)
  end

  test "far out, groups gather into clusters", ctx do
    group_with_members!(ctx.owner, [ctx.viewer], %{"latitude" => 44.811, "longitude" => 20.46})

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    assert %{places: [], clusters: [%{count: 2}], total: 2} = view(lv, 6)
  end

  test "the filters narrow it and send the view again", ctx do
    lv =
      live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map", %{"show_public_groups" => true})

    assert place_ids(view(lv)) == Enum.sort([ctx.shop.id, ctx.open.id])

    lv |> element("#root-map-relation-option-member") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == [ctx.shop.id]

    lv |> element("#root-map-relation-option-all") |> render_click()
    assert_push_event(lv, "root_map_data", _data)

    lv |> form("#root-map-search-form", root_map_search: %{q: "bašta"}) |> render_change()
    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == [ctx.open.id]

    lv |> element("#root-map-search-reset") |> render_click()
    assert_push_event(lv, "root_map_data", _data)

    lv |> element("#root-map-preset-option-polls") |> render_click()
    assert_push_event(lv, "root_map_data", %{places: [], total: 0})
    assert has_element?(lv, "#root-map-empty")
    assert has_element?(lv, "#root-map-preset-toggle[aria-label*=':']")

    lv |> element("#root-map-clear-filters") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == Enum.sort([ctx.shop.id, ctx.open.id])
    refute has_element?(lv, "#root-map-empty")
  end

  test "the time frame starts at 30 days of new groups and takes other frames and dates", ctx do
    long_ago = DateTime.utc_now() |> DateTime.add(-60, :day) |> DateTime.truncate(:second)

    open_id = ctx.open.id

    Repo.update_all(from(g in Group, where: g.id == ^open_id),
      set: [inserted_at: long_ago, published_at: nil]
    )

    lv =
      live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map", %{"show_public_groups" => true})

    assert has_element?(lv, "#root-map-time-option-30d[aria-checked='true']")
    assert has_element?(lv, "#root-map-time-created[aria-pressed='true']")
    assert place_ids(view(lv)) == [ctx.shop.id]

    lv |> element("#root-map-time-option-any") |> render_click()
    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == Enum.sort([ctx.shop.id, ctx.open.id])

    # Nobody wrote in either.
    lv |> element("#root-map-time-option-7d") |> render_click()
    assert_push_event(lv, "root_map_data", _data)
    lv |> element("#root-map-time-active") |> render_click()
    assert_push_event(lv, "root_map_data", %{places: []})
    assert has_element?(lv, "#root-map-time-active[aria-pressed='true']")

    lv |> element("#root-map-time-created") |> render_click()
    assert_push_event(lv, "root_map_data", _data)

    day =
      long_ago
      |> DateTime.shift_zone!("Europe/Belgrade")
      |> DateTime.to_date()
      |> Date.to_iso8601()

    lv
    |> form("#root-map-range-form", root_map_range: %{from: day, to: day})
    |> render_submit()

    assert_push_event(lv, "root_map_data", data)
    assert place_ids(data) == [ctx.open.id]
    refute has_element?(lv, "#root-map-time-option-30d[aria-checked='true']")
  end

  test "a pin opens its group's sheet over the map, at any depth", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    render_click(lv, "root_map_open", %{"id" => ctx.shop.id})

    assert has_element?(lv, "#group-sheet #group-sheet-title", "Pekara")
    [sheet] = Enum.filter(live_children(lv), &String.starts_with?(&1.id, "group-sheet-lv-"))
    assert has_element?(sheet, "#sheet-panel-description strong", "svako")

    lv |> element("#group-sheet-close") |> render_click()
    refute has_element?(lv, "#group-sheet")

    # Not a group the viewer does not see, nor a bad id.
    for id <- [ctx.closed.id, "x", -1] do
      render_click(lv, "root_map_open", %{"id" => id})
      refute has_element?(lv, "#group-sheet")
    end
  end

  test "a crowded spot lists its groups, and each opens", ctx do
    second =
      group_with_members!(ctx.owner, [ctx.viewer], %{
        "name" => "Apoteka",
        "latitude" => 44.81,
        "longitude" => 20.46
      })

    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    render_hook(lv, "root_map_spot", %{bounds: [[44.81, 20.46], [44.81, 20.46]]})

    assert has_element?(lv, "#root-map-spot-group-#{second.id}", "Apoteka")
    assert has_element?(lv, "#root-map-spot-group-#{ctx.shop.id}", "Pekara")

    lv |> element("#root-map-spot-group-#{second.id}") |> render_click()

    refute has_element?(lv, "#root-map-spot")
    assert has_element?(lv, "#group-sheet #group-sheet-title", "Apoteka")
  end

  test "the fit button frames every group the filters keep", ctx do
    lv = live_map(ctx.viewer_account, ~p"/groups/#{ctx.root.id}/map")

    lv |> element("#root-map-fit") |> render_click()

    assert_push_event(lv, "root_map_fit", %{bounds: [[44.81, 20.46], [44.81, 20.46]]})
  end

  test "a newcomer learns where places come from", _ctx do
    {account, _profile} = account_with_profile!("rmap-new")
    lv = live_map(account, ~p"/groups/#{Social.get_root_group!().id}/map")

    assert has_element?(lv, "#root-map-empty")
    refute has_element?(lv, "#root-map-clear-filters")
    assert %{ok: true, places: [], total: 0} = view(lv)

    # The time frame it starts with is not what keeps the map empty.
    lv |> element("#root-map-any-time") |> render_click()
    assert_push_event(lv, "root_map_data", %{places: []})
    assert has_element?(lv, "#root-map-empty")
    refute has_element?(lv, "#root-map-any-time")
  end
end
