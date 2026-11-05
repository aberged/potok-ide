defmodule PotokIdeWeb.GroupLive.GroupReactionsTest do
  @moduledoc """
  Reactions to a group: under its description on the group's page, and through
  the App API for a feed that shows the groups below it.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("gr-owner")
    {member_account, member} = account_with_profile!("gr-member")
    {visitor_account, visitor} = account_with_profile!("gr-visitor")

    group = text_group!(owner, Social.get_root_group!(), "group-react-text")
    add_member!(owner, group, member)

    {:ok, app_group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "group-react-app",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "uses_api" => true
      })

    feed = text_group!(owner, app_group, ".feed")
    story = text_group!(owner, feed, "story")

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      visitor: visitor,
      group: group,
      app_group: app_group,
      feed: feed,
      story: story
    }
  end

  defp text_group!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => name,
            "description" => "The text",
            "description_format" => :markdown,
            "is_public" => true
          },
          attrs
        )
      )

    group
  end

  defp open(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp api(view, method, params) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  defp pill(emoji), do: "#group-reaction-#{Base.encode16(emoji, case: :lower)}"

  describe "on the group's page" do
    test "a member adds a reaction and takes it back", ctx do
      view = open(ctx.conn, ctx.member_account, ctx.group)

      assert has_element?(view, "#group-react[data-reaction-trigger]")
      assert has_element?(view, "#reaction-picker[phx-hook=ReactionPicker]")

      render_hook(view, "toggle_group_reaction", %{"emoji" => "👍"})
      assert has_element?(view, ~s(#{pill("👍")}[aria-pressed="true"]))

      view |> element(pill("👍")) |> render_click()
      refute has_element?(view, pill("👍"))
    end

    test "a visitor of a public group reacts without joining", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      render_hook(view, "toggle_group_reaction", %{"emoji" => "❤️"})

      assert has_element?(view, pill("❤️"))
      refute Social.member_of_group?(ctx.visitor, ctx.group)
    end

    test "with reactions closed to \"everyone\" a visitor sees them and adds none", ctx do
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.owner, ctx.group, "👍")
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :react, :neutral)

      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#{pill("👍")}[disabled]")
      refute has_element?(view, "#group-react")
      refute has_element?(view, "#reaction-picker")

      render_hook(view, "toggle_group_reaction", %{"emoji" => "❤️"})
      refute has_element?(view, pill("❤️"))
    end

    test "with no reactions and none allowed there is no row", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :react, :neutral)

      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      refute has_element?(view, "#group-reactions")
    end

    test "reaches the others who have the group open", ctx do
      watching = open(ctx.conn, ctx.visitor_account, ctx.group)
      refute has_element?(watching, pill("👍"))

      {:ok, _reactions} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")

      assert has_element?(watching, ~s(#{pill("👍")}[aria-pressed="false"]))
    end

    test "a group that is an app has no row, and the picker for its app", ctx do
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.owner, ctx.app_group, "👍")

      view = open(ctx.conn, ctx.member_account, ctx.app_group)

      refute has_element?(view, "#group-reactions")
      assert has_element?(view, "#reaction-picker")
    end
  end

  describe "in the app API" do
    test "list_subgroups says what a card needs", ctx do
      {:ok, _} = Social.create_value(ctx.owner, ctx.story, %{"content" => "one"})
      {:ok, _} = Social.create_value(ctx.owner, ctx.story, %{"content" => "two"})
      {:ok, _} = Social.toggle_group_reaction(ctx.owner, ctx.story, "👍")
      {:ok, _} = Social.toggle_group_reaction(ctx.visitor, ctx.story, "👍")

      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)
      api(view, "list_subgroups", %{"name" => ".feed"})

      assert_reply(view, %{ok: true, groups: [story]})
      assert story.comment_count == 2
      assert story.can_react
      assert story.reactions == [%{emoji: "👍", count: 2, mine: true}]
    end

    test "a group nobody reacted to or wrote in has none of it, and the viewer's right", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.story)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.story, "everyone", :react, :neutral)

      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)
      api(view, "list_subgroups", %{"name" => ".feed"})

      assert_reply(view, %{ok: true, groups: [story]})
      assert story.comment_count == 0
      assert story.reactions == []
      refute story.can_react
    end

    test "a visitor reacts to a story and takes the reaction back", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      api(view, "toggle_group_reaction", %{"id" => ctx.story.id, "emoji" => "🎉"})
      assert_reply(view, %{ok: true, reactions: [%{emoji: "🎉", count: 1, mine: true}]})

      api(view, "toggle_group_reaction", %{"id" => ctx.story.id, "emoji" => "🎉"})
      assert_reply(view, %{ok: true, reactions: []})
    end

    test "reaches two levels below the app and no others", ctx do
      unrelated = text_group!(ctx.owner, Social.get_root_group!(), "group-react-unrelated")
      too_deep = text_group!(ctx.owner, ctx.story, "too-deep")

      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      for %{id: id} <- [ctx.feed, ctx.story] do
        api(view, "toggle_group_reaction", %{"id" => id, "emoji" => "👍"})
        assert_reply(view, %{ok: true})
      end

      for id <- [unrelated.id, too_deep.id, "nope"] do
        api(view, "toggle_group_reaction", %{"id" => id, "emoji" => "👍"})
        assert_reply(view, %{ok: false, error: "not_found"})
      end
    end

    test "an app cannot react to the group above it, though it can share it", ctx do
      {:ok, nested_app} =
        Social.create_group(ctx.owner, ctx.app_group, %{
          "name" => "nested-app",
          "description" => "<p>app</p>",
          "description_format" => :html,
          "is_public" => true,
          "uses_api" => true
        })

      view = open(ctx.conn, ctx.visitor_account, nested_app)

      api(view, "toggle_group_reaction", %{"id" => ctx.app_group.id, "emoji" => "👍"})
      assert_reply(view, %{ok: false, error: "not_found"})

      api(view, "share_group", %{"id" => ctx.app_group.id})
      assert_reply(view, %{ok: true})
    end

    test "a private story stays out of a visitor's reach", ctx do
      hidden = text_group!(ctx.owner, ctx.feed, "hidden", %{"is_public" => false})
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      api(view, "toggle_group_reaction", %{"id" => hidden.id, "emoji" => "👍"})
      assert_reply(view, %{ok: false, error: "not_found"})
    end

    test "refuses a viewer who may not react, and what is no emoji", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      api(view, "toggle_group_reaction", %{"id" => ctx.story.id, "emoji" => "hello"})
      assert_reply(view, %{ok: false, error: "invalid_emoji"})

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.story)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.story, "everyone", :react, :neutral)

      api(view, "toggle_group_reaction", %{"id" => ctx.story.id, "emoji" => "👍"})
      assert_reply(view, %{ok: false, error: "forbidden"})
    end

    test "reactions count as writes", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      # Tokens come back as time passes, so a busy machine takes more than 30 writes.
      refused =
        Enum.find_value(1..300, fn _attempt ->
          api(view, "toggle_group_reaction", %{"id" => ctx.story.id, "emoji" => "👍"})
          assert_reply(view, reply)
          if !reply.ok, do: reply
        end)

      assert %{error: "rate_limited"} = refused
    end

    test "share_group hands the page the link of a group in reach", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      api(view, "share_group", %{"id" => ctx.story.id})
      assert_reply(view, %{ok: true})

      url = url(~p"/groups/#{ctx.story.id}")
      assert_push_event(view, "app_share_link", %{url: ^url})
    end

    test "share_group refuses a group out of reach", ctx do
      unrelated = text_group!(ctx.owner, Social.get_root_group!(), "group-react-far")
      view = open(ctx.conn, ctx.visitor_account, ctx.app_group)

      api(view, "share_group", %{"id" => unrelated.id})
      assert_reply(view, %{ok: false, error: "not_found"})
    end
  end
end
