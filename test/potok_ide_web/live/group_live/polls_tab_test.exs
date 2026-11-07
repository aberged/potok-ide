defmodule PotokIdeWeb.GroupLive.PollsTabTest do
  @moduledoc """
  The overview of polls on a group, at the root, and for those outside.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Social

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("pt-owner")
    {member_account, member} = account_with_profile!("pt-member")
    group = group_with_members!(owner, [member])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => @zone})
    |> live(path)
  end

  defp overview(account, group, query \\ []) do
    {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}/polls?#{query}")
    lv
  end

  describe "the section" do
    test "comes with the group's first poll", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      refute has_element?(lv, "#group-polls-summary")

      create_poll!(ctx.owner, ctx.group)
      render(lv)

      assert has_element?(lv, "#group-polls-summary")
    end

    test "goes with the last one", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      assert has_element?(lv, "#group-polls-summary")

      {:ok, _poll} = Polls.delete_poll(ctx.owner, poll)
      render(lv)

      refute has_element?(lv, "#group-polls-summary")
    end

    test "the group's menu leads there before that", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      assert has_element?(lv, "#group-tab-polls")
      assert has_element?(overview(ctx.member_account, ctx.group), "#polls-empty")
    end

    test "is not for a direct conversation", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

      lv = overview(ctx.owner_account, direct)
      refute has_element?(lv, "#group-panel-polls")
    end
  end

  describe "the list" do
    test "shows open polls and filters by status", ctx do
      open = create_poll!(ctx.owner, ctx.group, %{"question" => "Open?"})
      closed = create_poll!(ctx.owner, ctx.group, %{"question" => "Closed?"})
      {:ok, _closed} = Polls.close_poll(ctx.owner, closed)

      lv = overview(ctx.member_account, ctx.group)
      assert has_element?(lv, "#poll-row-#{open.id}", "Open?")
      refute has_element?(lv, "#poll-row-#{closed.id}")

      lv |> element("#polls-status-closed") |> render_click()
      assert_patch(lv, ~p"/groups/#{ctx.group.id}/polls?status=closed")

      assert has_element?(lv, "#poll-row-#{closed.id}", "Closed?")
      refute has_element?(lv, "#poll-row-#{open.id}")
    end

    test "waiting for my vote leaves out what the viewer has voted in", ctx do
      waiting = create_poll!(ctx.owner, ctx.group, %{"question" => "Waiting?"})
      voted = create_poll!(ctx.owner, ctx.group, %{"question" => "Voted?"})
      vote!(ctx.member, ctx.member_account, voted, 0)

      lv = overview(ctx.member_account, ctx.group, status: "waiting")

      assert has_element?(lv, "#poll-row-#{waiting.id}")
      refute has_element?(lv, "#poll-row-#{voted.id}")
    end

    test "the switch brings in sub-groups of the viewer", ctx do
      sub = group_with_members!(ctx.owner, [ctx.member], %{"name" => "pt-sub", parent: ctx.group})
      poll = create_poll!(ctx.owner, sub, %{"question" => "In the sub-group?"})
      create_poll!(ctx.owner, ctx.group)

      lv = overview(ctx.member_account, ctx.group)
      refute has_element?(lv, "#poll-row-#{poll.id}")

      lv |> element("#polls-subgroups-toggle") |> render_click()

      assert has_element?(lv, "#poll-row-#{poll.id}", "pt-sub")
    end

    test "a new poll joins the list live", ctx do
      lv = overview(ctx.member_account, ctx.group)

      poll = create_poll!(ctx.owner, ctx.group)
      render(lv)

      assert has_element?(lv, "#poll-row-#{poll.id}")
    end

    test "new polls start from here too", ctx do
      lv = overview(ctx.member_account, ctx.group)

      lv |> element("#polls-new") |> render_click()

      assert has_element?(lv, "#poll-form-dialog")
    end
  end

  describe "the detail" do
    test "opens the poll beside the list, where it can be voted in", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      lv = overview(ctx.member_account, ctx.group)

      lv |> element("#poll-row-#{poll.id}") |> render_click()
      assert_patch(lv, ~p"/groups/#{ctx.group.id}/polls?poll=#{poll.id}")

      lv |> element("#poll-detail-card-vote-#{hd(option_ids(poll))}") |> render_click()

      assert %{voters_count: 1} = Polls.get_poll(poll.id)
      assert has_element?(lv, "#poll-detail-card-changing.hidden")
    end

    test "holds no details for a member without the right", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      vote!(ctx.owner, ctx.owner_account, poll, 0)

      lv = overview(ctx.member_account, ctx.group, poll: poll.id)

      assert has_element?(lv, "#poll-detail")
      refute has_element?(lv, "#poll-stats")
      refute has_element?(lv, "#poll-close")
      refute has_element?(lv, "#poll-export-voters")
    end

    test "shows the organizer who voted for what and who has not", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      [a, _b] = option_ids(poll)
      vote!(ctx.member, ctx.member_account, poll, 0)

      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      assert has_element?(lv, "#poll-stats-turnout", "of 2 who may vote")
      assert has_element?(lv, "#poll-stats-answer-#{a}", "pt-member")
      assert has_element?(lv, "#poll-stats-not-voted", "pt-owner")
      assert has_element?(lv, "#poll-stats-role-everyone")
    end

    test "gives a role on the list its details", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"details_role_keys" => ["everyone"]})

      lv = overview(ctx.member_account, ctx.group, poll: poll.id)

      assert has_element?(lv, "#poll-stats")
      refute has_element?(lv, "#poll-close")
    end

    test "of a secret poll stops at who took part", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})
      vote!(ctx.member, ctx.member_account, poll, 0)

      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      assert has_element?(lv, "#poll-stats-took-part", "pt-member")
      refute has_element?(lv, "#poll-stats-answers")
      refute has_element?(lv, "#poll-export-results")
    end

    test "the organizer ends and reopens a poll", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      lv |> element("#poll-close") |> render_click()
      assert %{closed_at: %DateTime{}} = Polls.get_poll(poll.id)
      assert has_element?(lv, "#poll-reopen")

      lv |> element("#poll-reopen") |> render_click()
      assert %{closed_at: nil} = Polls.get_poll(poll.id)
    end

    test "a secret poll offers no reopening", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})
      {:ok, _closed} = Polls.close_poll(ctx.owner, poll)

      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      refute has_element?(lv, "#poll-reopen")
    end

    test "deleting leaves the list", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      lv |> element("#poll-delete") |> render_click()

      assert_patch(lv, ~p"/groups/#{ctx.group.id}/polls")
      assert Polls.get_poll(poll.id) == nil
      refute has_element?(lv, "#poll-row-#{poll.id}")
    end

    test "the reminder by hand reaches those who have not voted, once an hour", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      assert lv |> element("#poll-nudge") |> render_click() =~ "The reminder is on its way."
      assert lv |> element("#poll-nudge") |> render_click() =~ "less than an hour ago"
    end

    test "those who manage it clear out answers nobody chose", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"allow_member_options" => "true"})
      {:ok, _poll} = Polls.add_option(ctx.member, poll, %{"text" => "Lake"})
      vote!(ctx.member, ctx.member_account, poll, 0)
      [sea, _mountains, lake] = option_ids(poll)

      lv = overview(ctx.owner_account, ctx.group, poll: poll.id)

      refute has_element?(lv, "#poll-remove-option-#{sea}")
      lv |> element("#poll-remove-option-#{lake}") |> render_click()
      render(lv)

      assert [_sea, _mountains] = option_ids(poll)
      refute has_element?(lv, "#poll-remove-option-#{lake}")

      member_page = overview(ctx.member_account, ctx.group, poll: poll.id)
      refute has_element?(member_page, "#poll-removable-options")
    end

    test "a poll of a group the viewer cannot see does not open", ctx do
      {other_account, _other} = account_with_profile!("pt-other")
      own = group_with_members!(ctx.owner, [])
      poll = create_poll!(ctx.owner, own)

      {:ok, root_page, _html} =
        live_as(
          other_account,
          ~p"/groups/#{Social.get_root_group!().id}/polls?#{[poll: poll.id]}"
        )

      refute has_element?(root_page, "#poll-detail")
    end
  end

  describe "the root" do
    test "gathers the viewer's groups and public polls", ctx do
      {_stranger_account, stranger} = account_with_profile!("pt-stranger")
      public = group_with_members!(stranger, [], %{"is_public" => true})
      elsewhere = create_poll!(stranger, public, %{"is_public" => "true", "question" => "Far?"})
      mine = create_poll!(ctx.owner, ctx.group, %{"question" => "Mine?"})
      hidden = create_poll!(stranger, public, %{"question" => "Hidden?"})

      lv = overview(ctx.member_account, Social.get_root_group!())

      assert has_element?(lv, "#poll-row-#{mine.id}", ctx.group.name)
      assert has_element?(lv, "#poll-row-#{elsewhere.id}")
      refute has_element?(lv, "#poll-row-#{hidden.id}")

      lv |> element("#polls-public-toggle") |> render_click()
      refute has_element?(lv, "#poll-row-#{elsewhere.id}")
      assert_push_event(lv, "polls_filters", %{groups: true, public: false})

      lv |> element("#polls-groups-toggle") |> render_click()
      refute has_element?(lv, "#poll-row-#{mine.id}")
    end

    test "has no button for a new poll", ctx do
      lv = overview(ctx.member_account, Social.get_root_group!())

      refute has_element?(lv, "#polls-new")
    end

    test "a poll opens with a link to its group", ctx do
      poll = create_poll!(ctx.owner, ctx.group)

      lv = overview(ctx.member_account, Social.get_root_group!(), poll: poll.id)

      assert has_element?(lv, "#poll-detail-group", ctx.group.name)
    end
  end

  describe "someone outside" do
    setup ctx do
      public = group_with_members!(ctx.owner, [], %{"is_public" => true})
      {visitor_account, visitor} = account_with_profile!("pt-visitor")
      %{public: public, visitor_account: visitor_account, visitor: visitor}
    end

    test "has the overview of a public group with a public poll", ctx do
      poll = create_poll!(ctx.owner, ctx.public, %{"is_public" => "true"})
      other = create_poll!(ctx.owner, ctx.public, %{"question" => "Members?"})

      lv = overview(ctx.visitor_account, ctx.public)

      assert has_element?(lv, "#group-polls-summary")
      assert has_element?(lv, "#poll-row-#{poll.id}")
      refute has_element?(lv, "#poll-row-#{other.id}")
    end

    test "has none without one", ctx do
      create_poll!(ctx.owner, ctx.public)

      lv = overview(ctx.visitor_account, ctx.public)

      refute has_element?(lv, "#group-panel-polls")
      refute has_element?(lv, "#group-polls-summary")
    end

    test "votes from the detail", ctx do
      poll = create_poll!(ctx.owner, ctx.public, %{"is_public" => "true"})

      lv = overview(ctx.visitor_account, ctx.public, poll: poll.id)
      lv |> element("#poll-detail-card-vote-#{hd(option_ids(poll))}") |> render_click()

      assert %{voters_count: 1} = Polls.get_poll(poll.id)
    end

    test "does not open a poll for members by its address", ctx do
      create_poll!(ctx.owner, ctx.public, %{"is_public" => "true"})
      hidden = create_poll!(ctx.owner, ctx.public, %{"question" => "Members?"})

      lv = overview(ctx.visitor_account, ctx.public, poll: hidden.id)

      refute has_element?(lv, "#poll-detail")
    end
  end
end
