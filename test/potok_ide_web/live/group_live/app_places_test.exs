defmodule PotokIdeWeb.GroupLive.AppPlacesTest do
  @moduledoc """
  What a map app gets from the App API: how to draw its pins
  (`map_config`), the placed sub-groups the viewer sees (`list_places`), a
  new place where the viewer taps (`create_place`), and a sub-group's
  description over the app (`show_group`).
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupPins, GroupPresets}

  setup do
    {owner_account, owner} = account_with_profile!("map-owner")
    {member_account, member} = account_with_profile!("map-member")
    {visitor_account, _visitor} = account_with_profile!("map-visitor")

    {:ok, map} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "map-app",
        "description" => "<p>map</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true
      })

    add_member!(owner, map, member)

    %{
      owner_account: owner_account,
      member_account: member_account,
      visitor_account: visitor_account,
      owner: owner,
      member: member,
      map: map
    }
  end

  defp child!(owner, parent, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => "place-#{System.unique_integer([:positive])}",
            "description" => "Opis mesta",
            "description_format" => :markdown,
            "is_public" => true
          },
          attrs
        )
      )

    group
  end

  defp open_map(conn, account, map) do
    {:ok, view, _html} = conn |> log_in_account(account) |> live(~p"/groups/#{map.id}/group_home")
    view
  end

  defp call(view, method, params \\ %{}) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  describe "map_config" do
    test "says where tiles come from, where the map opens and how pins look", ctx do
      view = open_map(build_conn(), ctx.owner_account, ctx.map)
      call(view, "map_config")

      assert_reply(view, %{ok: true} = config)
      assert config.tiles.url =~ ~r{/tiles/\{z\}/\{x\}/\{y\}\.png$}
      assert config.tiles.attribution =~ "OpenStreetMap"
      assert config.default_bounds == [[41.85, 18.82], [46.19, 23.01]]
      assert length(config.pins.icons) == length(GroupPins.icons())
      assert Enum.map(config.place_kinds, & &1.key) == GroupPresets.keys()
      assert config.can_create_places
      assert config.can_edit_view
    end

    test "a non-member of a public map may look, not add", ctx do
      view = open_map(build_conn(), ctx.visitor_account, ctx.map)
      call(view, "map_config")

      assert_reply(view, %{ok: true, can_create_places: false, can_edit_view: false})
    end
  end

  describe "list_places" do
    test "gives the placed sub-groups right under the map that the viewer sees", ctx do
      shop =
        child!(ctx.owner, ctx.map, %{
          "latitude" => 44.8,
          "longitude" => 20.4,
          "pin_icon" => "shop"
        })

      closed =
        child!(ctx.owner, ctx.map, %{
          "latitude" => 45.2,
          "longitude" => 19.8,
          "is_public" => false,
          "inherits_members" => true
        })

      _unplaced = child!(ctx.owner, ctx.map, %{})
      _below = child!(ctx.owner, shop, %{"latitude" => 43.3, "longitude" => 21.9})

      member = open_map(build_conn(), ctx.member_account, ctx.map)
      call(member, "list_places")

      assert_reply(member, %{ok: true, truncated: false, places: places})
      assert Enum.map(places, & &1.id) == [shop.id, closed.id]

      assert %{lat: 44.8, lng: 20.4, pin: "shop", kind: "none", is_public: true} =
               Enum.find(places, &(&1.id == shop.id))

      assert %{pin: nil, is_public: false} = Enum.find(places, &(&1.id == closed.id))

      visitor = open_map(build_conn(), ctx.visitor_account, ctx.map)
      call(visitor, "list_places")

      assert_reply(visitor, %{ok: true, places: [%{id: shop_id}]})
      assert shop_id == shop.id
    end
  end

  describe "create_place" do
    test "makes a sub-group from a preset where the viewer tapped, and the map hears of it",
         ctx do
      view = open_map(build_conn(), ctx.member_account, ctx.map)

      call(view, "create_place", %{
        "name" => "Pekara",
        "kind" => "chat",
        "lat" => 44.81,
        "lng" => 20.46,
        "pin" => "food"
      })

      assert_reply(view, %{ok: true, place: %{id: id, name: "Pekara", kind: "chat", pin: "food"}})

      group = Repo.get!(Group, id)
      assert group.parent_id == ctx.map.id
      assert group.creator_id == ctx.member.id
      assert group.preset == :chat
      assert {group.latitude, group.longitude} == {44.81, 20.46}
      assert group.is_public == GroupPresets.defaults("chat", ctx.map)["is_public"]

      assert_push_event(view, "app_children_changed", %{host: "page"})
    end

    test "takes integers for coordinates and the viewer's choice of audience", ctx do
      view = open_map(build_conn(), ctx.owner_account, ctx.map)

      call(view, "create_place", %{
        "name" => "Trg",
        "kind" => "page",
        "lat" => 44,
        "lng" => 20,
        "is_public" => true
      })

      assert_reply(view, %{ok: true, place: %{id: id, lat: 44.0, lng: 20.0, is_public: true}})
      assert Repo.get!(Group, id).is_public
    end

    test "refuses a kind, a place or a pin it does not know", ctx do
      view = open_map(build_conn(), ctx.owner_account, ctx.map)

      for params <- [
            %{"name" => "x", "kind" => "castle", "lat" => 44, "lng" => 20},
            %{"name" => "x", "kind" => "chat", "lat" => 91, "lng" => 20},
            %{"name" => "x", "kind" => "chat", "lat" => "44", "lng" => 20},
            %{"name" => "  ", "kind" => "chat", "lat" => 44, "lng" => 20},
            %{"name" => "x", "kind" => "chat", "lat" => 44, "lng" => 20, "pin" => "unicorn"}
          ] do
        call(view, "create_place", params)
        assert_reply(view, %{ok: false, error: "invalid_place"})
      end
    end

    test "only whoever may make a sub-group here adds a place", ctx do
      view = open_map(build_conn(), ctx.visitor_account, ctx.map)
      call(view, "create_place", %{"name" => "x", "kind" => "chat", "lat" => 44, "lng" => 20})

      assert_reply(view, %{ok: false, error: "forbidden"})
    end
  end

  describe "show_group" do
    test "opens a sub-group's description over the app, and closing tells the app", ctx do
      place = child!(ctx.owner, ctx.map, %{"latitude" => 44.8, "longitude" => 20.4})
      view = open_map(build_conn(), ctx.member_account, ctx.map)

      call(view, "show_group", %{"id" => place.id})
      assert_reply(view, %{ok: true})

      assert has_element?(view, "#group-sheet")
      assert has_element?(view, "#group-sheet-title", place.name)
      assert has_element?(view, "#group-sheet-open[href='/groups/#{place.id}']")

      view |> element("#group-sheet-close") |> render_click()

      refute has_element?(view, "#group-sheet")
      assert_push_event(view, "group_sheet_closed", %{id: id, host: "page"})
      assert id == place.id
    end

    test "reaches only a sub-group right under the app that the viewer sees", ctx do
      place = child!(ctx.owner, ctx.map, %{})
      below = child!(ctx.owner, place, %{})

      closed =
        child!(ctx.owner, ctx.map, %{"is_public" => false, "inherits_members" => false})

      view = open_map(build_conn(), ctx.member_account, ctx.map)

      for id <- [below.id, closed.id, ctx.map.id] do
        call(view, "show_group", %{"id" => id})
        assert_reply(view, %{ok: false, error: "not_found"})
      end

      refute has_element?(view, "#group-sheet")
    end
  end
end
