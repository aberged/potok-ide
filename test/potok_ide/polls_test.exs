defmodule PotokIde.PollsTest do
  use PotokIde.DataCase

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Polls
  alias PotokIde.Polls.{Deadlines, Poll, PollBallot}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Value

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("p#{System.unique_integer([:positive])}")
    {member_account, member} = account_with_profile!("p#{System.unique_integer([:positive])}")
    {outsider_account, outsider} = account_with_profile!("p#{System.unique_integer([:positive])}")
    group = group_with_members!(owner, [member])

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      outsider: outsider,
      outsider_account: outsider_account,
      group: group
    }
  end

  defp public_group(owner, members \\ []) do
    group_with_members!(owner, members, %{"is_public" => true})
  end

  defp owner_account_id(profile) do
    Repo.one!(
      from(ap in PotokIde.Social.AccountProfile,
        where: ap.profile_id == ^profile.id,
        select: ap.account_id
      )
    )
  end

  defp ballots(poll), do: Repo.all(from(b in PollBallot, where: b.poll_id == ^poll.id))

  defp counts(poll),
    do: poll.id |> Polls.get_poll() |> Map.fetch!(:options) |> Enum.map(& &1.votes_count)

  describe "create_poll/5" do
    test "keeps the answers in order and starts with no votes", %{owner: owner, group: group} do
      poll = create_poll!(owner, group)

      assert poll.group_id == group.id
      assert poll.creator_id == owner.id
      assert Enum.map(poll.options, & &1.text) == ["Sea", "Mountains"]
      assert Enum.map(poll.options, & &1.position) == [0, 1]
      assert poll.voters_count == 0
    end

    test "starts open to every member, with the results after voting", %{
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)

      assert poll.voter_role_keys == ["everyone"]
      assert poll.results_role_keys == ["everyone"]
      assert poll.details_role_keys == []
      assert poll.results_when == :voted
      assert poll.allow_change
      refute poll.secret
    end

    test "needs the permission", %{member: member, outsider: outsider, owner: owner, group: group} do
      assert {:error, :not_permitted} = Polls.create_poll(outsider, group, poll_attrs(), @zone)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, "everyone", :create_polls, :neutral)

      assert {:error, :not_permitted} = Polls.create_poll(member, group, poll_attrs(), @zone)
    end

    test "is not for the root or direct conversations", %{owner: owner} do
      root = Social.get_root_group!()
      assert {:error, :not_permitted} = Polls.create_poll(owner, root, poll_attrs(), @zone)
    end

    test "needs at least two different answers, at most ten", %{owner: owner, group: group} do
      one = poll_attrs(%{"options" => %{"0" => %{"text" => "Sea"}}})
      assert {:error, changeset} = Polls.create_poll(owner, group, one, @zone)
      assert %{options: [_error]} = errors_on(changeset)

      twice =
        poll_attrs(%{"options" => %{"0" => %{"text" => "Sea"}, "1" => %{"text" => " sea "}}})

      assert {:error, changeset} = Polls.create_poll(owner, group, twice, @zone)
      assert "has the same answer twice" in errors_on(changeset).options

      many = Map.new(0..10, &{Integer.to_string(&1), %{"text" => "Answer #{&1}"}})

      assert {:error, changeset} =
               Polls.create_poll(owner, group, poll_attrs(%{"options" => many}), @zone)

      assert %{options: [_error]} = errors_on(changeset)
    end

    test "drops a row the form deleted", %{owner: owner, group: group} do
      attrs =
        poll_attrs(%{
          "options" => %{
            "0" => %{"text" => "Sea"},
            "1" => %{"text" => ""},
            "2" => %{"text" => "Mountains"}
          },
          "options_drop" => ["", "1"]
        })

      assert {:ok, poll} = Polls.create_poll(owner, group, attrs, @zone)
      assert ["Sea", "Mountains"] = poll.options |> Enum.map(& &1.text)
    end

    test "counts a question as the database does", %{owner: owner, group: group} do
      flags = String.duplicate("🇷🇸", 151)

      assert {:error, changeset} =
               Polls.create_poll(owner, group, poll_attrs(%{"question" => flags}), @zone)

      assert %{question: [_too_long]} = errors_on(changeset)
    end

    test "needs a deadline to come", %{owner: owner, group: group} do
      past = poll_attrs(%{"closes_local" => local_in(-2)})

      assert {:error, changeset} = Polls.create_poll(owner, group, past, @zone)
      assert "must be in the future" in errors_on(changeset).closes_local
    end

    test "reads the deadline in the viewer's zone and sets the reminder", %{
      owner: owner,
      group: group
    } do
      poll =
        create_poll!(owner, group, %{"closes_local" => local_in(48), "reminder_minutes" => "60"})

      assert DateTime.diff(poll.closes_at, DateTime.utc_now(), :hour) in 47..48
      assert DateTime.diff(poll.closes_at, poll.remind_at, :minute) == 60
    end

    test "a secret poll cannot promise less", %{owner: owner, group: group} do
      poll =
        create_poll!(owner, group, %{
          "secret" => "true",
          "allow_change" => "true",
          "results_when" => "always",
          "allow_member_options" => "true"
        })

      assert poll.secret
      refute poll.allow_change
      assert poll.results_when == :closed
      refute poll.allow_member_options
    end

    test "the database holds a secret poll to that too", %{owner: owner, group: group} do
      poll = create_poll!(owner, group, %{"secret" => "true"})

      assert_raise Postgrex.Error, ~r/polls_secret_check/, fn ->
        Repo.update_all(from(p in Poll, where: p.id == ^poll.id), set: [allow_change: true])
      end
    end

    test "several answers take no quorum or decision", %{owner: owner, group: group} do
      poll =
        create_poll!(owner, group, %{
          "kind" => "multiple",
          "max_choices" => "2",
          "quorum_percent" => "50",
          "majority" => "simple"
        })

      assert poll.max_choices == 2
      assert poll.quorum_percent == nil
      assert poll.majority == :none
    end

    test "a quorum needs a decision", %{owner: owner, group: group} do
      poll = create_poll!(owner, group, %{"quorum_percent" => "50"})
      assert poll.quorum_percent == nil

      decided = create_poll!(owner, group, %{"quorum_percent" => "50", "majority" => "simple"})
      assert decided.quorum_percent == 50
    end

    test "only `publish_polls` opens a poll to non-members", %{owner: owner, member: member} do
      group = public_group(owner, [member])

      assert create_poll!(owner, group, %{"is_public" => "true"}).is_public

      {:ok, poll} = Polls.create_poll(member, group, poll_attrs(%{"is_public" => "true"}), @zone)
      refute poll.is_public
    end

    test "a public poll is for everyone and decides nothing", %{owner: owner} do
      group = public_group(owner)

      poll =
        create_poll!(owner, group, %{
          "is_public" => "true",
          "voter_role_keys" => ["admin"],
          "allow_member_options" => "true",
          "quorum_percent" => "50",
          "majority" => "simple"
        })

      assert poll.voter_role_keys == ["everyone"]
      refute poll.allow_member_options
      assert poll.quorum_percent == nil
      assert poll.majority == :none
    end

    test "announces in the chat and pushes to the other members", context do
      %{owner: owner, group: group, member_account: member_account, owner_account: owner_account} =
        context

      capture_push_requests!()
      endpoint = push_device!(member_account)
      _own = push_device!(owner_account)

      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)

      value = Repo.get!(Value, poll.value_id)
      assert value.content =~ "Where do we go?"
      assert value.group_id == group.id
      assert pushed_endpoints() == [endpoint]
    end

    test "without `post_values` it stays out of the chat", %{
      owner: owner,
      member: member,
      group: group
    } do
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, "everyone", :post_values, :neutral)

      {:ok, poll} = Polls.create_poll(member, group, poll_attrs(), @zone)

      assert poll.value_id == nil
    end

    test "escapes markdown in the message's text", %{owner: owner, group: group} do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(%{"question" => "*now*?"}), @zone)

      assert Repo.get!(Value, poll.value_id).content =~ "\\*now\\*?"
    end
  end

  describe "vote/4" do
    test "records a ballot and counts it", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)

      assert %Poll{voters_count: 1} = vote!(member, account, poll, 0)

      assert [%PollBallot{} = ballot] = ballots(poll)
      assert ballot.profile_id == member.id
      assert ballot.account_id == account.id
      assert ballot.option_ids == [hd(option_ids(poll))]
      assert counts(poll) == [1, 0]
    end

    test "a new vote takes the place of the old one", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)

      vote!(member, account, poll, 0)
      assert %Poll{voters_count: 1} = vote!(member, account, poll, 1)

      assert [%PollBallot{changed_at: %DateTime{}}] = ballots(poll)
      assert counts(poll) == [0, 1]
    end

    test "the same vote again changes nothing", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)

      vote!(member, account, poll, 0)
      vote!(member, account, poll, 0)

      assert [%PollBallot{changed_at: nil}] = ballots(poll)
      assert counts(poll) == [1, 0]
    end

    test "cannot change where the poll says so", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"allow_change" => "false"})

      vote!(member, account, poll, 0)

      assert {:error, :already_voted} =
               Polls.vote(member, account, poll, [List.last(option_ids(poll))])

      assert counts(poll) == [1, 0]
    end

    test "takes one answer of a single choice", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)

      assert {:error, :invalid_choice} = Polls.vote(member, account, poll, option_ids(poll))
      assert {:error, :invalid_choice} = Polls.vote(member, account, poll, [])
    end

    test "takes up to the limit of several answers", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      options = %{"0" => %{"text" => "A"}, "1" => %{"text" => "B"}, "2" => %{"text" => "C"}}

      poll =
        create_poll!(owner, group, %{
          "kind" => "multiple",
          "max_choices" => "2",
          "options" => options
        })

      [a, b, c] = option_ids(poll)

      assert {:error, :invalid_choice} = Polls.vote(member, account, poll, [a, b, c])
      assert {:ok, %Poll{voters_count: 1}} = Polls.vote(member, account, poll, [a, b])
      assert counts(poll) == [1, 1, 0]

      assert {:ok, %Poll{voters_count: 1}} = Polls.vote(member, account, poll, [b, c])
      assert counts(poll) == [0, 1, 1]
    end

    test "counts an answer once", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)
      [a, _b] = option_ids(poll)

      assert {:ok, _poll} = Polls.vote(member, account, poll, [a, a])
      assert counts(poll) == [1, 0]
    end

    test "refuses an answer of another poll", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)
      other = create_poll!(owner, group, %{"question" => "Other?"})

      assert {:error, :invalid_choice} =
               Polls.vote(member, account, poll, [hd(option_ids(other))])
    end

    test "refuses after the end", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)
      {:ok, poll} = Polls.close_poll(owner, poll)

      assert {:error, :closed} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
    end

    test "refuses past the deadline before anything closed it", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"closes_local" => local_in(1)})

      Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
        set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
      )

      assert {:error, :closed} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
    end

    test "refuses a member without a role on the list", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"voter_role_keys" => ["admin"]})

      assert {:error, :role} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
    end

    test "refuses someone outside of a poll for members", %{
      outsider: outsider,
      outsider_account: account,
      owner: owner
    } do
      poll = create_poll!(owner, public_group(owner))

      assert {:error, :members_only} = Polls.vote(outsider, account, poll, [hd(option_ids(poll))])
    end

    test "takes someone outside of a public poll, unless blocked", %{
      outsider: outsider,
      outsider_account: account,
      owner: owner
    } do
      group = public_group(owner)
      poll = create_poll!(owner, group, %{"is_public" => "true"})

      assert {:ok, _poll} = Polls.vote(outsider, account, poll, [hd(option_ids(poll))])

      other = create_poll!(owner, group, %{"is_public" => "true", "question" => "Other?"})
      {:ok, _block} = Social.block_from_group(owner, group, outsider)

      assert {:error, :blocked} = Polls.vote(outsider, account, other, [hd(option_ids(other))])
    end

    test "holds back someone outside who votes in a loop", %{
      outsider: outsider,
      outsider_account: account,
      owner: owner
    } do
      group = public_group(owner)

      for index <- 1..10 do
        poll = create_poll!(owner, group, %{"is_public" => "true", "question" => "Q #{index}?"})
        assert {:ok, _poll} = Polls.vote(outsider, account, poll, [hd(option_ids(poll))])
      end

      poll = create_poll!(owner, group, %{"is_public" => "true", "question" => "One more?"})
      assert {:error, :rate_limited} = Polls.vote(outsider, account, poll, [hd(option_ids(poll))])
    end

    test "does not hold back a member", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      for index <- 1..11 do
        poll = create_poll!(owner, group, %{"question" => "Q #{index}?"})
        assert {:ok, _poll} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
      end
    end
  end

  describe "one account, one vote" do
    setup %{member_account: account, owner: owner, group: group} do
      {:ok, second} =
        Social.create_profile_for_account(account, %{
          username: "p#{System.unique_integer([:positive])}",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      add_member!(owner, group, second)
      %{second: second, poll: create_poll!(owner, group)}
    end

    test "a second profile of the account cannot vote too", %{
      member: member,
      member_account: account,
      second: second,
      poll: poll
    } do
      vote!(member, account, poll, 0)

      assert {:error, :voted_with_other_profile} =
               Polls.vote(second, account, poll, [hd(option_ids(poll))])

      assert %{voters_count: 1} = Polls.get_poll(poll.id)
    end

    test "a profile several accounts share votes on its own", %{
      member: member,
      member_account: account,
      second: second,
      poll: poll,
      owner_account: owner_account
    } do
      {:ok, shared} = Social.update_profile_for_account(account, second.id, %{sharing: :shared})
      share_profile!(shared, owner_account)

      vote!(member, account, poll, 0)
      assert %{voters_count: 2} = vote!(shared, account, poll, 1)

      assert [_personal, %PollBallot{account_id: nil, profile_id: profile_id}] =
               poll |> ballots() |> Enum.sort_by(& &1.id)

      assert profile_id == shared.id
    end

    test "a shared profile with one account does not get around it", %{
      member: member,
      member_account: account,
      second: second,
      poll: poll
    } do
      {:ok, shared} = Social.update_profile_for_account(account, second.id, %{sharing: :shared})

      vote!(member, account, poll, 0)

      assert {:error, :voted_with_other_profile} =
               Polls.vote(shared, account, poll, [hd(option_ids(poll))])
    end

    test "the view says so to the profile that cannot vote", %{
      member: member,
      member_account: account,
      second: second,
      poll: poll,
      group: group
    } do
      vote!(member, account, poll, 0)

      poll = Polls.get_poll(poll.id)
      access = PotokIde.Social.Access.for_profile(second, group)

      view = Polls.views([poll], second, account, %{group.id => {group, access}})[poll.id]

      assert view.voted_with_other_profile?
      refute view.can_vote?
    end

    test "those with a right to vote are counted as people", %{group: group, poll: poll} do
      # The owner, and the member with their two profiles.
      assert Polls.eligible_count(poll, group) == 2
    end
  end

  describe "a secret poll" do
    test "keeps no link between a voter and an answer", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"secret" => "true"})

      vote!(member, account, poll, 1)

      assert [%PollBallot{option_ids: [], profile_id: profile_id}] = ballots(poll)
      assert profile_id == member.id
      assert counts(poll) == [0, 1]
    end

    test "does not take a second vote", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"secret" => "true"})

      vote!(member, account, poll, 1)

      assert {:error, :already_voted} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
      assert counts(poll) == [0, 1]
    end

    test "tells open pages only how many voted", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"secret" => "true"})
      Polls.subscribe(group.id)

      vote!(member, account, poll, 1)

      assert_receive {:polls, {:tally, %{voters_count: 1, counts: nil}}}
    end

    test "does not tell by a refusal which answers have votes", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      options = %{"0" => %{"text" => "A"}, "1" => %{"text" => "B"}, "2" => %{"text" => "C"}}
      poll = create_poll!(owner, group, %{"secret" => "true", "options" => options})
      vote!(member, account, poll, 0)
      [voted, not_voted, _other] = option_ids(poll)

      assert {:error, :not_permitted} = Polls.delete_option(owner, poll, voted)
      assert {:error, :not_permitted} = Polls.delete_option(owner, poll, not_voted)

      view =
        Polls.view_of(
          Polls.get_poll(poll.id),
          owner,
          Accounts.get_account!(owner_account_id(owner))
        )

      assert view.removable_option_ids == []
    end

    test "stays closed", %{owner: owner, group: group} do
      poll = create_poll!(owner, group, %{"secret" => "true"})
      {:ok, poll} = Polls.close_poll(owner, poll)

      assert {:error, :secret} = Polls.reopen_poll(owner, poll)
    end
  end

  describe "tally messages" do
    test "carry the counts of a poll that is not secret", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)
      Polls.subscribe(group.id)
      [a, b] = option_ids(poll)

      vote!(member, account, poll, 0)

      assert_receive {:polls,
                      {:tally,
                       %{poll_id: poll_id, voters_count: 1, counts: counts, voter_id: voter_id}}}

      assert poll_id == poll.id
      assert voter_id == member.id
      assert counts == %{a => 1, b => 0}
    end
  end

  describe "update_poll/4" do
    test "changes everything before the first vote", %{owner: owner, group: group} do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)

      {:ok, updated} =
        Polls.update_poll(
          owner,
          poll,
          %{"question" => "New?", "details_role_keys" => ["everyone"]},
          @zone
        )

      assert updated.question == "New?"
      assert updated.details_role_keys == ["everyone"]
      assert Repo.get!(Value, poll.value_id).content =~ "New?"
    end

    test "after it keeps what voters saw", %{
      member: member,
      member_account: account,
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group)
      vote!(member, account, poll, 0)

      {:ok, updated} =
        Polls.update_poll(
          owner,
          poll,
          %{
            "question" => "New?",
            "details_role_keys" => ["everyone"],
            "secret" => "true",
            "closes_local" => local_in(24)
          },
          @zone
        )

      assert updated.question == "Where do we go?"
      assert updated.details_role_keys == []
      refute updated.secret
      assert updated.closes_at
    end

    test "is for the organizer and managers", %{member: member, owner: owner, group: group} do
      poll = create_poll!(owner, group)

      assert {:error, :not_permitted} =
               Polls.update_poll(member, poll, %{"question" => "New?"}, @zone)
    end

    test "not after the end", %{owner: owner, group: group} do
      poll = create_poll!(owner, group)
      {:ok, poll} = Polls.close_poll(owner, poll)

      assert {:error, :closed} = Polls.update_poll(owner, poll, %{"question" => "New?"}, @zone)
    end
  end

  describe "closing" do
    test "is for the organizer and managers", %{member: member, owner: owner, group: group} do
      poll = create_poll!(owner, group)

      assert {:error, :not_permitted} = Polls.close_poll(member, poll)
      assert {:ok, %Poll{closed_at: %DateTime{}}} = Polls.close_poll(owner, poll)
    end

    test "works out the decision and writes it down", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, %{"majority" => "simple", "quorum_percent" => "50"})
      [a, _b] = option_ids(poll)

      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      assert {:ok, closed} = Polls.close_poll(owner, poll)
      assert closed.eligible_count == 2
      assert closed.outcome == :passed
      assert closed.winner_option_id == a
    end

    test "without enough voters there is no quorum", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, %{"majority" => "simple", "quorum_percent" => "100"})
      vote!(member, account, poll, 0)

      assert {:ok, %Poll{outcome: :no_quorum, winner_option_id: nil}} =
               Polls.close_poll(owner, poll)
    end

    test "a later change of members leaves the decision", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, %{"majority" => "absolute"})
      vote!(member, account, poll, 0)
      {:ok, closed} = Polls.close_poll(owner, poll)

      {_other_account, other} = account_with_profile!("p#{System.unique_integer([:positive])}")
      add_member!(owner, group, other)

      assert %{eligible_count: 2} = Polls.get_poll(closed.id)
    end

    test "a public poll counts no right to vote", %{owner: owner} do
      group = public_group(owner)
      poll = create_poll!(owner, group, %{"is_public" => "true"})

      assert {:ok, %Poll{eligible_count: nil}} = Polls.close_poll(owner, poll)
    end

    test "reopening forgets the decision and a deadline that passed", %{
      owner: owner,
      group: group
    } do
      poll = create_poll!(owner, group, %{"majority" => "simple", "closes_local" => local_in(1)})

      Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
        set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
      )

      [_closed] = Deadlines.close_due(DateTime.utc_now(:second))

      assert {:ok, reopened} = Polls.reopen_poll(owner, Polls.get_poll(poll.id))
      assert reopened.closed_at == nil
      assert reopened.closes_at == nil
      assert reopened.outcome == nil
      assert reopened.eligible_count == nil
    end
  end

  describe "deadlines" do
    defp past_deadline!(poll, minutes_ago \\ 1) do
      Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
        set: [closes_at: DateTime.add(DateTime.utc_now(:second), -minutes_ago, :minute)]
      )
    end

    test "close a poll at its deadline, once", %{owner: owner, group: group} do
      poll = create_poll!(owner, group, %{"closes_local" => local_in(1)})
      past_deadline!(poll)
      now = DateTime.utc_now(:second)

      assert [%Poll{id: id, closed_at: closed_at}] = Deadlines.close_due(now)
      assert id == poll.id
      assert closed_at == Polls.get_poll(poll.id).closes_at

      assert [] = Deadlines.close_due(now)
    end

    test "leave a poll that is still running", %{owner: owner, group: group} do
      create_poll!(owner, group, %{"closes_local" => local_in(1)})
      create_poll!(owner, group, %{"question" => "No deadline?"})

      assert [] = Deadlines.close_due(DateTime.utc_now(:second))
    end

    test "go on when the organizer has no profile any more", %{
      owner: owner,
      group: group,
      member: member,
      member_account: account
    } do
      capture_push_requests!()
      poll = create_poll!(owner, group, %{"closes_local" => local_in(1)})
      vote!(member, account, poll, 0)
      endpoint = push_device!(account)

      Repo.update_all(from(p in Poll, where: p.id == ^poll.id), set: [creator_id: nil])
      past_deadline!(poll)

      assert [%Poll{}] = Deadlines.close_due(DateTime.utc_now(:second))
      assert pushed_endpoints() == [endpoint]
    end

    test "tell those who voted and the organizer", context do
      %{
        owner: owner,
        owner_account: owner_account,
        member: member,
        member_account: account,
        group: group
      } = context

      capture_push_requests!()
      poll = create_poll!(owner, group, %{"closes_local" => local_in(1)})

      {other_account, other} = account_with_profile!("p#{System.unique_integer([:positive])}")
      add_member!(owner, group, other)
      vote!(member, account, poll, 0)

      voter = push_device!(account)
      organizer = push_device!(owner_account)
      _silent = push_device!(other_account)

      past_deadline!(poll)
      Deadlines.close_due(DateTime.utc_now(:second))

      assert pushed_endpoints() == Enum.sort([voter, organizer])
    end

    test "remind those who may vote and have not, once", context do
      %{
        owner: owner,
        owner_account: owner_account,
        member: member,
        member_account: account,
        group: group
      } = context

      capture_push_requests!()

      {other_account, other} = account_with_profile!("p#{System.unique_integer([:positive])}")
      add_member!(owner, group, other)

      poll =
        create_poll!(owner, group, %{"closes_local" => local_in(5), "reminder_minutes" => "60"})

      vote!(member, account, poll, 0)

      _voter = push_device!(account)
      organizer = push_device!(owner_account)
      late = push_device!(other_account)

      assert Polls.get_poll(poll.id).remind_at

      in_time = DateTime.add(DateTime.utc_now(:second), 5, :hour)
      Deadlines.send_due_reminders(in_time)
      assert pushed_endpoints() == Enum.sort([organizer, late])

      Deadlines.send_due_reminders(in_time)
      assert pushed_endpoints() == []
    end

    test "a reminder skips an account that voted with another profile", context do
      %{owner: owner, member: member, member_account: account, group: group} = context
      capture_push_requests!()

      {:ok, second} =
        Social.create_profile_for_account(account, %{
          username: "p#{System.unique_integer([:positive])}",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      add_member!(owner, group, second)

      poll =
        create_poll!(owner, group, %{"closes_local" => local_in(5), "reminder_minutes" => "60"})

      vote!(member, account, poll, 0)

      _device = push_device!(account)

      Deadlines.send_due_reminders(DateTime.add(DateTime.utc_now(:second), 5, :hour))

      assert pushed_endpoints() == []
    end

    test "a reminder goes only to the roles that vote", context do
      %{owner: owner, owner_account: owner_account, member_account: account, group: group} =
        context

      capture_push_requests!()

      create_poll!(owner, group, %{
        "closes_local" => local_in(5),
        "reminder_minutes" => "60",
        "voter_role_keys" => ["admin"]
      })

      _member = push_device!(account)
      organizer = push_device!(owner_account)

      Deadlines.send_due_reminders(DateTime.add(DateTime.utc_now(:second), 5, :hour))

      assert pushed_endpoints() == [organizer]
    end
  end

  describe "answers from members" do
    setup %{owner: owner, group: group} do
      %{poll: create_poll!(owner, group, %{"allow_member_options" => "true"})}
    end

    test "join the poll in the next place", %{member: member, poll: poll} do
      assert {:ok, _poll} = Polls.add_option(member, poll, %{"text" => "Lake"})

      assert ["Sea", "Mountains", "Lake"] =
               poll.id |> Polls.get_poll() |> Map.fetch!(:options) |> Enum.map(& &1.text)

      added = List.last(Polls.get_poll(poll.id).options)
      assert added.creator_id == member.id
    end

    test "may come after the first vote", %{member: member, member_account: account, poll: poll} do
      vote!(member, account, poll, 0)

      assert {:ok, _poll} = Polls.add_option(member, poll, %{"text" => "Lake"})
    end

    test "refuse the same words", %{member: member, poll: poll} do
      assert {:error, :duplicate} = Polls.add_option(member, poll, %{"text" => " sea "})
    end

    test "are not for polls that do not allow them", %{member: member, owner: owner, group: group} do
      poll = create_poll!(owner, group, %{"question" => "Fixed?"})

      assert {:error, :not_permitted} = Polls.add_option(member, poll, %{"text" => "Lake"})
    end

    test "are not for those who may not vote", %{outsider: outsider, poll: poll} do
      assert {:error, :not_permitted} = Polls.add_option(outsider, poll, %{"text" => "Lake"})
    end

    test "stop at the limit", %{member: member, owner: owner, group: group} do
      options = Map.new(1..10, &{Integer.to_string(&1), %{"text" => "Answer #{&1}"}})
      poll = create_poll!(owner, group, %{"options" => options, "allow_member_options" => "true"})

      for index <- 11..30 do
        assert {:ok, _poll} = Polls.add_option(member, poll, %{"text" => "Answer #{index}"})
      end

      assert {:error, :not_permitted} = Polls.add_option(member, poll, %{"text" => "One more"})
    end

    test "go only while nobody voted for them", %{
      member: member,
      member_account: account,
      owner: owner,
      poll: poll
    } do
      {:ok, _poll} = Polls.add_option(member, poll, %{"text" => "Lake"})
      lake = List.last(option_ids(poll))

      {:ok, _poll} = Polls.vote(member, account, poll, [lake])
      assert {:error, :has_votes} = Polls.delete_option(owner, poll, lake)

      {:ok, _poll} = Polls.vote(member, account, poll, [hd(option_ids(poll))])
      assert {:error, :not_permitted} = Polls.delete_option(member, poll, lake)
      assert {:ok, _poll} = Polls.delete_option(owner, poll, lake)
    end

    test "a poll keeps at least two", %{owner: owner, poll: poll} do
      assert {:error, :too_few_options} = Polls.delete_option(owner, poll, hd(option_ids(poll)))
    end
  end

  describe "deleting" do
    test "a poll takes its message and votes", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)
      vote!(member, account, poll, 0)
      Polls.subscribe(group.id)

      assert {:ok, _poll} = Polls.delete_poll(owner, poll)

      assert Polls.get_poll(poll.id) == nil
      assert Repo.get(Value, poll.value_id) == nil
      assert ballots(poll) == []
      poll_id = poll.id
      assert_receive {:polls, {:deleted, ^poll_id}}
    end

    test "a poll without a message", %{owner: owner, group: group} do
      poll = create_poll!(owner, group)

      assert {:ok, _poll} = Polls.delete_poll(owner, poll)
      assert Polls.get_poll(poll.id) == nil
    end

    test "the message takes the poll", %{owner: owner, group: group} do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)
      Polls.subscribe(group.id)

      assert {:ok, _value} = Social.delete_value(owner, Repo.get!(Value, poll.value_id))

      assert Polls.get_poll(poll.id) == nil
      poll_id = poll.id
      assert_receive {:polls, {:deleted, ^poll_id}}
    end

    test "a poll is for the organizer and managers", %{member: member, owner: owner, group: group} do
      poll = create_poll!(owner, group)

      assert {:error, :not_permitted} = Polls.delete_poll(member, poll)
    end
  end

  describe "the message of a poll" do
    test "cannot be edited", %{owner: owner, group: group} do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)

      assert {:error, :announcement} =
               Social.update_value(owner, Repo.get!(Value, poll.value_id), %{"content" => "Other"})
    end
  end

  describe "overview/4" do
    test "lists the group's polls by status, newest first", %{
      owner: owner,
      owner_account: account,
      group: group
    } do
      open = create_poll!(owner, group, %{"question" => "Open?"})
      newer = create_poll!(owner, group, %{"question" => "Newer?"})
      closed = create_poll!(owner, group, %{"question" => "Closed?"})
      {:ok, _closed} = Polls.close_poll(owner, closed)

      %{rows: rows} = Polls.overview(owner, account, {:groups, [group.id]}, status: :open)
      assert Enum.map(rows, & &1.id) == [newer.id, open.id]

      %{rows: rows} = Polls.overview(owner, account, {:groups, [group.id]}, status: :closed)
      assert Enum.map(rows, & &1.id) == [closed.id]
    end

    test "a poll past its deadline counts as finished before anything closed it", %{
      owner: owner,
      owner_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, %{"closes_local" => local_in(1)})

      Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
        set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
      )

      assert %{rows: []} = Polls.overview(owner, account, {:groups, [group.id]}, status: :open)

      assert %{rows: [_row]} =
               Polls.overview(owner, account, {:groups, [group.id]}, status: :closed)
    end

    test "waiting holds what the viewer can still vote in", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      waiting = create_poll!(owner, group, %{"question" => "Waiting?"})
      voted = create_poll!(owner, group, %{"question" => "Voted?"})

      _other_role =
        create_poll!(owner, group, %{"question" => "Admins?", "voter_role_keys" => ["admin"]})

      vote!(member, account, voted, 0)

      %{rows: rows} = Polls.overview(member, account, {:groups, [group.id]}, status: :waiting)

      assert Enum.map(rows, & &1.id) == [waiting.id]
    end

    test "public_of holds only the public polls of the group", %{
      owner: owner,
      outsider: outsider,
      outsider_account: account
    } do
      group = public_group(owner)
      public = create_poll!(owner, group, %{"is_public" => "true"})
      _members = create_poll!(owner, group, %{"question" => "Members?"})

      %{rows: rows} = Polls.overview(outsider, account, {:public_of, group.id}, status: :open)

      assert Enum.map(rows, & &1.id) == [public.id]
      assert hd(rows).view.can_vote?
    end

    test ":public leaves out a group that stopped being public", %{
      owner: owner,
      outsider: outsider,
      outsider_account: account
    } do
      group = public_group(owner)
      poll = create_poll!(owner, group, %{"is_public" => "true"})

      %{rows: rows} = Polls.overview(outsider, account, :public, status: :open)
      assert poll.id in Enum.map(rows, & &1.id)

      {:ok, _group} = Social.update_group(owner, group, %{"is_public" => false})

      %{rows: rows} = Polls.overview(outsider, account, :public, status: :open)
      refute poll.id in Enum.map(rows, & &1.id)
    end

    test "pages back by id", %{owner: owner, owner_account: account, group: group} do
      polls = for index <- 1..31, do: create_poll!(owner, group, %{"question" => "Q #{index}?"})

      %{rows: rows, more?: true} =
        Polls.overview(owner, account, {:groups, [group.id]}, status: :open)

      assert length(rows) == 30

      %{rows: rest, more?: false} =
        Polls.overview(owner, account, {:groups, [group.id]},
          status: :open,
          before_id: List.last(rows).id
        )

      assert Enum.map(rest, & &1.id) == [hd(polls).id]
    end
  end

  describe "put_views/5" do
    test "costs nothing without a poll and reads a poll afresh", %{
      owner: owner,
      owner_account: account,
      member: member,
      member_account: member_account,
      group: group
    } do
      access = PotokIde.Social.Access.for_profile(owner, group)
      assert Polls.put_views([], group, access, owner, account) == []

      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(), @zone)
      value = Social.get_value_for_display(poll.value_id)
      assert value.poll.voters_count == 0
      assert value.poll_view == nil

      vote!(member, member_account, poll, 0)

      [value] = Polls.put_views([value], group, access, owner, account)
      assert value.poll_view.voters_count == 1
    end
  end

  test "account deletion keeps the vote counted", %{
    owner: owner,
    group: group,
    member: member,
    member_account: account
  } do
    poll = create_poll!(owner, group)
    vote!(member, account, poll, 0)

    Repo.delete!(Accounts.get_account!(account.id))

    assert [%PollBallot{account_id: nil, profile_id: profile_id}] = ballots(poll)
    assert profile_id == member.id
    assert %{voters_count: 1} = Polls.get_poll(poll.id)
  end
end
