defmodule PotokIdeWeb.GroupLive.PollsTest do
  @moduledoc """
  A poll in the chat: what its card shows each viewer, voting from it, and that
  every path of a message onto the page brings the viewer's own view.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Social

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("pc-owner")
    {member_account, member} = account_with_profile!("pc-member")
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

  defp chat(account, group) do
    {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}/values")
    lv
  end

  defp announced!(owner, group, attrs \\ %{}) do
    {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(attrs), @zone)
    Polls.get_poll(poll.id)
  end

  defp card(poll), do: "#value-poll-card-#{poll.value_id}"

  defp tally_style(lv), do: lv |> element("#group-poll-tally-style") |> render()

  defp vote_button(poll, index \\ 0) do
    "#value-poll-card-#{poll.value_id}-vote-#{Enum.at(option_ids(poll), index)}"
  end

  describe "the card" do
    test "stands in for the message's text", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.member_account, ctx.group)

      assert has_element?(lv, card(poll), "Where do we go?")
      refute has_element?(lv, "#value-#{poll.value_id} .rich-content")
    end

    test "cannot be edited as a message", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.owner_account, ctx.group)

      refute has_element?(lv, "#value-edit-#{poll.value_id}")
      assert has_element?(lv, "#value-delete-#{poll.value_id}")
    end

    test "says who sees the votes", ctx do
      poll = announced!(ctx.owner, ctx.group)
      secret = announced!(ctx.owner, ctx.group, %{"secret" => "true", "question" => "Secret?"})
      lv = chat(ctx.member_account, ctx.group)

      assert has_element?(lv, card(poll), "organizer and those who manage polls")
      assert has_element?(lv, card(secret), "Neither the group's admins nor the app")
    end

    test "leads to the poll's place in the overview", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.member_account, ctx.group)

      lv |> element("#value-poll-card-#{poll.value_id}-details") |> render_click()

      assert_patch(lv, ~p"/groups/#{ctx.group.id}/polls?poll=#{poll.id}")
      assert has_element?(lv, "#poll-detail", "Where do we go?")
    end

    test "says what the viewer's role stops", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"voter_role_keys" => ["admin"]})
      lv = chat(ctx.member_account, ctx.group)

      refute has_element?(lv, vote_button(poll))
      assert has_element?(lv, card(poll), "Only these vote: Admin.")
    end

    test "follows a role that was deleted", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "board"})
      poll = announced!(ctx.owner, ctx.group, %{"voter_role_keys" => [role.key]})

      {:ok, _deleted} = Social.delete_group_role(ctx.owner, ctx.group, role.key)

      lv = chat(ctx.member_account, ctx.group)
      assert has_element?(lv, card(poll), "Nobody can vote any more.")
    end
  end

  describe "voting from the chat" do
    test "one tap gives a vote and shows the bars", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.member_account, ctx.group)
      [a, _b] = option_ids(poll)

      lv |> element(vote_button(poll)) |> render_click()

      assert has_element?(lv, "#{card(poll)}-shown .poll-bar-#{a}")
      # The form stays for a change of vote, out of sight.
      assert has_element?(lv, "#{card(poll)}-changing.hidden #{vote_button(poll)}")
      assert tally_style(lv) =~ ~s(.poll-count-#{a}::after{content:"1 · 100%"})
      assert %{voters_count: 1} = Polls.get_poll(poll.id)
    end

    test "a vote that can change stays open for a change", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.member_account, ctx.group)

      lv |> element(vote_button(poll)) |> render_click()

      assert has_element?(lv, "#value-poll-card-#{poll.value_id}-change")
      lv |> element(vote_button(poll, 1)) |> render_click()

      assert [0, 1] =
               poll.id |> Polls.get_poll() |> Map.fetch!(:options) |> Enum.map(& &1.votes_count)
    end

    test "a final vote asks for a press of the button", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"allow_change" => "false"})
      lv = chat(ctx.member_account, ctx.group)
      [a, _b] = option_ids(poll)

      refute has_element?(lv, vote_button(poll))
      assert has_element?(lv, "#value-poll-card-#{poll.value_id}-ballot input[type=radio]")

      lv
      |> element("#value-poll-card-#{poll.value_id}-ballot")
      |> render_submit(%{"poll" => poll.id, "option_ids" => [a]})

      refute has_element?(lv, "#value-poll-card-#{poll.value_id}-ballot")
      refute has_element?(lv, "#value-poll-card-#{poll.value_id}-change")
    end

    test "several answers go by checkboxes", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"kind" => "multiple"})
      lv = chat(ctx.member_account, ctx.group)
      [a, b] = option_ids(poll)

      assert has_element?(lv, "#value-poll-card-#{poll.value_id}-ballot input[type=checkbox]")

      lv
      |> element("#value-poll-card-#{poll.value_id}-ballot")
      |> render_submit(%{"poll" => poll.id, "option_ids" => [a, b]})

      assert tally_style(lv) =~ ~s(.poll-count-#{a}::after{content:"1 · 100%"})
      assert tally_style(lv) =~ ~s(.poll-count-#{b}::after{content:"1 · 100%"})
    end

    test "without a choice nothing happens", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"allow_change" => "false"})
      lv = chat(ctx.member_account, ctx.group)

      lv
      |> element("#value-poll-card-#{poll.value_id}-ballot")
      |> render_submit(%{"poll" => poll.id})

      assert %{voters_count: 0} = Polls.get_poll(poll.id)
    end

    test "another's vote moves the numbers for one who sees them", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"results_when" => "always"})
      lv = chat(ctx.owner_account, ctx.group)
      [a, _b] = option_ids(poll)

      vote!(ctx.member, ctx.member_account, poll, 0)

      assert tally_style(lv) =~ ~s(.poll-voters-#{poll.id}::after{content:"1"})
      assert tally_style(lv) =~ ~s(.poll-count-#{a}::after{content:"1 · 100%"})
    end

    test "another's vote moves only how many voted for one who may not see the rest", ctx do
      poll = announced!(ctx.owner, ctx.group)
      lv = chat(ctx.member_account, ctx.group)
      [a, _b] = option_ids(poll)

      vote!(ctx.owner, ctx.owner_account, poll, 0)

      assert tally_style(lv) =~ ~s(.poll-voters-#{poll.id}::after{content:"1"})
      refute tally_style(lv) =~ "poll-count-#{a}"
    end

    test "a vote reaches the viewer's other tab", ctx do
      poll = announced!(ctx.owner, ctx.group)
      other_tab = chat(ctx.member_account, ctx.group)

      vote!(ctx.member, ctx.member_account, poll, 0)
      render(other_tab)

      assert has_element?(other_tab, "#{card(poll)}-changing.hidden #{vote_button(poll)}")
      assert has_element?(other_tab, "#{card(poll)}-shown [class*='poll-bar-']")
    end

    test "ending the poll shows its results to everyone", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"results_when" => "closed"})
      lv = chat(ctx.member_account, ctx.group)
      [a, _b] = option_ids(poll)

      vote!(ctx.member, ctx.member_account, poll, 0)
      refute tally_style(lv) =~ "poll-count-#{a}"

      {:ok, _closed} = Polls.close_poll(ctx.owner, poll)
      render(lv)

      assert has_element?(lv, card(poll), "Voting ended")
      assert tally_style(lv) =~ "poll-count-#{a}"
    end

    test "a decision shows on the card", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"majority" => "plurality"})
      lv = chat(ctx.member_account, ctx.group)

      vote!(ctx.member, ctx.member_account, poll, 0)
      {:ok, _closed} = Polls.close_poll(ctx.owner, poll)
      render(lv)

      assert has_element?(lv, card(poll), "Decided: Sea")
    end
  end

  describe "a secret poll" do
    test "keeps the numbers off the page until the end, for everyone", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"secret" => "true"})
      [a, _b] = option_ids(poll)

      owner_page = chat(ctx.owner_account, ctx.group)
      vote!(ctx.member, ctx.member_account, poll, 0)

      refute render(owner_page) =~ "poll-count-#{a}::after"
      assert tally_style(owner_page) =~ ~s(.poll-voters-#{poll.id}::after{content:"1"})

      member_page = chat(ctx.member_account, ctx.group)
      refute render(member_page) =~ "poll-count-#{a}::after"
      assert has_element?(member_page, card(poll), "Your vote is recorded.")
    end

    test "offers no change of a vote", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"secret" => "true"})
      vote!(ctx.member, ctx.member_account, poll, 0)

      lv = chat(ctx.member_account, ctx.group)

      refute has_element?(lv, "#value-poll-card-#{poll.value_id}-change")
      refute has_element?(lv, "#value-poll-card-#{poll.value_id}-ballot")
    end
  end

  describe "every way a message reaches the page" do
    test "a poll posted while the page is open comes with the viewer's view", ctx do
      lv = chat(ctx.member_account, ctx.group)

      poll = announced!(ctx.owner, ctx.group)
      render(lv)

      assert has_element?(lv, vote_button(poll))
    end

    test "the poster's own page gets its own view", ctx do
      lv = chat(ctx.owner_account, ctx.group)

      poll = announced!(ctx.owner, ctx.group)
      render(lv)

      assert has_element?(lv, vote_button(poll))
      assert has_element?(lv, card(poll), "organizer")
    end

    test "a message sent again keeps each viewer's view", ctx do
      poll = announced!(ctx.owner, ctx.group)
      voter = chat(ctx.member_account, ctx.group)
      other = chat(ctx.owner_account, ctx.group)
      [a, _b] = option_ids(poll)

      vote!(ctx.member, ctx.member_account, poll, 0)
      render(voter)

      {:ok, _reaction} =
        Social.toggle_value_reaction(
          ctx.owner,
          ctx.group,
          Social.get_value_for_display(poll.value_id),
          "👍"
        )

      render(voter)
      render(other)

      assert has_element?(voter, "#{card(poll)} .poll-bar-#{a}")
      refute has_element?(other, "#{card(poll)} .poll-bar-#{a}")
      assert has_element?(other, vote_button(poll))
    end

    test "a poll in older messages comes with its view", ctx do
      poll = announced!(ctx.owner, ctx.group)

      for index <- 1..25,
          do: Social.create_value(ctx.owner, ctx.group, %{"content" => "m#{index}"})

      lv = chat(ctx.member_account, ctx.group)
      refute has_element?(lv, card(poll))

      lv |> element("#group-values-load-more") |> render_click()

      assert has_element?(lv, vote_button(poll))
    end

    test "a jump to the message comes with its view", ctx do
      poll = announced!(ctx.owner, ctx.group)

      for index <- 1..25,
          do: Social.create_value(ctx.owner, ctx.group, %{"content" => "m#{index}"})

      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values?#{[value: poll.value_id]}")

      assert has_element?(lv, vote_button(poll))
    end

    test "a change of profile gets that profile's view", ctx do
      poll = announced!(ctx.owner, ctx.group)
      vote!(ctx.member, ctx.member_account, poll, 0)

      {:ok, second} =
        Social.create_profile_for_account(ctx.member_account, %{
          username: "pc-second",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      add_member!(ctx.owner, ctx.group, second)

      lv = chat(ctx.member_account, ctx.group)
      assert has_element?(lv, "#value-poll-card-#{poll.value_id}-change")

      {:ok, _account} = PotokIde.Accounts.set_current_profile(ctx.member_account, second)
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      refute has_element?(lv, "#value-poll-card-#{poll.value_id}-change")
      assert has_element?(lv, card(poll), "Another profile of yours has already voted.")
    end
  end

  describe "someone outside, in an open chat" do
    setup ctx do
      group =
        group_with_members!(ctx.owner, [ctx.member], %{
          "is_public" => true,
          "has_public_chat" => true
        })

      {visitor_account, visitor} = account_with_profile!("pc-visitor")
      %{open_group: group, visitor_account: visitor_account, visitor: visitor}
    end

    test "sees the question of a poll for members and no more", ctx do
      poll = announced!(ctx.owner, ctx.open_group)
      vote!(ctx.member, ctx.member_account, poll, 0)
      [a, _b] = option_ids(poll)

      lv = chat(ctx.visitor_account, ctx.open_group)

      assert has_element?(lv, card(poll), "Where do we go?")
      assert has_element?(lv, card(poll), "Members of the group vote here.")
      refute has_element?(lv, vote_button(poll))
      refute render(lv) =~ "Mountains"
      refute render(lv) =~ "poll-voters-#{poll.id}"
      refute render(lv) =~ "poll-count-#{a}"
    end

    test "votes in a public poll", ctx do
      poll = announced!(ctx.owner, ctx.open_group, %{"is_public" => "true"})
      lv = chat(ctx.visitor_account, ctx.open_group)

      lv |> element(vote_button(poll)) |> render_click()

      assert %{voters_count: 1} = Polls.get_poll(poll.id)
    end

    test "is told a public poll is no count of people", ctx do
      poll = announced!(ctx.owner, ctx.open_group, %{"is_public" => "true"})
      lv = chat(ctx.visitor_account, ctx.open_group)

      assert has_element?(lv, card(poll), "a mood, not a count of people")
    end

    test "has no way to start a poll", ctx do
      lv = chat(ctx.visitor_account, ctx.open_group)

      refute has_element?(lv, "#group-value-poll")
    end
  end

  describe "answers from members" do
    test "join the card", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"allow_member_options" => "true"})
      lv = chat(ctx.member_account, ctx.group)

      lv
      |> element("#value-poll-card-#{poll.value_id}-add-option")
      |> render_submit(%{"poll" => poll.id, "text" => "Lake"})

      assert has_element?(lv, card(poll), "Lake")
    end

    test "are refused twice", ctx do
      poll = announced!(ctx.owner, ctx.group, %{"allow_member_options" => "true"})
      lv = chat(ctx.member_account, ctx.group)

      html =
        lv
        |> element("#value-poll-card-#{poll.value_id}-add-option")
        |> render_submit(%{"poll" => poll.id, "text" => "sea"})

      assert html =~ "That answer is already there."
    end
  end
end
