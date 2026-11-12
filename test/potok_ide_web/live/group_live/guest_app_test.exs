defmodule PotokIdeWeb.GroupLive.GuestAppTest do
  @moduledoc """
  An app in the description of a public group that opened it to guests, run
  for a guest (`GuestApp`): it reads the public groups below, a map of them
  and public polls, with a guest's sight, and nothing it does writes.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("ga-owner")

    parent = group!(owner, Social.get_root_group!(), "ga-parent", %{"is_public" => true})

    app =
      group!(owner, parent, "ga-app", %{
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true,
        "description_for_guests" => true
      })

    feed = group!(owner, app, ".feed", %{"is_public" => true})

    open =
      group!(owner, feed, "ga-open", %{
        "description" => "Otvorena priča.",
        "is_public" => true,
        "description_for_guests" => true
      })

    public =
      group!(owner, feed, "ga-public", %{"description" => "Za prijavljene.", "is_public" => true})

    closed = group!(owner, feed, "ga-closed", %{"description" => "Tajna.", "is_public" => false})

    %{
      owner_account: owner_account,
      owner: owner,
      parent: parent,
      app: app,
      feed: feed,
      open: open,
      public: public,
      closed: closed
    }
  end

  defp group!(owner, parent, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp guest(path) do
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  defp call(view, method, params \\ %{}, app_id \\ "") do
    render_hook(view, "app_api", %{"method" => method, "params" => params, "app_id" => app_id})
    assert_reply(view, reply)
    reply
  end

  test "runs for a guest, with nobody signed in", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    assert has_element?(view, "#group-app-frame iframe")
    assert %{ok: true, profile: nil} = call(view, "current_profile")
    assert %{ok: true, group: %{id: id}} = call(view, "get_description")
    assert id == ctx.app.id
  end

  test "tells the app where it stands and that nobody is signed in", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    assert %{ok: true, group: group} = call(view, "get_group")

    assert group.id == ctx.app.id
    refute group.signed_in
    refute group.can_manage_children
    refute group.can_create_children

    assert group.parent == %{
             id: ctx.parent.id,
             name: "ga-parent",
             is_public: true,
             uses_api: false
           }

    {:ok, _private} = Social.update_group(ctx.owner, ctx.parent, %{"is_public" => false})
    assert %{ok: true, group: %{parent: nil}} = call(view, "get_group")
  end

  test "lists the public groups below, with the text of the open ones only", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    assert %{ok: true, groups: groups} = call(view, "list_subgroups", %{"name" => ".feed"})

    by_name = Map.new(groups, &{&1.name, &1})

    assert Map.keys(by_name) |> Enum.sort() == ["ga-open", "ga-public"]
    assert by_name["ga-open"].description_html =~ "Otvorena priča."
    assert by_name["ga-public"].description_html == nil
    assert Enum.all?(groups, &(&1.creator_id == nil and &1.can_react == false))
  end

  test "writes, reacts and edits nothing", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    assert %{ok: false, error: "not_a_member"} = call(view, "insert_value", %{"data" => %{}})
    assert %{ok: false, error: "not_a_member"} = call(view, "list_values")

    for {method, params} <- [
          {"toggle_group_reaction", %{"id" => ctx.open.id, "emoji" => "👍"}},
          {"create_child", %{"name" => "nova"}},
          {"list_children", %{}},
          {"save_config", %{"config" => %{}}},
          {"open_poll", %{"id" => 1}},
          {"file_url", %{"id" => 1}},
          {"create_place", %{"lat" => 44.8, "lng" => 20.4}},
          {"update_description", %{"description" => "<p>moje</p>"}}
        ] do
      assert %{ok: false, error: "forbidden"} = call(view, method, params), method
    end

    assert Social.get_group!(ctx.app.id).description == "<p>app</p>"
    assert Social.group_reaction_summaries([ctx.open.id], nil) == %{}
  end

  test "opens a group's page and shares its link", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    call(view, "share_group", %{"id" => ctx.feed.id})
    assert_push_event(view, "app_share_link", %{url: url})
    assert url == url(~p"/groups/#{ctx.feed.id}")

    render_hook(view, "app_api", %{
      "method" => "open_group",
      "params" => %{"id" => ctx.feed.id, "tab" => "description"},
      "app_id" => ""
    })

    assert_redirect(view, ~p"/groups/#{ctx.feed.id}/group_home")
  end

  test "opens a group over the app as text, or as its card", ctx do
    app =
      group!(ctx.owner, ctx.parent, "ga-map", %{
        "description" => "<p>map</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true,
        "description_for_guests" => true
      })

    open =
      group!(ctx.owner, app, "ga-map-open", %{
        "description" => "Ovde je park.",
        "is_public" => true,
        "description_for_guests" => true
      })

    public =
      group!(ctx.owner, app, "ga-map-public", %{
        "description" => "Samo kartica.",
        "is_public" => true
      })

    closed = group!(ctx.owner, app, "ga-map-closed", %{"is_public" => false})

    view = guest(~p"/groups/#{app.id}")

    assert %{ok: true} = call(view, "show_group", %{"id" => open.id})
    assert has_element?(view, "#guest-sheet-description", "Ovde je park.")

    render_hook(view, "guest_sheet_close", %{})
    assert_push_event(view, "group_sheet_closed", %{id: open_id})
    assert open_id == open.id
    refute has_element?(view, "#guest-sheet")

    assert %{ok: true} = call(view, "show_group", %{"id" => public.id})
    assert has_element?(view, "#guest-sheet-card", "Samo kartica.")
    refute has_element?(view, "#guest-sheet-description")

    assert %{ok: false, error: "not_found"} = call(view, "show_group", %{"id" => closed.id})
  end

  test "reads the public polls and votes in none", ctx do
    public_poll = create_poll!(ctx.owner, ctx.app, %{"is_public" => "true"})
    _members_poll = create_poll!(ctx.owner, ctx.app, %{"question" => "Samo članovi?"})

    view = guest(~p"/groups/#{ctx.app.id}")

    assert %{ok: true, polls: [poll]} = call(view, "list_polls")
    assert poll.id == public_poll.id
    refute poll.can_vote
    refute poll.voted

    assert %{ok: true, poll: %{id: id}} = call(view, "get_poll", %{"id" => public_poll.id})
    assert id == public_poll.id
  end

  test "maps the public places only", ctx do
    map =
      group!(ctx.owner, ctx.parent, "ga-places", %{
        "description" => "<p>map</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true,
        "description_for_guests" => true
      })

    seen =
      group!(ctx.owner, map, "ga-seen", %{
        "is_public" => true,
        "latitude" => 44.8,
        "longitude" => 20.4
      })

    _hidden =
      group!(ctx.owner, map, "ga-hidden", %{
        "is_public" => false,
        "latitude" => 44.81,
        "longitude" => 20.41
      })

    view = guest(~p"/groups/#{map.id}")

    assert %{ok: true, can_create_places: false} = call(view, "map_config")
    assert %{ok: true, places: places} = call(view, "list_places")
    assert Enum.map(places, & &1.id) == [seen.id]

    assert %{ok: true, places: spot} =
             call(view, "list_places_at", %{"bounds" => [[44.0, 20.0], [45.0, 21.0]]})

    assert Enum.map(spot, & &1.id) == [seen.id]
  end

  test "refuses a call from an app no longer on screen", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")

    assert %{ok: false, error: "stale_app"} = call(view, "get_group", %{}, "123")
  end

  test "stops once the group closes its description to guests", ctx do
    view = guest(~p"/groups/#{ctx.app.id}")
    assert %{ok: true} = call(view, "get_group")

    {:ok, _closed} = Social.update_group(ctx.owner, ctx.app, %{"description_for_guests" => false})

    assert %{ok: false, error: "unavailable"} = call(view, "get_group")
    assert has_element?(view, "#guest-app-unavailable")
    refute has_element?(view, "#group-app-frame")
  end

  test "runs an alternative description's app with its own id", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.app, %{
        "name" => "Tabla",
        "description" => "<p>tabla</p>",
        "uses_api" => "true",
        "for_guests" => "true"
      })

    view = guest(~p"/groups/#{ctx.app.id}/group_home?#{[d: alt.id]}")

    assert has_element?(view, "#group-app-frame-alt-#{alt.id}")

    assert %{ok: true, group: %{description_id: id}} =
             call(view, "get_description", %{}, "#{alt.id}")

    assert id == alt.id
    assert %{ok: false, error: "stale_app"} = call(view, "get_description")
  end

  test "an app the group keeps from guests shows only its card", ctx do
    {:ok, _closed} = Social.update_group(ctx.owner, ctx.app, %{"description_for_guests" => false})

    conn = get(build_conn(), ~p"/groups/#{ctx.app.id}")
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "#public-group")) == 1
    assert Enum.empty?(LazyHTML.query(document, "[data-phx-session]"))
  end

  describe "a story of a feed" do
    setup ctx do
      {:ok, %{feed: feed}} =
        Social.create_group_from_preset(ctx.owner, Social.get_root_group!(), "feed", %{
          "name" => "ga-feed",
          "is_public" => true
        })

      %{preset_feed: feed}
    end

    defp create_story(view) do
      render_hook(view, "app_api", %{
        "method" => "create_child",
        "params" => %{
          "name" => "story",
          "description" => "text",
          "is_public" => true,
          "description_for_guests" => true
        }
      })

      assert_reply(view, %{ok: true, group: %{id: id}})
      Social.get_group!(id)
    end

    defp open_as_owner(ctx, group) do
      {:ok, view, _html} =
        build_conn()
        |> log_in_account(ctx.owner_account)
        |> live(~p"/groups/#{group.id}/group_home")

      view
    end

    test "goes to guests when the stories of `.feed` do", ctx do
      {:ok, feed} =
        Social.update_group(ctx.owner, ctx.preset_feed, %{"description_for_guests" => true})

      assert create_story(open_as_owner(ctx, feed)).description_for_guests
    end

    test "stays with members under a `.feed` that does, whatever the app asks", ctx do
      refute create_story(open_as_owner(ctx, ctx.preset_feed)).description_for_guests
    end
  end
end
