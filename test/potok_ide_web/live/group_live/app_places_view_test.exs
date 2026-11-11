defmodule PotokIdeWeb.GroupLive.AppPlacesViewTest do
  @moduledoc """
  A map app over more places than `list_places` gives at once: with a view
  (`bbox`, `zoom`) it gets what the view shows, gathered into cells on the
  server like the root's map, filtered by name and pin, and `list_places_at`
  lists a spot no zoom can spread. A small map gets all its places, as before.

  Not async: the threshold is lowered for the whole app (`:app_max_places`).
  """
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Social

  @serbia [18.8, 41.8, 23.1, 46.2]

  setup do
    Application.put_env(:potok_ide, :app_max_places, 3)
    on_exit(fn -> Application.delete_env(:potok_ide, :app_max_places) end)

    {owner_account, owner} = account_with_profile!("view-owner")
    {member_account, member} = account_with_profile!("view-member")

    {:ok, map} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "view-map",
        "description" => "<p>map</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true
      })

    add_member!(owner, map, member)

    %{owner_account: owner_account, owner: owner, member_account: member_account, map: map}
  end

  defp place!(owner, parent, name, {lat, lng}, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => name,
            "description" => "",
            "description_format" => :markdown,
            "is_public" => true,
            "latitude" => lat,
            "longitude" => lng
          },
          attrs
        )
      )

    group
  end

  # Three close together in Belgrade, two in Niš, a record and a closed one.
  defp seed!(ctx) do
    %{owner: owner, map: map} = ctx

    a = place!(owner, map, "Barajevo jedan", {44.80, 20.40}, %{"pin_icon" => "problem"})
    b = place!(owner, map, "Barajevo dva", {44.81, 20.41}, %{"pin_icon" => "warning"})
    c = place!(owner, map, "Čukarica", {44.82, 20.42}, %{"pin_icon" => "warning"})
    d = place!(owner, map, "Niš centar", {43.32, 21.90})
    e = place!(owner, map, "Niš most", {43.33, 21.91}, %{"pin_icon" => "transport"})

    {:ok, [%{id: record}]} =
      Social.create_children(owner, map, [
        %{
          "name" => "Zapis Zemun",
          "description" => "",
          "is_public" => true,
          "latitude" => 44.84,
          "longitude" => 20.40,
          "pin_icon" => "transport",
          "external_key" => "mup:1"
        }
      ])

    closed = place!(owner, map, "Zatvoreno", {44.83, 20.43}, %{"is_public" => false})
    _below = place!(owner, a, "Ispod", {44.85, 20.45})

    %{a: a, b: b, c: c, d: d, e: e, record: record, closed: closed}
  end

  defp open_map(account, map) do
    {:ok, view, _html} =
      build_conn() |> log_in_account(account) |> live(~p"/groups/#{map.id}/group_home")

    view
  end

  defp call(view, method, params \\ %{}) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  defp single_ids(reply), do: reply.places |> Enum.map(& &1.id) |> Enum.sort()

  test "a small map gets every place, and says so", ctx do
    a = place!(ctx.owner, ctx.map, "jedan", {44.80, 20.40})
    b = place!(ctx.owner, ctx.map, "dva", {43.32, 21.90})

    view = open_map(ctx.member_account, ctx.map)
    call(view, "list_places", %{"bbox" => [20.0, 44.0, 20.1, 44.1], "zoom" => 12})

    assert_reply(view, %{ok: true, mode: "all", places: places, truncated: false})
    assert places |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
  end

  test "without a view the call is as it was: up to the limit, oldest first", ctx do
    %{a: a, b: b, c: c} = seed!(ctx)

    view = open_map(ctx.member_account, ctx.map)
    call(view, "list_places")

    assert_reply(view, %{ok: true, places: places, truncated: true} = reply)
    refute Map.has_key?(reply, :mode)
    assert Enum.map(places, & &1.id) == [a.id, b.id, c.id]
  end

  test "a big map gets its view gathered into cells", ctx do
    %{a: a, b: b, c: c, d: d, e: e, record: record} = seed!(ctx)
    view = open_map(ctx.member_account, ctx.map)

    # Up close every place stands alone; the closed one and the one below are not there.
    call(view, "list_places", %{"bbox" => @serbia, "zoom" => 18})

    assert_reply(
      view,
      %{ok: true, mode: "view", clusters: [], total: 6, truncated: false} = reply
    )

    assert single_ids(reply) == Enum.sort([a.id, b.id, c.id, d.id, e.id, record])

    [place] = Enum.filter(reply.places, &(&1.id == record))
    assert %{lat: 44.84, lng: 20.4, pin: "transport", kind: "none", shape: "point"} = place

    # From afar Belgrade and Niš are one cluster each, with the tones of their pins.
    call(view, "list_places", %{"bbox" => @serbia, "zoom" => 7})
    assert_reply(view, %{ok: true, mode: "view", places: [], clusters: clusters, total: 6})

    assert clusters |> Enum.map(& &1.count) |> Enum.sort() == [2, 4]
    belgrade = Enum.find(clusters, &(&1.count == 4))
    assert belgrade.tones == %{alert: 1, reports: 2, places: 1}
    assert [[south, west], [north, east]] = belgrade.bounds
    assert {south, west, north, east} == {44.8, 20.4, 44.84, 20.42}

    # Only what the box holds.
    call(view, "list_places", %{"bbox" => [21.0, 43.0, 22.5, 44.0], "zoom" => 18})
    assert_reply(view, %{ok: true, mode: "view", total: 2} = reply)
    assert single_ids(reply) == Enum.sort([d.id, e.id])
  end

  test "filters by name and by pin, with the extent and the pins of the whole map", ctx do
    %{a: a, b: b, c: c, d: d} = seed!(ctx)
    view = open_map(ctx.member_account, ctx.map)

    call(view, "list_places", %{
      "bbox" => @serbia,
      "zoom" => 18,
      "search" => "barajevo",
      "extent" => true,
      "counts" => true
    })

    assert_reply(view, %{ok: true, mode: "view"} = reply)
    assert single_ids(reply) == Enum.sort([a.id, b.id])
    assert reply.extent == %{count: 2, bounds: [[44.8, 20.4], [44.81, 20.41]]}

    assert reply.pins == [
             %{pin: "transport", count: 2},
             %{pin: "warning", count: 2},
             %{pin: "kind", count: 1},
             %{pin: "problem", count: 1}
           ]

    call(view, "list_places", %{"bbox" => @serbia, "zoom" => 18, "pins" => ["warning", "kind"]})
    assert_reply(view, %{ok: true} = reply)
    assert single_ids(reply) == Enum.sort([b.id, c.id, d.id])
    refute Map.has_key?(reply, :extent)
    refute Map.has_key?(reply, :pins)
  end

  test "lists the places of a spot by name", ctx do
    %{a: a, b: b, c: c} = seed!(ctx)
    view = open_map(ctx.member_account, ctx.map)

    call(view, "list_places_at", %{"bounds" => [[44.80, 20.40], [44.82, 20.42]]})
    assert_reply(view, %{ok: true, places: places, has_more: false})
    assert Enum.map(places, & &1.id) == [b.id, a.id, c.id]

    call(view, "list_places_at", %{
      "bounds" => [[44.80, 20.40], [44.82, 20.42]],
      "pins" => ["problem"]
    })

    assert_reply(view, %{ok: true, places: [%{id: id}]})
    assert id == a.id

    call(view, "list_places_at", %{"bounds" => [[44.80, 20.40]]})
    assert_reply(view, %{ok: false, error: "invalid_place"})
  end

  test "refuses a view it cannot read", ctx do
    view = open_map(ctx.member_account, ctx.map)

    for params <- [
          %{"bbox" => [1, 2, 3], "zoom" => 5},
          %{"bbox" => [1, 2, 3, "4"], "zoom" => 5},
          %{"bbox" => @serbia, "zoom" => 25},
          %{"bbox" => @serbia, "zoom" => 5.5},
          %{"bbox" => @serbia, "zoom" => 5, "pins" => "warning"},
          %{"bbox" => @serbia, "zoom" => 5, "search" => 7}
        ] do
      call(view, "list_places", params)
      assert_reply(view, %{ok: false, error: "invalid_place"})
    end
  end
end
