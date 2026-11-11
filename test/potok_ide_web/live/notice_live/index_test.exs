defmodule PotokIdeWeb.NoticeLive.IndexTest do
  @moduledoc """
  The page of notices: what the followed groups sent, read on opening, and the
  followed groups with their push switches. Also the badge on the profile's
  other pages, and the switch for every notice in Settings.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures, only: [account_fixture: 0]
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Notices
  alias PotokIde.Notices.{GroupNotice, GroupNoticeReceipt}
  alias PotokIde.Repo
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("nl-owner")
    {reader_account, reader} = account_with_profile!("nl-reader")
    group = group_with_members!(owner, [], %{"is_public" => true})
    {:ok, _follow} = Notices.follow(reader, group)

    %{
      owner: owner,
      owner_account: owner_account,
      reader: reader,
      reader_account: reader_account,
      group: group
    }
  end

  defp open(conn, account, path \\ ~p"/notices") do
    {:ok, view, _html} = conn |> log_in_account(account) |> live(path)
    view
  end

  defp send!(author, group, body \\ "The library opens at 9.") do
    access = Social.get_group_access(author, group)
    {:ok, notice} = Notices.send_notice(author, group, access, %{"body" => body})
    notice
  end

  test "asks for a profile first", %{conn: conn} do
    account = account_fixture()

    assert {:error, {:redirect, %{to: "/profiles"}}} =
             conn |> log_in_account(account) |> live(~p"/notices")
  end

  test "the bell in the header leads here", ctx do
    view = open(ctx.conn, ctx.reader_account, ~p"/invitations")
    assert has_element?(view, "#nav-notices-link[href='/notices']")
  end

  test "the menu leads to the help page", ctx do
    view = open(ctx.conn, ctx.reader_account, ~p"/invitations")
    assert has_element?(view, "#app-sidebar #app-help-link[href='/pomoc']")
  end

  describe "received notices" do
    test "come newest first, the unread marked, and opening reads them", ctx do
      first = send!(ctx.owner, ctx.group, "First")
      second = send!(ctx.owner, ctx.group, "Second")
      assert %{count: 2} = Notices.unread_snapshot(ctx.reader)

      view = open(ctx.conn, ctx.reader_account)

      assert has_element?(view, "#notice-#{first.id}[data-unread='true']", "First")
      assert has_element?(view, "#notice-#{second.id}[data-unread='true']", "Second")

      assert has_element?(
               view,
               "#notice-#{second.id} a[href='/groups/#{ctx.group.id}/notices?notice=#{second.id}']"
             )

      assert render(view) =~ ~r/notice-#{second.id}.*notice-#{first.id}/s
      assert %{count: 0} = Notices.unread_snapshot(ctx.reader)
      assert has_element?(view, "#nav-notices-count-badge[hidden]")
    end

    test "reading here clears the badge on the profile's other pages", ctx do
      send!(ctx.owner, ctx.group)
      other_page = open(ctx.conn, ctx.reader_account, ~p"/invitations")
      assert has_element?(other_page, "#nav-notices-count-badge", "1")

      open(ctx.conn, ctx.reader_account)

      assert_push_event(other_page, "unread_notices_count_updated", %{count: 0})
    end

    test "a notice that arrives while the page is open comes on top, already read", ctx do
      view = open(ctx.conn, ctx.reader_account)

      notice = send!(ctx.owner, ctx.group, "Just now")

      assert has_element?(view, "#notice-#{notice.id}", "Just now")
      assert %{count: 0} = Notices.unread_snapshot(ctx.reader)
      refute_push_event(view, "unread_notices_count_updated", %{count: 1})
    end

    test "a deleted notice leaves the page", ctx do
      notice = send!(ctx.owner, ctx.group)
      view = open(ctx.conn, ctx.reader_account)
      assert has_element?(view, "#notice-#{notice.id}")

      access = Social.get_group_access(ctx.owner, ctx.group)
      {:ok, _notice} = Notices.delete_notice(ctx.owner, ctx.group, access, notice.id)

      refute has_element?(view, "#notice-#{notice.id}")
    end

    test "load 20 at a time", ctx do
      for n <- 1..21 do
        notice =
          Repo.insert!(%GroupNotice{
            group_id: ctx.group.id,
            creator_id: ctx.owner.id,
            body: "N#{n}"
          })

        Repo.insert!(%GroupNoticeReceipt{notice_id: notice.id, profile_id: ctx.reader.id})
      end

      view = open(ctx.conn, ctx.reader_account)
      assert view |> element("#notices") |> render() |> count_rows() == 20

      view |> element("#notices-load-more") |> render_click()

      assert view |> element("#notices") |> render() |> count_rows() == 21
      refute has_element?(view, "#notices-load-more")
    end

    test "says so when there are none", ctx do
      {_account, _profile} = account_with_profile!("nl-empty")
      {empty_account, _empty} = account_with_profile!("nl-empty2")

      assert has_element?(open(ctx.conn, empty_account), "#notices-empty")
    end
  end

  describe "followed groups" do
    test "each has its push switch and a way to stop following", ctx do
      view = open(ctx.conn, ctx.reader_account)
      view |> element("#notices-tab-followed") |> render_click()

      assert has_element?(view, "#notices-tab-followed", "1")
      assert has_element?(view, "#follow-push-#{ctx.group.id}[aria-checked='true']")

      view |> element("#follow-push-#{ctx.group.id}") |> render_click()
      assert has_element?(view, "#follow-push-#{ctx.group.id}[aria-checked='false']")
      assert %{push?: false} = Notices.group_state(ctx.group, ctx.reader)

      view |> element("#unfollow-#{ctx.group.id}") |> render_click()
      refute has_element?(view, "#followed-group-#{ctx.group.id}")
      assert has_element?(view, "#followed-groups-empty")
    end

    test "say where to turn push on when the profile turned it off", ctx do
      {:ok, _profile} = Notices.set_notice_push(ctx.reader, false)
      view = open(ctx.conn, ctx.reader_account)

      assert has_element?(view, "#notices-push-off")
      assert has_element?(view, "#follow-push-#{ctx.group.id}[disabled]")
    end
  end

  test "another profile of the account brings its own notices", ctx do
    notice = send!(ctx.owner, ctx.group)
    view = open(ctx.conn, ctx.reader_account)
    assert has_element?(view, "#notice-#{notice.id}")

    {:ok, other} =
      Social.create_profile_for_account(ctx.reader_account, %{
        username: "nl-other",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, _account} = Accounts.set_current_profile(ctx.reader_account, other)

    refute has_element?(view, "#notice-#{notice.id}")
    assert has_element?(view, "#notices-empty")
  end

  test "pages that do not list notices live through their messages", ctx do
    id = ctx.reader.id

    for path <- [~p"/invitations", ~p"/requests", ~p"/profiles", ~p"/accounts/settings"] do
      view = open(ctx.conn, ctx.reader_account, path)

      for message <- [
            {:received, id, 1, ctx.group.id},
            {:read, id},
            {:deleted, id, 1, ctx.group.id, true},
            {:follow_changed, id, ctx.group.id},
            {:push_changed, id, true}
          ] do
        send(view.pid, {:notices, message})
      end

      assert render(view) =~ "nav-notices-link"
    end
  end

  test "the page lives through the profile's other messages", ctx do
    view = open(ctx.conn, ctx.reader_account)
    send(view.pid, {:profile_invitations_updated, ctx.reader.id})
    send(view.pid, {:group_unread_counts_updated, ctx.reader.id, ctx.group.id})

    assert render(view) =~ "notices-page"
  end

  describe "the switch for every notice in Settings" do
    test "turns the push of all notices off and on", ctx do
      view = open(ctx.conn, ctx.reader_account, ~p"/accounts/settings")

      assert has_element?(view, "#notice-push-toggle[aria-checked='true']")
      view |> element("#notice-push-toggle") |> render_click()

      assert has_element?(view, "#notice-push-toggle[aria-checked='false']")
      refute Repo.reload!(ctx.reader).notice_push

      view |> element("#notice-push-toggle") |> render_click()
      assert Repo.reload!(ctx.reader).notice_push
    end
  end

  defp count_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("article[id^='notice-']")
    |> Enum.count()
  end
end
