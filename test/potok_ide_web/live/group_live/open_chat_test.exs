defmodule PotokIdeWeb.GroupLive.OpenChatTest do
  @moduledoc """
  An open chat on the group's page: what someone outside the group sees and may
  do there, blocking from a message, and the switch in Edit group.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupValueRead, Value}

  setup do
    {owner_account, owner} = account_with_profile!("oc-owner")
    {member_account, member} = account_with_profile!("oc-member")
    {visitor_account, visitor} = account_with_profile!("oc-visitor")

    group = group!(owner, "oc-group", %{"has_public_chat" => true})
    add_member!(owner, group, member)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      visitor: visitor,
      group: group
    }
  end

  defp group!(owner, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
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

  # A group where only administrators write: `everyone` may not.
  defp read_only_group!(owner, name) do
    group = group!(owner, name)

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    {:ok, _role} =
      Social.set_group_role_permission(owner, group, "everyone", :post_values, :neutral)

    group
  end

  defp open(conn, account, group, tab \\ "values") do
    {:ok, view, _html} = conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/#{tab}")
    view
  end

  defp send_message(view, content) do
    view |> form("#group-value-form", value: %{content: content}) |> render_submit()
  end

  defp value!(profile, group, content) do
    {:ok, value} = Social.create_value(profile, group, %{"content" => content})
    value
  end

  describe "outside the group, in an open chat" do
    test "the messages show, with the place to write", ctx do
      value = value!(ctx.member, ctx.group, "hi")
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#group-panel-values")
      assert has_element?(view, "#value-#{value.id}")
      assert has_element?(view, "#group-value-form")
      refute has_element?(view, "#group-panel-description")
      assert has_element?(view, "#group-values-summary")
    end

    test "the way to join stays", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#group-request-access")
    end

    test "there is no way to send a file", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      refute has_element?(view, "#group-value-form input[type=file]")
    end

    test "a message goes out without joining", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      send_message(view, "hello from outside")

      assert has_element?(view, "#group-values-feed", "hello from outside")
      refute Social.member_of_group?(ctx.visitor, ctx.group)
    end

    test "a member sees it arrive", ctx do
      view = open(ctx.conn, ctx.member_account, ctx.group)

      value = value!(ctx.visitor, ctx.group, "hello from outside")
      render(view)

      assert has_element?(view, "#value-#{value.id}", "hello from outside")
    end

    test "a message arrives while the page is open", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      value = value!(ctx.member, ctx.group, "hi there")
      render(view)

      assert has_element?(view, "#value-#{value.id}", "hi there")
    end

    test "a reply quotes the message", ctx do
      value = value!(ctx.member, ctx.group, "the question")
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      view |> element("#value-reply-#{value.id}") |> render_click()
      assert has_element?(view, "#group-value-reply-preview", "the question")

      send_message(view, "the answer")

      assert [%Value{parent_id: parent_id}] =
               ctx.group
               |> Social.list_group_values_page(limit: 1)
               |> elem(0)

      assert parent_id == value.id
    end

    test "a reaction goes on the message", ctx do
      value = value!(ctx.member, ctx.group, "hi")
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#value-react-#{value.id}")

      render_hook(view, "toggle_reaction", %{"id" => value.id, "emoji" => "👍"})

      assert [%{profile_id: profile_id}] =
               Social.get_value_for_display(value.id).reactions

      assert profile_id == ctx.visitor.id
    end

    test "threads and tags stay with the members", ctx do
      value = value!(ctx.member, ctx.group, "hi")

      {:ok, _thread} =
        Social.get_or_create_value_thread(ctx.member, ctx.group, value, %{"name" => "talk"})

      other = value!(ctx.member, ctx.group, "other")
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      refute has_element?(view, "#value-thread-#{other.id}")
      refute has_element?(view, "#value-tags-#{other.id}")

      assert has_element?(
               view,
               "#value-#{value.id} button[phx-click=open_value_thread][disabled]"
             )
    end

    test "writing too much at once says so", ctx do
      for n <- 1..10, do: value!(ctx.visitor, ctx.group, "#{n}")

      view = open(ctx.conn, ctx.visitor_account, ctx.group)
      send_message(view, "one more")

      refute has_element?(view, "#group-values-feed", "one more")
      assert has_element?(view, "#group-value-form")
    end

    test "a message over the limit says why it did not go out", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      send_message(view, String.duplicate("a", 4_001))

      assert has_element?(view, "#group-value-form p.text-error")
      assert {[], false} = Social.list_group_values_page(ctx.group)
    end

    test "the page stops writing the read marker for each message", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)
      value!(ctx.member, ctx.group, "first")
      render(view)

      refute Repo.get_by(GroupValueRead, profile_id: ctx.visitor.id, group_id: ctx.group.id)
    end

    test "opening it writes no read marker and shows no divider", ctx do
      value!(ctx.member, ctx.group, "before")
      open(ctx.conn, ctx.visitor_account, ctx.group)
      value!(ctx.member, ctx.group, "after")

      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      refute Repo.get_by(GroupValueRead, profile_id: ctx.visitor.id, group_id: ctx.group.id)
      refute has_element?(view, "#group-values-unread-divider")
    end
  end

  describe "outside the group, in a chat that is not open" do
    setup ctx do
      %{closed: group!(ctx.owner, "oc-closed")}
    end

    test "the description shows instead of the messages", ctx do
      value = value!(ctx.owner, ctx.closed, "hi")
      view = open(ctx.conn, ctx.visitor_account, ctx.closed)

      assert has_element?(view, "#group-panel-description")
      refute has_element?(view, "#group-panel-values")
      refute has_element?(view, "#value-#{value.id}")
      refute has_element?(view, "#group-value-form")
      refute has_element?(view, "#group-values-summary")
    end

    test "posting is refused", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.closed)

      render_hook(view, "create_value", %{"value" => %{"content" => "hi"}})

      assert {[], false} = Social.list_group_values_page(ctx.closed)
    end
  end

  describe "a chat closing while the page is open" do
    test "takes the messages off the page", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)
      assert has_element?(view, "#group-value-form")

      {:ok, _group} = Social.update_group(ctx.owner, ctx.group, %{"has_public_chat" => false})
      render(view)
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#group-value-form")
      assert has_element?(view, "#group-panel-description")
    end
  end

  describe "a read-only group" do
    test "tells someone outside it that they cannot write", ctx do
      group = read_only_group!(ctx.owner, "oc-news")
      {:ok, group} = Social.update_group(ctx.owner, group, %{"has_public_chat" => true})
      value = value!(ctx.owner, group, "news")

      view = open(ctx.conn, ctx.visitor_account, group)

      assert has_element?(view, "#value-#{value.id}")
      refute has_element?(view, "#group-value-form")
      assert has_element?(view, "#group-value-composer-disabled")
    end
  end

  describe "an event only for members" do
    setup ctx do
      event =
        create_event!(ctx.owner, ctx.group, event_attrs(Date.add(today(), 2)), announce: true)

      %{event: event, value: Social.get_value_for_display(event.value_id)}
    end

    test "stays hidden from someone outside the group", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#value-event-hidden-#{ctx.value.id}")
      refute has_element?(view, "#value-#{ctx.value.id}", ctx.event.title)
      refute has_element?(view, "#value-reply-#{ctx.value.id}")
    end

    test "shows to a member", ctx do
      view = open(ctx.conn, ctx.member_account, ctx.group)

      refute has_element?(view, "#value-event-hidden-#{ctx.value.id}")
      assert has_element?(view, "#value-#{ctx.value.id}", ctx.event.title)
    end

    test "stays out of a quote and of a reply", ctx do
      {:ok, reply} =
        Social.create_value(ctx.member, ctx.group, %{
          "content" => "I am coming",
          "parent_id" => ctx.value.id
        })

      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#value-#{reply.id}")
      refute has_element?(view, "#value-#{reply.id}", ctx.event.title)

      render_hook(view, "start_reply_value", %{"id" => ctx.value.id})
      refute has_element?(view, "#group-value-reply-preview")
    end
  end

  describe "a public event" do
    test "shows to someone outside the group", ctx do
      event =
        create_event!(
          ctx.owner,
          ctx.group,
          event_attrs(Date.add(today(), 2), %{"is_public" => "true"}),
          announce: true
        )

      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      refute has_element?(view, "#value-event-hidden-#{event.value_id}")
      assert has_element?(view, "#value-#{event.value_id}", event.title)
    end
  end

  describe "blocking from a message" do
    test "is for those who may remove members, on the messages of others", ctx do
      visitors = value!(ctx.visitor, ctx.group, "hello")
      owners = value!(ctx.owner, ctx.group, "hi")

      owner_view = open(ctx.conn, ctx.owner_account, ctx.group)
      assert has_element?(owner_view, "#value-block-#{visitors.id}")
      refute has_element?(owner_view, "#value-block-#{owners.id}")

      member_view = open(ctx.conn, ctx.member_account, ctx.group)
      refute has_element?(member_view, "#value-block-#{visitors.id}")
    end

    test "is not offered while the chat is not open", ctx do
      closed = group!(ctx.owner, "oc-closed")
      add_member!(ctx.owner, closed, ctx.member)
      value = value!(ctx.member, closed, "hi")

      view = open(ctx.conn, ctx.owner_account, closed)

      refute has_element?(view, "#value-block-#{value.id}")
    end

    test "stops writing on the open page, and shows in Members", ctx do
      value = value!(ctx.visitor, ctx.group, "hello")

      visitor_view = open(ctx.conn, ctx.visitor_account, ctx.group)
      assert has_element?(visitor_view, "#group-value-form")

      owner_view = open(ctx.conn, ctx.owner_account, ctx.group)
      owner_view |> element("#value-block-#{value.id}") |> render_click()

      render(visitor_view)
      _ = :sys.get_state(visitor_view.pid)

      refute has_element?(visitor_view, "#group-value-form")
      assert has_element?(visitor_view, "#group-value-composer-disabled")
      assert has_element?(visitor_view, "#value-#{value.id}")
      refute has_element?(visitor_view, "#group-request-access")

      members = open(ctx.conn, ctx.owner_account, ctx.group, "members")
      assert has_element?(members, "#group-block-#{ctx.visitor.id}")
    end

    test "removes a member", ctx do
      value = value!(ctx.member, ctx.group, "hi")
      view = open(ctx.conn, ctx.owner_account, ctx.group)

      view |> element("#value-block-#{value.id}") |> render_click()

      refute Social.member_of_group?(ctx.member, ctx.group)
    end

    test "is refused to someone without the right", ctx do
      value = value!(ctx.visitor, ctx.group, "hello")
      view = open(ctx.conn, ctx.member_account, ctx.group)

      render_hook(view, "block_value_author", %{"id" => value.id})

      assert Social.list_group_blocks(ctx.group) == []
    end
  end

  describe "the blocked in Members" do
    setup ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)
      :ok
    end

    test "are lifted from there, and writing comes back", ctx do
      view = open(ctx.conn, ctx.owner_account, ctx.group, "members")

      view |> element("#group-unblock-#{ctx.visitor.id}") |> render_click()

      refute has_element?(view, "#group-blocks-panel")

      visitor_view = open(ctx.conn, ctx.visitor_account, ctx.group)
      assert has_element?(visitor_view, "#group-value-form")
    end

    test "are not shown to a member without the right", ctx do
      view = open(ctx.conn, ctx.member_account, ctx.group, "members")

      refute has_element?(view, "#group-blocks-panel")
    end

    test "cannot ask to join", ctx do
      view = open(ctx.conn, ctx.visitor_account, ctx.group)

      render_hook(view, "request_join", %{})

      assert Social.get_pending_group_join_request(ctx.visitor, ctx.group) == nil
    end
  end

  describe "the switch in Edit group" do
    setup ctx do
      %{closed: group!(ctx.owner, "oc-closed")}
    end

    defp edit(ctx, group), do: open(ctx.conn, ctx.owner_account, group, "edit_group")

    test "opens the chat", ctx do
      view = edit(ctx, ctx.closed)
      assert has_element?(view, "#group-edit-open-chat input[type=checkbox]")

      view
      |> form("#group-edit-form", group: %{has_public_chat: "true"})
      |> render_submit()

      assert Social.get_group!(ctx.closed.id).has_public_chat
      assert has_element?(open(ctx.conn, ctx.visitor_account, ctx.closed), "#group-value-form")
    end

    test "comes up with \"Public group\" and goes with it", ctx do
      private = group!(ctx.owner, "oc-private", %{"is_public" => false})
      view = edit(ctx, private)
      refute has_element?(view, "#group-edit-open-chat")

      view |> form("#group-edit-form", group: %{is_public: "true"}) |> render_change()
      assert has_element?(view, "#group-edit-open-chat")

      view |> form("#group-edit-form", group: %{is_public: "false"}) |> render_change()
      refute has_element?(view, "#group-edit-open-chat")
    end

    test "survives a save with the group private", ctx do
      view = edit(ctx, ctx.group)

      view |> form("#group-edit-form", group: %{is_public: "false"}) |> render_submit()

      group = Social.get_group!(ctx.group.id)
      refute group.is_public
      assert group.has_public_chat
    end

    test "is not offered in a thread", ctx do
      value = value!(ctx.owner, ctx.group, "start")

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      refute has_element?(edit(ctx, thread), "#group-edit-open-chat")
    end

    test "says when those outside the group would only read", ctx do
      refute has_element?(edit(ctx, ctx.closed), "#group-edit-open-chat-read-only")

      group = read_only_group!(ctx.owner, "oc-news")

      assert has_element?(edit(ctx, group), "#group-edit-open-chat-read-only")
    end
  end

  describe "a story of a feed" do
    setup ctx do
      {:ok, %{feed: feed}} =
        Social.create_group_from_preset(ctx.owner, Social.get_root_group!(), "feed", %{
          "name" => "oc-feed",
          "is_public" => true
        })

      %{feed: feed}
    end

    defp create_story(view) do
      render_hook(view, "app_api", %{
        "method" => "create_child",
        "params" => %{"name" => "story", "description" => "text", "is_public" => true}
      })

      assert_reply(view, %{ok: true, group: %{id: id}})
      id
    end

    test "takes over the chat of `.feed`", ctx do
      {:ok, feed} = Social.update_group(ctx.owner, ctx.feed, %{"has_public_chat" => true})
      view = open(ctx.conn, ctx.owner_account, feed, "group_home")

      story = Social.get_group!(create_story(view))

      assert story.has_public_chat
    end

    test "stays closed under a `.feed` that is", ctx do
      view = open(ctx.conn, ctx.owner_account, ctx.feed, "group_home")

      refute Social.get_group!(create_story(view)).has_public_chat
    end

    test "keeps it over withdrawing and publishing again", ctx do
      {:ok, feed} = Social.update_group(ctx.owner, ctx.feed, %{"has_public_chat" => true})
      view = open(ctx.conn, ctx.owner_account, feed, "group_home")
      story = Social.get_group!(create_story(view))

      {:ok, withdrawn} = Social.withdraw_group(ctx.owner, story)
      refute withdrawn.is_public

      {:ok, published} = Social.update_group(ctx.owner, withdrawn, %{"is_public" => true})
      assert has_element?(open(ctx.conn, ctx.visitor_account, published), "#group-value-form")
    end
  end
end
