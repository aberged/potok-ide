defmodule PotokIdeWeb.GroupLive.AppSubgroupsTest do
  @moduledoc """
  What an app can reach below its group: the groups under one of its direct
  sub-groups, as far as the viewer can see them, and the chat of those groups.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("app-sub-owner")
    {visitor_account, visitor} = account_with_profile!("app-sub-visitor")

    {:ok, app_group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "app-sub-group",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "uses_api" => true
      })

    feed = child!(owner, app_group, ".feed", %{"is_public" => true})

    %{
      owner_account: owner_account,
      owner: owner,
      visitor_account: visitor_account,
      visitor: visitor,
      app_group: app_group,
      feed: feed
    }
  end

  defp child!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => name,
            "description" => "",
            "description_format" => :markdown,
            "is_public" => true
          },
          attrs
        )
      )

    group
  end

  defp open_app(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp list(view, params) do
    render_hook(view, "app_api", %{"method" => "list_subgroups", "params" => params})
  end

  defp open_group(view, id, params \\ %{}) do
    render_hook(view, "app_api", %{
      "method" => "open_group",
      "params" => Map.put(params, "id", id)
    })
  end

  defp assert_groups(view, expected, has_more) do
    assert_reply(view, %{ok: true, groups: groups, has_more: ^has_more})
    assert Enum.map(groups, & &1.name) == expected
    groups
  end

  describe "list_subgroups" do
    test "lists the newest first, page by page", ctx do
      for name <- ~w(first second third) do
        child!(ctx.owner, ctx.feed, name)
      end

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed", "limit" => 2})
      [_third, second] = assert_groups(view, ~w(third second), true)

      list(view, %{"name" => ".feed", "limit" => 2, "before_id" => second.id})
      assert_groups(view, ~w(first), false)
    end

    test "a limit over the maximum is cut down, none gets the default", ctx do
      for number <- 1..21 do
        child!(ctx.owner, ctx.feed, "story-#{number}")
      end

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      assert_reply(view, %{ok: true, groups: default_page, has_more: true})
      assert length(default_page) == 20

      list(view, %{"name" => ".feed", "limit" => 500})
      assert_reply(view, %{ok: true, groups: all, has_more: false})
      assert length(all) == 21
    end

    test "gives the sanitized description and what a card needs", ctx do
      story =
        child!(ctx.owner, ctx.feed, "story", %{
          "description" => "# Title\n\n**bold**<script>alert(1)</script>"
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      [card] = assert_groups(view, ~w(story), false)

      assert card.id == story.id
      assert card.description_html =~ "<h1>Title</h1>"
      assert card.description_html =~ "<strong>bold</strong>"
      refute card.description_html =~ "<script"
      assert card.picture_url =~ "/avatar/group/#{story.id}"
      assert card.uses_api == false
    end

    test "sanitizes an HTML description too", ctx do
      child!(ctx.owner, ctx.feed, "story", %{
        "description" => ~s|<p onclick="steal()">text</p><script>steal()</script>|,
        "description_format" => :html
      })

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      [card] = assert_groups(view, ~w(story), false)

      assert card.description_html =~ "text"
      refute card.description_html =~ "steal"
    end

    test "gives no text for an app or an empty description", ctx do
      child!(ctx.owner, ctx.feed, "an-app", %{
        "description" => "<script>run()</script>",
        "description_format" => :html,
        "uses_api" => true
      })

      child!(ctx.owner, ctx.feed, "empty", %{"description" => "  \n"})

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      [empty, app] = assert_groups(view, ~w(empty an-app), false)

      assert empty.description_html == nil
      assert app.description_html == nil
      assert app.uses_api == true
    end

    test "says what an app says about itself, and nothing for other groups", ctx do
      child!(ctx.owner, ctx.feed, "silent-app", %{
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true
      })

      child!(ctx.owner, ctx.feed, "app", %{
        "description" =>
          ~s|<meta name="description" content="Igra za dvoje"><script>document.write("x")</script>|,
        "description_format" => :html,
        "uses_api" => true
      })

      child!(ctx.owner, ctx.feed, "text", %{
        "description" => ~s|<meta name="description" content="Nije aplikacija">|,
        "description_format" => :html
      })

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      [text, app, silent] = assert_groups(view, ~w(text app silent-app), false)

      assert app.app_description == "Igra za dvoje"
      assert app.description_html == nil
      assert silent.app_description == nil
      assert text.app_description == nil
    end

    test "a private story reaches its members only", ctx do
      private = child!(ctx.owner, ctx.feed, "private", %{"is_public" => false})
      child!(ctx.owner, ctx.feed, "public")

      owner_view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      list(owner_view, %{"name" => ".feed"})
      assert_groups(owner_view, ~w(public private), false)

      visitor_view = open_app(ctx.conn, ctx.visitor_account, ctx.app_group)
      list(visitor_view, %{"name" => ".feed"})
      assert_groups(visitor_view, ~w(public), false)

      {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, private, ctx.visitor)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.visitor)

      list(visitor_view, %{"name" => ".feed"})
      assert_groups(visitor_view, ~w(public private), false)
    end

    test "a viewer who cannot see the sub-group finds nothing under it", ctx do
      hidden = child!(ctx.owner, ctx.app_group, ".hidden", %{"is_public" => false})
      child!(ctx.owner, hidden, "public-below-private")

      visitor_view = open_app(ctx.conn, ctx.visitor_account, ctx.app_group)
      list(visitor_view, %{"name" => ".hidden"})

      assert_reply(visitor_view, %{ok: false, error: "not_found"})
    end

    test "leaves out threads", ctx do
      story = child!(ctx.owner, ctx.feed, "story")
      {:ok, value} = Social.create_value(ctx.owner, ctx.feed, %{"content" => "hello"})

      {:ok, _thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.feed, value, %{"name" => "a thread"})

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      list(view, %{"name" => ".feed"})

      [card] = assert_groups(view, ~w(story), false)
      assert card.id == story.id
    end

    test "finds the sub-group by its exact name, the oldest of several", ctx do
      child!(ctx.owner, ctx.feed, "in-the-oldest")

      newer = child!(ctx.owner, ctx.app_group, ".feed")
      child!(ctx.owner, newer, "in-the-newer")

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      list(view, %{"name" => ".feed"})
      assert_groups(view, ~w(in-the-oldest), false)

      list(view, %{"name" => ".fee"})
      assert_reply(view, %{ok: false, error: "not_found"})

      list(view, %{})
      assert_reply(view, %{ok: false, error: "not_found"})
    end

    test "reaches only below its own group", ctx do
      {:ok, other} =
        Social.create_group(ctx.owner, Social.get_root_group!(), %{
          "name" => "app-sub-other",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      other_feed = child!(ctx.owner, other, ".elsewhere")
      child!(ctx.owner, other_feed, "story")

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      list(view, %{"name" => ".elsewhere"})

      assert_reply(view, %{ok: false, error: "not_found"})
    end
  end

  describe "open_group" do
    test "takes the viewer to the chat of a story", ctx do
      story = child!(ctx.owner, ctx.feed, "story")

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      open_group(view, story.id)

      assert_redirect(view, ~p"/groups/#{story.id}/values")
    end

    test "takes the viewer to the description, where an app runs", ctx do
      story =
        child!(ctx.owner, ctx.feed, "an-app", %{
          "description" => "<p>app</p>",
          "description_format" => :html,
          "uses_api" => true
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      open_group(view, story.id, %{"tab" => "description"})

      assert_redirect(view, ~p"/groups/#{story.id}/group_home")
    end

    test "any other tab is the chat", ctx do
      story = child!(ctx.owner, ctx.feed, "story")

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      open_group(view, story.id, %{"tab" => "edit_group"})

      assert_redirect(view, ~p"/groups/#{story.id}/values")
    end

    test "takes the id as text too", ctx do
      story = child!(ctx.owner, ctx.feed, "story")

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)
      open_group(view, to_string(story.id))

      assert_redirect(view, ~p"/groups/#{story.id}/values")
    end

    test "refuses what is outside the app's reach", ctx do
      {:ok, outside} =
        Social.create_group(ctx.owner, Social.get_root_group!(), %{
          "name" => "app-sub-outside",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      deep = child!(ctx.owner, child!(ctx.owner, ctx.feed, "story"), "below-a-story")

      {:ok, value} = Social.create_value(ctx.owner, ctx.feed, %{"content" => "hello"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.feed, value, %{"name" => "a thread"})

      view = open_app(ctx.conn, ctx.owner_account, ctx.app_group)

      for id <- [outside.id, ctx.app_group.id, deep.id, thread.id, "nope"],
          tab <- ["chat", "description"] do
        open_group(view, id, %{"tab" => tab})

        assert_reply(view, %{ok: false, error: "not_found"})
      end
    end

    test "refuses a story the viewer cannot see", ctx do
      private = child!(ctx.owner, ctx.feed, "private", %{"is_public" => false})

      view = open_app(ctx.conn, ctx.visitor_account, ctx.app_group)
      open_group(view, private.id)

      assert_reply(view, %{ok: false, error: "not_found"})
    end
  end
end
