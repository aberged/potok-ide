defmodule PotokIdeWeb.GroupLive.NoticesTest do
  @moduledoc """
  Following a group from its page (the bell in the header) and the group's
  notices tab: who reads it, who writes there, and what a notice sent from it
  does to a follower's badge.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures, only: [create_poll!: 2]

  alias PotokIde.LinkPreviews
  alias PotokIde.Notices
  alias PotokIde.Notices.GroupNotice
  alias PotokIde.Repo
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("nt-owner")
    {member_account, member} = account_with_profile!("nt-member")
    {visitor_account, visitor} = account_with_profile!("nt-visitor")

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      visitor: visitor,
      group: group_with_members!(owner, [member], %{"is_public" => true})
    }
  end

  defp open(conn, account, path) do
    {:ok, view, _html} = conn |> log_in_account(account) |> live(path)
    view
  end

  defp open_group(conn, account, group, tab \\ "group_home"),
    do: open(conn, account, ~p"/groups/#{group.id}/#{tab}")

  defp send!(author, group, body \\ "The street is closed on Sunday.") do
    access = Social.get_group_access(author, group)
    {:ok, notice} = Notices.send_notice(author, group, access, %{"body" => body})
    notice
  end

  # Every linked page answers with the same Open Graph card.
  defp stub_linked_page! do
    Req.Test.stub(LinkPreviews, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, """
      <html><head>
        <meta property="og:title" content="Example article">
        <meta property="og:description" content="A short summary.">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="https://cdn.example.com/card.png">
      </head></html>
      """)
    end)
  end

  describe "the bell" do
    test "follows a public group from outside with one tap, then opens a menu", ctx do
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#group-follow-button")
      refute has_element?(view, "#group-follow-menu")

      view |> element("#group-follow-button") |> render_click()

      assert has_element?(view, "#group-follow-menu")
      refute has_element?(view, "#group-follow-button")
      assert %{following?: true, push?: true} = Notices.group_state(ctx.group, ctx.visitor)
    end

    test "its menu turns the group's push off and stops following", ctx do
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#group-follow-push[aria-checked='true']")
      view |> element("#group-follow-push") |> render_click()
      assert has_element?(view, "#group-follow-push[aria-checked='false']")
      assert %{push?: false} = Notices.group_state(ctx.group, ctx.visitor)

      view |> element("#group-unfollow") |> render_click()
      assert has_element?(view, "#group-follow-button")
      assert %{following?: false} = Notices.group_state(ctx.group, ctx.visitor)
    end

    test "says where to turn push back on when the profile turned it off", ctx do
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      {:ok, _profile} = Notices.set_notice_push(ctx.visitor, false)
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group)

      assert has_element?(view, "#group-follow-push[disabled]")

      assert has_element?(
               view,
               "#group-follow-push-off a[href='/accounts/settings#notice-push-settings']"
             )
    end

    test "is not on the root or a direct conversation", ctx do
      root = Social.get_root_group!()
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

      refute has_element?(
               open(ctx.conn, ctx.owner_account, ~p"/groups/#{root.id}"),
               "#group-follow-button"
             )

      refute has_element?(
               open_group(ctx.conn, ctx.owner_account, direct, "values"),
               "#group-follow-button"
             )
    end

    test "a follow made on another page shows here", ctx do
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group)
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)

      assert render(view) =~ "group-follow-menu"
      assert has_element?(view, "#group-follow-menu")
    end
  end

  describe "the notices tab" do
    test "everyone who sees the group reads it, the author only its members", ctx do
      notice = send!(ctx.owner, ctx.group)

      visitor_view = open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")
      assert has_element?(visitor_view, "#group-panel-notices")
      assert has_element?(visitor_view, "#group-notice-#{notice.id}", "The street is closed")
      refute has_element?(visitor_view, "#group-notice-#{notice.id}-author")
      refute has_element?(visitor_view, "#group-notice-form")
      refute has_element?(visitor_view, "#group-notice-#{notice.id}-delete")

      member_view = open_group(ctx.conn, ctx.member_account, ctx.group, "notices")
      assert has_element?(member_view, "#group-notice-#{notice.id}-author", ctx.owner.username)
      refute has_element?(member_view, "#group-notice-form")
    end

    test "says when the group has sent nothing yet", ctx do
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")

      assert has_element?(view, "#group-notices-empty")
      assert has_element?(view, "#group-notices-follow")
      assert has_element?(view, "#group-notices-followers", "0")
    end

    test "a sender's notice shows at once and raises a follower's badge on another page", ctx do
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      follower_page = open(ctx.conn, ctx.visitor_account, ~p"/invitations")

      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")
      assert has_element?(view, "#group-notice-send", "1")

      view
      |> form("#group-notice-form", notice: %{body: "Meeting on Friday at 6."})
      |> render_submit()

      assert [%GroupNotice{id: id, recipients_count: 1}] = Repo.all(GroupNotice)
      assert has_element?(view, "#group-notice-#{id}", "Meeting on Friday")
      assert has_element?(view, "#group-notice-#{id}-reached")

      assert_push_event(follower_page, "unread_notices_count_updated", %{count: 1})
      assert has_element?(follower_page, "#nav-notices-count-badge", "1")
    end

    test "an empty notice stays a draft with its error", ctx do
      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")

      view |> form("#group-notice-form", notice: %{body: "   "}) |> render_submit()

      assert has_element?(view, "#group-notice-form .text-error")
      assert Repo.aggregate(GroupNotice, :count) == 0
    end

    test "a role with the permission writes there", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "editors"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, role.key, :send_notices, :allow)

      {:ok, _member_role} =
        Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)

      view = open_group(ctx.conn, ctx.member_account, ctx.group, "notices")
      assert has_element?(view, "#group-notice-form")
    end

    test "the author and the senders delete a notice", ctx do
      notice = send!(ctx.owner, ctx.group)

      member_view = open_group(ctx.conn, ctx.member_account, ctx.group, "notices")
      refute has_element?(member_view, "#group-notice-#{notice.id}-delete")

      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")
      view |> element("#group-notice-#{notice.id}-delete") |> render_click()

      refute has_element?(view, "#group-notice-#{notice.id}")
      assert Repo.aggregate(GroupNotice, :count) == 0
      refute has_element?(member_view, "#group-notice-#{notice.id}")
    end

    test "a notice sent while the tab is open comes on top, and is read", ctx do
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")

      notice = send!(ctx.owner, ctx.group)

      assert has_element?(view, "#group-notice-#{notice.id}")
      assert %{count: 0} = Notices.unread_snapshot(ctx.visitor)
    end

    test "opening it reads the group's notices", ctx do
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      send!(ctx.owner, ctx.group)
      assert %{count: 1} = Notices.unread_snapshot(ctx.visitor)

      open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")

      assert %{count: 0} = Notices.unread_snapshot(ctx.visitor)
    end

    test "a link to one notice marks it", ctx do
      notice = send!(ctx.owner, ctx.group)

      view =
        open(
          ctx.conn,
          ctx.visitor_account,
          ~p"/groups/#{ctx.group.id}/notices?notice=#{notice.id}"
        )

      assert has_element?(view, "#group-notice-#{notice.id}[data-focus='true']")
    end
  end

  describe "the card of a notice's link" do
    test "comes to the sender's tab and to a follower's open one", ctx do
      stub_linked_page!()
      {:ok, _follow} = Notices.follow(ctx.visitor, ctx.group)
      follower_view = open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")
      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")
      Req.Test.allow(LinkPreviews, self(), view.pid)

      view
      |> form("#group-notice-form", notice: %{body: "Read https://example.com/article"})
      |> render_submit()

      assert [%GroupNotice{id: id}] = Repo.all(GroupNotice)

      assert has_element?(
               view,
               "#group-notice-#{id} #notice-link-preview-#{id}",
               "Example article"
             )

      assert has_element?(view, "#notice-link-preview-#{id}", "A short summary.")

      assert has_element?(
               view,
               "#notice-link-preview-link-#{id}[href='https://example.com/article'][target=_blank]"
             )

      assert has_element?(
               view,
               "#notice-link-preview-image-#{id}[src='https://cdn.example.com/card.png'][referrerpolicy=no-referrer]"
             )

      assert has_element?(follower_view, "#notice-link-preview-#{id}", "Example article")
    end

    test "its × is for whoever may delete the notice, and takes it from every page", ctx do
      stub_linked_page!()
      notice = send!(ctx.owner, ctx.group, "https://example.com/article")

      member_view = open_group(ctx.conn, ctx.member_account, ctx.group, "notices")
      assert has_element?(member_view, "#notice-link-preview-#{notice.id}")
      refute has_element?(member_view, "#notice-link-preview-dismiss-#{notice.id}")

      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")
      view |> element("#notice-link-preview-dismiss-#{notice.id}") |> render_click()

      refute has_element?(view, "#notice-link-preview-#{notice.id}")
      assert has_element?(view, "#group-notice-#{notice.id}", "https://example.com/article")
      refute has_element?(member_view, "#notice-link-preview-#{notice.id}")
      assert Repo.get!(GroupNotice, notice.id).link_preview == nil

      refute has_element?(
               open_group(ctx.conn, ctx.owner_account, ctx.group, "notices"),
               "#notice-link-preview-#{notice.id}"
             )
    end

    test "a notice without a link has none", ctx do
      notice = send!(ctx.owner, ctx.group)
      view = open_group(ctx.conn, ctx.owner_account, ctx.group, "notices")

      assert has_element?(view, "#group-notice-#{notice.id}")
      refute has_element?(view, "#notice-link-preview-#{notice.id}")
    end
  end

  describe "the way there" do
    test "the group's menu leads there for any group that can be followed", ctx do
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group)
      assert has_element?(view, "#group-tab-notices")
    end

    test "the bar has the section once the group sent a notice", ctx do
      refute has_element?(
               open_group(ctx.conn, ctx.visitor_account, ctx.group),
               "#group-notices-summary"
             )

      send!(ctx.owner, ctx.group)

      assert has_element?(
               open_group(ctx.conn, ctx.visitor_account, ctx.group),
               "#group-notices-summary"
             )

      assert has_element?(
               open_group(ctx.conn, ctx.member_account, ctx.group),
               "#group-notices-summary"
             )
    end

    test "a full bar leaves notices to the menu", ctx do
      send!(ctx.owner, ctx.group)
      create_poll!(ctx.owner, ctx.group)

      view = open_group(ctx.conn, ctx.member_account, ctx.group, "values")

      assert has_element?(view, "#group-polls-summary")
      refute has_element?(view, "#group-notices-summary")
      assert has_element?(view, "#group-tab-notices")
    end
  end

  test "the page lives through the profile's notice messages", ctx do
    view = open_group(ctx.conn, ctx.visitor_account, ctx.group)
    id = ctx.visitor.id

    for message <- [
          {:received, id, 1, ctx.group.id},
          {:read, id},
          {:deleted, id, 1, ctx.group.id, true},
          {:preview_changed, id, 1, ctx.group.id},
          {:follow_changed, id, ctx.group.id + 1},
          {:push_changed, id, false}
        ] do
      send(view.pid, {:notices, message})
    end

    assert render(view) =~ "group-header"
  end

  test "the card of a notice not on screen changes nothing", ctx do
    for tab <- ["group_home", "notices"] do
      view = open_group(ctx.conn, ctx.visitor_account, ctx.group, tab)
      send(view.pid, {:group_notices, {:preview_changed, 1}})

      assert render(view) =~ "group-header"
      refute has_element?(view, "#group-notice-1")
    end
  end

  test "a card for a notice the open tab does not show leaves it out", ctx do
    view = open_group(ctx.conn, ctx.visitor_account, ctx.group, "notices")

    notice =
      Repo.insert!(%GroupNotice{
        group_id: ctx.group.id,
        creator_id: ctx.owner.id,
        body: "https://example.com/article",
        link_preview: %{"url" => "https://example.com/article", "title" => "Example article"}
      })

    send(view.pid, {:group_notices, {:preview_changed, notice.id}})

    refute has_element?(view, "#group-notice-#{notice.id}")
  end
end
