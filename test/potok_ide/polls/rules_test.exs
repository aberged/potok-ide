defmodule PotokIde.Polls.RulesTest do
  use ExUnit.Case, async: true

  alias PotokIde.Polls.{Poll, PollBallot, PollOption, Rules}
  alias PotokIde.Social.{Access, Group, GroupManifest, GroupRole, Profile}

  @now ~U[2026-11-07 12:00:00Z]
  @later ~U[2026-11-08 12:00:00Z]
  @earlier ~U[2026-11-06 12:00:00Z]

  @member_permissions [:post_values, :create_polls, :vote_polls]

  defp manifest(everyone_allowed \\ @member_permissions) do
    %GroupManifest{
      roles: [
        %GroupRole{key: "admin", name: "admin", allowed: []},
        %GroupRole{key: "board", name: "board", allowed: []},
        %GroupRole{key: "everyone", name: "everyone", allowed: everyone_allowed}
      ]
    }
  end

  defp group(attrs \\ []), do: struct!(%Group{id: 1, name: "g", is_public: false}, attrs)
  defp public_group, do: group(is_public: true)

  defp profile(id \\ 2), do: %Profile{id: id, username: "p#{id}"}

  defp member(roles \\ [], permissions \\ @member_permissions) do
    %Access{
      member?: true,
      role_keys: ["everyone" | roles],
      permissions: MapSet.new(permissions),
      manifest: manifest()
    }
  end

  defp manager, do: member([], @member_permissions ++ [:manage_polls])
  defp outsider(attrs \\ []), do: struct!(%Access{manifest: manifest()}, attrs)

  defp poll(attrs \\ []) do
    struct!(
      %Poll{
        id: 9,
        group_id: 1,
        creator_id: 1,
        question: "Q?",
        voters_count: 3,
        options: [
          %PollOption{id: 1, text: "A", votes_count: 2},
          %PollOption{id: 2, text: "B", votes_count: 1}
        ]
      },
      attrs
    )
  end

  defp closed(attrs \\ []), do: poll(Keyword.put(attrs, :closed_at, @earlier))

  defp ballot(option_ids \\ [1]), do: %PollBallot{option_ids: option_ids}

  describe "who may start a poll" do
    test "holders of the permission, outside the root and direct conversations" do
      assert Rules.can_create?(member(), group())
      refute Rules.can_create?(member([], []), group())
      refute Rules.can_create?(member(), group(is_root: true))
      refute Rules.can_create?(member(), group(is_direct: true))
    end

    test "threads have polls" do
      assert Rules.can_create?(member(), group(parent_value_id: 5))
    end

    test "only a public group can open a poll to non-members" do
      publisher = member([], [:publish_polls])

      assert Rules.can_publish?(publisher, public_group())
      refute Rules.can_publish?(member(), public_group())
      refute Rules.can_publish?(publisher, group())
      refute Rules.can_publish?(publisher, group(is_public: true, parent_value_id: 5))
      refute Rules.can_publish?(publisher, group(is_public: true, is_direct: true))
    end
  end

  describe "who votes" do
    test "a member with `vote_polls` and a role on the list" do
      assert Rules.vote_block(poll(), group(), member(), profile(), @now) == nil

      poll = poll(voter_role_keys: ["board"])
      assert Rules.vote_block(poll, group(), member(["board"]), profile(), @now) == nil
      assert Rules.vote_block(poll, group(), member(), profile(), @now) == :role
    end

    test "not without `vote_polls`, whatever the list says" do
      assert Rules.vote_block(poll(), group(), member([], []), profile(), @now) == :not_permitted
    end

    test "nobody past the end" do
      assert Rules.vote_block(closed(), group(), member(), profile(), @now) == :closed

      past_deadline = poll(closes_at: @earlier)
      assert Rules.vote_block(past_deadline, group(), member(), profile(), @now) == :closed

      open_until = poll(closes_at: @later)
      assert Rules.vote_block(open_until, group(), member(), profile(), @now) == nil
    end

    test "the deadline itself is too late" do
      assert Rules.vote_block(poll(closes_at: @now), group(), member(), profile(), @now) ==
               :closed
    end

    test "someone outside only in a public poll of a public group" do
      assert Rules.vote_block(poll(), public_group(), outsider(), profile(), @now) ==
               :members_only

      public = poll(is_public: true)
      assert Rules.vote_block(public, public_group(), outsider(), profile(), @now) == nil
      assert Rules.vote_block(public, group(), outsider(), profile(), @now) == :members_only
    end

    test "someone outside not while blocked, or while \"everyone\" may not" do
      public = poll(is_public: true)

      assert Rules.vote_block(public, public_group(), outsider(blocked?: true), profile(), @now) ==
               :blocked

      no_vote = outsider(manifest: manifest([:post_values]))
      assert Rules.vote_block(public, public_group(), no_vote, profile(), @now) == :not_permitted
    end

    test "nobody without a profile" do
      public = poll(is_public: true)
      assert Rules.vote_block(public, public_group(), outsider(), nil, @now) == :not_permitted
    end
  end

  describe "who manages" do
    test "the organizer while a member, and holders of `manage_polls`" do
      assert Rules.manage?(poll(), member(), profile(1))
      refute Rules.manage?(poll(), member(), profile(2))
      assert Rules.manage?(poll(), manager(), profile(2))
    end

    test "not an organizer who left" do
      refute Rules.manage?(poll(), outsider(), profile(1))
    end
  end

  describe "who sees the results" do
    test "by default those who voted, and everyone at the end" do
      refute Rules.results?(poll(), group(), member(), profile(), false, @now)
      assert Rules.results?(poll(), group(), member(), profile(), true, @now)
      assert Rules.results?(closed(), group(), member(), profile(), false, @now)
    end

    test "at any time when chosen" do
      poll = poll(results_when: :always)
      assert Rules.results?(poll, group(), member(), profile(), false, @now)
    end

    test "only at the end when chosen" do
      poll = poll(results_when: :closed)
      refute Rules.results?(poll, group(), member(), profile(), true, @now)

      assert Rules.results?(
               closed(results_when: :closed),
               group(),
               member(),
               profile(),
               true,
               @now
             )
    end

    test "only the roles on the list" do
      closed = closed(results_role_keys: ["board"])

      assert Rules.results?(closed, group(), member(["board"]), profile(), false, @now)
      refute Rules.results?(closed, group(), member(), profile(), false, @now)
    end

    test "with an empty list the organizer and managers alone" do
      closed = closed(results_role_keys: [])

      refute Rules.results?(closed, group(), member(), profile(), true, @now)
      assert Rules.results?(closed, group(), member(), profile(1), true, @now)
      assert Rules.results?(closed, group(), manager(), profile(), true, @now)
    end

    test "the organizer and managers before the end too" do
      poll = poll(results_when: :closed, results_role_keys: [])

      assert Rules.results?(poll, group(), member(), profile(1), false, @now)
      assert Rules.results?(poll, group(), manager(), profile(), false, @now)
    end

    test "those who see the details" do
      poll = poll(results_when: :closed, details_role_keys: ["board"])
      assert Rules.results?(poll, group(), member(["board"]), profile(), false, @now)
    end

    test "someone outside of a public poll, when \"everyone\" is on the list" do
      public = closed(is_public: true)
      assert Rules.results?(public, public_group(), outsider(), profile(), false, @now)

      members_only = closed(is_public: true, results_role_keys: ["board"])
      refute Rules.results?(members_only, public_group(), outsider(), profile(), false, @now)
    end

    test "not someone outside of a poll for members" do
      refute Rules.results?(closed(), public_group(), outsider(), profile(), false, @now)
    end
  end

  describe "who sees the details" do
    test "by default the organizer and managers alone" do
      refute Rules.details?(poll(), member(), profile(), @now)
      assert Rules.details?(poll(), member(), profile(1), @now)
      assert Rules.details?(poll(), manager(), profile(), @now)
    end

    test "the roles on the list, at the chosen time" do
      always = poll(details_role_keys: ["board"])
      assert Rules.details?(always, member(["board"]), profile(), @now)
      refute Rules.details?(always, member(), profile(), @now)

      at_the_end = poll(details_role_keys: ["board"], details_when: :closed)
      refute Rules.details?(at_the_end, member(["board"]), profile(), @now)

      assert Rules.details?(
               closed(details_role_keys: ["board"], details_when: :closed),
               member(["board"]),
               profile(),
               @now
             )
    end

    test "never someone outside, even with \"everyone\" on the list" do
      public = poll(is_public: true, details_role_keys: ["everyone"])
      refute Rules.details?(public, outsider(), profile(), @now)
    end
  end

  describe "a secret poll" do
    defp secret(attrs \\ []) do
      poll(
        [secret: true, allow_change: false, results_when: :closed, details_role_keys: ["board"]] ++
          attrs
      )
    end

    test "shows no counts to anyone before the end" do
      for {access, profile} <- [
            {member(), profile()},
            {member(), profile(1)},
            {manager(), profile()},
            {member(["board"]), profile()}
          ] do
        refute Rules.results?(secret(), group(), access, profile, true, @now)
      end
    end

    test "shows them at the end" do
      closed = secret(closed_at: @earlier)

      assert Rules.results?(closed, group(), member(), profile(), false, @now)
      assert Rules.results?(closed, group(), manager(), profile(), false, @now)
    end

    test "keeps the counts from those who only see who took part" do
      closed = secret(closed_at: @earlier, results_role_keys: [])

      assert Rules.details?(closed, member(["board"]), profile(), @now)
      refute Rules.results?(closed, group(), member(["board"]), profile(), false, @now)
    end
  end

  describe "view/7" do
    test "holds no counts for a viewer who may not see them" do
      view = Rules.view(poll(), group(), member(), profile(), nil, nil, @now)

      assert view.can_vote?
      refute view.results?
      assert Enum.map(view.options, & &1.votes_count) == [nil, nil]
      assert view.voters_count == 3
    end

    test "holds them for one who may" do
      view = Rules.view(poll(), group(), member(), profile(), ballot(), nil, @now)

      assert view.results?
      assert view.voted?
      assert Enum.map(view.options, & &1.votes_count) == [2, 1]
      assert Enum.map(view.options, & &1.mine?) == [true, false]
    end

    test "gives someone outside of a poll for members the question alone" do
      poll = poll(description: "Details")
      view = Rules.view(poll, public_group(), outsider(), profile(), nil, nil, @now)

      assert view.scope == :teaser
      assert view.question == "Q?"
      assert view.description == ""
      assert view.options == []
      assert view.voters_count == nil
      assert view.vote_block == :members_only
      refute view.can_vote?
    end

    test "gives someone outside of a public poll the card" do
      poll = poll(is_public: true)
      view = Rules.view(poll, public_group(), outsider(), profile(), nil, nil, @now)

      assert view.scope == :full
      assert view.public?
      assert view.can_vote?
      assert length(view.options) == 2
    end

    test "a group that stopped being public ends a public poll for those outside" do
      poll = poll(is_public: true)
      view = Rules.view(poll, group(), outsider(), profile(), nil, nil, @now)

      assert view.scope == :teaser
      refute view.public?
      refute view.can_vote?
    end

    test "does not take another vote where it cannot change" do
      poll = poll(allow_change: false)
      view = Rules.view(poll, group(), member(), profile(), ballot(), nil, @now)
      refute view.can_vote?

      changing = Rules.view(poll(), group(), member(), profile(), ballot(), nil, @now)
      assert changing.can_vote?
    end

    test "says when the account voted with another profile" do
      other = %PollBallot{profile_id: 7, option_ids: [1]}
      view = Rules.view(poll(), group(), member(), profile(), nil, other, @now)

      assert view.voted_with_other_profile?
      refute view.can_vote?
      refute view.voted?
    end

    test "gives one tap only to a single choice that can change" do
      assert Rules.view(poll(), group(), member(), profile(), nil, nil, @now).one_tap?

      refute Rules.view(poll(allow_change: false), group(), member(), profile(), nil, nil, @now).one_tap?

      refute Rules.view(poll(kind: :multiple), group(), member(), profile(), nil, nil, @now).one_tap?
    end

    test "the form's key follows the answers and the ballot, not the counts" do
      view = fn poll, ballot ->
        Rules.view(poll, group(), member(), profile(), ballot, nil, @now)
      end

      same = view.(poll(), nil).form_key
      assert view.(poll(voters_count: 9), nil).form_key == same
      refute view.(poll(), ballot()).form_key == same

      other_options = poll(options: [%PollOption{id: 1, text: "A"}])
      refute view.(other_options, nil).form_key == same
    end

    test "a member adds answers only where the poll allows it" do
      allowed = poll(allow_member_options: true)

      assert Rules.view(allowed, group(), member(), profile(), nil, nil, @now).can_add_option?
      refute Rules.view(poll(), group(), member(), profile(), nil, nil, @now).can_add_option?

      refute Rules.view(
               poll(allow_member_options: true, closed_at: @earlier),
               group(),
               member(),
               profile(),
               nil,
               nil,
               @now
             ).can_add_option?
    end

    test "names the roles still there, for the card to say who sees the votes" do
      poll = poll(details_role_keys: ["board", "gone"])
      view = Rules.view(poll, group(), member(), profile(), nil, nil, @now)

      assert Enum.map(view.detail_roles, & &1.key) == ["board"]
    end
  end
end
