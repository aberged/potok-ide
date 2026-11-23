defmodule PotokIde.Polls.EffectsTest do
  use PotokIde.DataCase

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Polls.{Deadlines, Effects, Poll}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupMemberRole, Value}

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("p#{System.unique_integer([:positive])}")
    {member_account, member} = account_with_profile!("p#{System.unique_integer([:positive])}")
    {third_account, third} = account_with_profile!("p#{System.unique_integer([:positive])}")
    group = group_with_members!(owner, [member, third])

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      third: third,
      third_account: third_account,
      group: group
    }
  end

  defp grant_attrs(target, attrs \\ %{}) do
    Map.merge(
      %{
        "question" => "Does #{target.username} become an admin?",
        "effect" => "grant",
        "effect_role_key" => "admin",
        "effect_profile_id" => Integer.to_string(target.id),
        "majority" => "simple",
        "quorum_percent" => "50",
        "closes_local" => local_in(1)
      },
      attrs
    )
  end

  defp elect_attrs(candidates, attrs \\ %{}) do
    Map.merge(
      %{
        "question" => "Who leads?",
        "effect" => "elect",
        "effect_role_key" => "admin",
        "candidate_ids" => Enum.map(candidates, &Integer.to_string(&1.id)),
        "majority" => "plurality",
        "quorum_percent" => "50",
        "closes_local" => local_in(1)
      },
      attrs
    )
  end

  defp past_deadline!(poll) do
    Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
      set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
    )

    Deadlines.close_due(DateTime.utc_now(:second))
    Polls.get_poll(poll.id)
  end

  defp admin?(profile, group),
    do: Access.for_profile(profile, Repo.reload!(group)).admin?

  defp role_row(profile, group, key \\ "admin") do
    Repo.one(
      from(r in GroupMemberRole,
        where: r.group_id == ^group.id and r.profile_id == ^profile.id and r.role_key == ^key
      )
    )
  end

  defp elect!(group) do
    Repo.update_all(from(g in PotokIde.Social.Group, where: g.id == ^group.id),
      set: [elects_admins: true]
    )

    Repo.reload!(group)
  end

  describe "who may put a decision to a vote" do
    test "an admin, in a group of its founders", %{owner: owner, member: member, group: group} do
      assert Effects.may_propose?(Access.for_profile(owner, group), group)
      refute Effects.may_propose?(Access.for_profile(member, group), group)

      assert {:error, :not_permitted} =
               Polls.create_poll(member, group, poll_attrs(grant_attrs(member)), @zone)
    end

    test "anyone who may start a poll, in a group that elects its admins", %{
      member: member,
      group: group
    } do
      group = elect!(group)
      assert Effects.may_propose?(Access.for_profile(member, group), group)

      assert {:ok, _poll} =
               Polls.create_poll(member, group, poll_attrs(grant_attrs(member)), @zone)
    end

    test "never at the root", %{owner: owner} do
      root = Social.get_root_group!()
      refute Effects.group_allowed?(root)
      refute Effects.may_propose?(Access.for_profile(owner, root), root)
    end

    test "ending elections only where the group elects", %{owner: owner, group: group} do
      refute Effects.may_propose?(Access.for_profile(owner, group), group, :end_elections)
      group = elect!(group)
      assert Effects.may_propose?(Access.for_profile(owner, group), group, :end_elections)
    end
  end

  describe "a poll that changes roles" do
    test "takes fixed answers and keeps its promises", %{
      owner: owner,
      member: member,
      group: group
    } do
      attrs =
        grant_attrs(member, %{
          "kind" => "multiple",
          "voter_role_keys" => ["admin"],
          "abstain" => "true"
        })

      poll = create_poll!(owner, group, attrs)

      assert poll.effect == :grant
      assert poll.effect_role_key == "admin"
      assert poll.effect_profile_id == member.id
      assert poll.kind == :single
      assert poll.voter_role_keys == ["everyone"]
      assert Enum.map(poll.options, & &1.text) == ["For", "Against", "Abstain"]
      assert Enum.map(poll.options, & &1.approves) == [true, false, false]
    end

    test "needs a majority, a quorum and a deadline", %{
      owner: owner,
      member: member,
      group: group
    } do
      for {field, attrs} <- [
            majority: %{"majority" => "none"},
            quorum_percent: %{"quorum_percent" => ""},
            closes_local: %{"closes_local" => ""}
          ] do
        assert {:error, changeset} =
                 Polls.create_poll(owner, group, poll_attrs(grant_attrs(member, attrs)), @zone)

        assert Keyword.has_key?(changeset.errors, field), inspect({field, changeset.errors})
      end

      assert {:error, changeset} =
               Polls.create_poll(
                 owner,
                 group,
                 poll_attrs(grant_attrs(member, %{"majority" => "plurality"})),
                 @zone
               )

      assert Keyword.has_key?(changeset.errors, :majority)
    end

    test "names members only, and a role they hold to take it", %{
      owner: owner,
      member: member,
      group: group
    } do
      {_account, stranger} = account_with_profile!("p#{System.unique_integer([:positive])}")

      assert {:error, changeset} =
               Polls.create_poll(owner, group, poll_attrs(grant_attrs(stranger)), @zone)

      assert Keyword.has_key?(changeset.errors, :effect_profile_id)

      assert {:error, changeset} =
               Polls.create_poll(
                 owner,
                 group,
                 poll_attrs(grant_attrs(member, %{"effect" => "revoke"})),
                 @zone
               )

      assert Keyword.has_key?(changeset.errors, :effect_profile_id)

      assert {:error, changeset} =
               Polls.create_poll(
                 owner,
                 group,
                 poll_attrs(grant_attrs(member, %{"effect_role_key" => "everyone"})),
                 @zone
               )

      assert Keyword.has_key?(changeset.errors, :effect_role_key)
    end

    test "changes nothing once a ballot is in, not even its deadline", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member))
      vote!(member, account, poll, 0)

      assert {:ok, updated} =
               Polls.update_poll(
                 owner,
                 Polls.get_poll(poll.id),
                 %{"question" => "Else?", "closes_local" => local_in(48)},
                 @zone
               )

      assert updated.question == poll.question
      assert updated.closes_at == poll.closes_at
    end

    test "ends at its deadline and not before, stays ended and stays", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      {:ok, poll} = Polls.create_poll(owner, group, poll_attrs(grant_attrs(member)), @zone)
      poll = Polls.get_poll(poll.id)
      vote!(member, account, poll, 0)

      assert {:error, :effect_poll} = Polls.close_poll(owner, poll)
      assert {:error, :decision} = Polls.delete_poll(owner, poll)
      assert {:error, :decision} = Social.delete_value(owner, Repo.get!(Value, poll.value_id))

      closed = past_deadline!(poll)
      assert closed.closed_at
      assert {:error, :effect_poll} = Polls.reopen_poll(owner, closed)
      assert {:error, :decision} = Polls.delete_poll(owner, closed)
    end

    test "without a vote it may still be taken back", %{
      owner: owner,
      member: member,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member))
      assert {:ok, _poll} = Polls.delete_poll(owner, poll)
    end
  end

  describe "carrying it out as the poll closes" do
    test "gives the role, by the decision", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member))
      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      closed = past_deadline!(poll)

      assert closed.outcome == :passed
      assert closed.effect_status == :applied
      assert admin?(member, group)
      assert role_row(member, group).poll_id == poll.id

      # The access history names the decision as who gave it.
      assert [%{kind: :role_given, poll_id: poll_id, actor_id: nil, role_key: "admin"}] =
               access_changes(group, :role_given)

      assert poll_id == poll.id
    end

    test "does nothing when the answer against wins", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member))
      vote!(member, account, poll, 1)
      vote!(owner, owner_account, poll, 1)

      closed = past_deadline!(poll)

      assert closed.outcome == :passed
      assert closed.effect_status == :rejected
      refute admin?(member, group)
    end

    test "does nothing without a quorum", %{
      owner: owner,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member, %{"quorum_percent" => "100"}))
      vote!(member, account, poll, 0)

      assert %{outcome: :no_quorum, effect_status: :rejected} = past_deadline!(poll)
      refute admin?(member, group)
    end

    test "says so when the member left or the role is gone", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      third: third,
      third_account: third_account,
      group: group
    } do
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      {:ok, role} = Social.create_group_role(owner, group, %{"name" => "blagajnik"})
      group = Repo.reload!(group)

      left = create_poll!(owner, group, grant_attrs(member))
      gone = create_poll!(owner, group, grant_attrs(third, %{"effect_role_key" => role.key}))

      for poll <- [left, gone] do
        vote!(owner, owner_account, poll, 0)
      end

      vote!(member, account, left, 0)
      vote!(third, third_account, gone, 0)

      {:ok, _member} = Social.remove_group_member(owner, group, member)
      {:ok, _role} = Social.delete_group_role(owner, group, role.key)

      assert %{effect_status: :not_a_member} = past_deadline!(left)
      assert %{effect_status: :role_gone} = past_deadline!(gone)
    end

    test "gives nothing a member holds through the parent, and says so", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      {:ok, _role} = Social.assign_group_member_role(owner, group, member.id, "admin")

      child =
        group_with_members!(owner, [], %{"inherits_members" => true, parent: group})

      assert %{member?: true, admin?: true} = Access.for_profile(member, child)

      poll = create_poll!(owner, child, grant_attrs(member))
      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      assert %{effect_status: :inherited_role} = past_deadline!(poll)
      assert admin?(member, child)
      assert role_row(member, child).inherited
    end

    test "never takes the last admin", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(owner, %{"effect" => "revoke"}))
      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      assert %{effect_status: :last_admin} = past_deadline!(poll)
      assert admin?(owner, group)
    end

    test "takes a role", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      {:ok, _role} = Social.assign_group_member_role(owner, group, member.id, "admin")
      poll = create_poll!(owner, group, grant_attrs(member, %{"effect" => "revoke"}))
      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      assert %{effect_status: :applied} = past_deadline!(poll)
      refute admin?(member, group)

      assert [%{kind: :role_taken, poll_id: poll_id, subject_id: subject_id}] =
               access_changes(group, :role_taken)

      assert {poll_id, subject_id} == {poll.id, member.id}
    end

    test "an election gives the role to the winner and, replacing, takes it from the others", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      third: third,
      third_account: third_account,
      group: group
    } do
      poll =
        create_poll!(owner, group, elect_attrs([member, third], %{"effect_replace" => "true"}))

      assert Enum.map(poll.options, & &1.profile_id) == [member.id, third.id]
      assert Enum.map(poll.options, & &1.text) == [member.username, third.username]

      vote!(owner, owner_account, poll, 0)
      vote!(member, account, poll, 0)
      vote!(third, third_account, poll, 1)

      assert %{effect_status: :applied} = past_deadline!(poll)
      assert admin?(member, group)
      refute admin?(owner, group)
      refute admin?(third, group)
      assert role_row(member, group).poll_id == poll.id
    end

    test "an election without replacing adds a holder", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      third: third,
      group: group
    } do
      poll = create_poll!(owner, group, elect_attrs([member, third]))
      vote!(owner, owner_account, poll, 0)
      vote!(member, account, poll, 0)

      assert %{effect_status: :applied} = past_deadline!(poll)
      assert admin?(member, group)
      assert admin?(owner, group)
    end

    test "members stand in an election for themselves, once", %{
      owner: owner,
      member: member,
      third: third,
      group: group
    } do
      {_account, fourth} = account_with_profile!("p#{System.unique_integer([:positive])}")
      add_member!(owner, group, fourth)

      poll =
        create_poll!(
          owner,
          group,
          elect_attrs([member, third], %{"allow_member_options" => "true"})
        )

      assert poll.allow_member_options
      assert {:ok, _poll} = Polls.add_option(fourth, poll, %{"text" => "anything"})

      candidates = Polls.get_poll(poll.id).options
      assert List.last(candidates).profile_id == fourth.id
      assert List.last(candidates).text == fourth.username

      assert {:error, :not_permitted} = Polls.add_option(fourth, Polls.get_poll(poll.id), %{})
    end

    test "a rolled back closing leaves no role", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      poll = create_poll!(owner, group, grant_attrs(member))
      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      {:error, :rollback} =
        Repo.transaction(fn ->
          locked = Repo.get!(Poll, poll.id)
          {closed, _announcements} = Polls.close_locked(locked, group, DateTime.utc_now(:second))
          assert closed.effect_status == :applied
          Repo.rollback(:rollback)
        end)

      refute admin?(member, group)
      assert %{closed_at: nil, effect_status: nil} = Polls.get_poll(poll.id)
    end
  end

  describe "a group that elects its admins" do
    test "turns on by an admin and off only by a decision", %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: account,
      group: group
    } do
      assert {:error, :not_permitted} = Social.set_elects_admins(member, group, true)
      assert {:ok, group} = Social.set_elects_admins(owner, group, true)
      assert Social.elects_admins?(group)
      assert {:error, :elected_mode} = Social.set_elects_admins(owner, group, false)

      poll =
        create_poll!(member, group, %{
          "question" => "Back to the founders?",
          "effect" => "end_elections",
          "majority" => "simple",
          "quorum_percent" => "50",
          "closes_local" => local_in(1)
        })

      vote!(member, account, poll, 0)
      vote!(owner, owner_account, poll, 0)

      assert %{effect_status: :applied} = past_deadline!(poll)
      refute Social.elects_admins?(group)

      assert [%{actor_id: actor_id}] = access_changes(group, :elections_on)
      assert actor_id == owner.id
      assert [%{poll_id: poll_id}] = access_changes(group, :elections_off)
      assert poll_id == poll.id
    end

    test "never at the root", %{owner: owner} do
      assert {:error, :not_allowed} =
               Social.set_elects_admins(owner, Social.get_root_group!(), true)
    end

    test "keeps Admin out of the hands of admins", %{owner: owner, member: member, group: group} do
      {:ok, _role} = Social.assign_group_member_role(owner, group, member.id, "admin")
      {:ok, group} = Social.set_elects_admins(owner, group, true)

      {_account, other} = account_with_profile!("p#{System.unique_integer([:positive])}")
      add_member!(owner, group, other)

      assert {:error, :elected_role} =
               Social.assign_group_member_role(owner, group, other.id, "admin")

      assert {:error, :elected_role} =
               Social.unassign_group_member_role(owner, group, member.id, "admin")

      assert {:error, :elected_admin} = Social.remove_group_member(owner, group, member)
      assert {:ok, _member} = Social.remove_group_member(owner, group, other)
    end
  end

  defp access_changes(group, kind) do
    import Ecto.Query, only: [from: 2]

    PotokIde.Repo.all(
      from(c in PotokIde.Social.GroupAccessChange,
        where: c.group_id == ^group.id and c.kind == ^kind,
        order_by: c.id
      )
    )
  end
end
