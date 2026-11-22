defmodule PotokIde.Social.GroupRequestsTest do
  @moduledoc """
  Asking to join with roles, members asking for roles, and how whoever
  decides, or the group by a vote, answers.
  """

  use PotokIde.DataCase

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Polls.{Deadlines, Poll}
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    GroupJoinRequest,
    GroupJoinRequestApproval,
    GroupRequestDecision,
    GroupRequests,
    GroupRoleRequest
  }

  @rule %{
    "quorum_percent" => "50",
    "majority" => "simple",
    "hours" => "24",
    "unique_votes" => "yes",
    "shared_votes" => "as_one"
  }

  setup do
    n = System.unique_integer([:positive])
    {owner_account, owner} = account_with_profile!("gr-owner#{n}")
    {member_account, member} = account_with_profile!("gr-member#{n}")
    {asker_account, asker} = account_with_profile!("gr-asker#{n}")
    group = group_with_members!(owner, [member], %{"is_public" => true})
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    neighbour = role!(owner, group, "komsija", %{"request_mode" => "approve"})

    treasurer =
      role!(owner, group, "blagajnik", %{"request_mode" => "choose", "request_poll" => @rule})

    council = role!(owner, group, "savet", %{"request_mode" => "vote", "request_poll" => @rule})

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      asker: asker,
      asker_account: asker_account,
      group: Social.get_group!(group.id),
      neighbour: neighbour,
      treasurer: treasurer,
      council: council
    }
  end

  defp role!(owner, group, name, rule) do
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => name})
    {:ok, role} = Social.set_role_request_rule(owner, group, role.key, rule)
    role
  end

  defp roles_of(profile, group), do: Access.for_profile(profile, group).role_keys

  defp request_poll(group, profile, effect) do
    Repo.one!(
      from(p in Poll,
        where:
          p.group_id == ^group.id and p.effect_profile_id == ^profile.id and p.effect == ^effect and
            is_nil(p.closed_at)
      )
    )
  end

  defp end_poll!(poll) do
    Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
      set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
    )

    Deadlines.close_due(DateTime.utc_now(:second))
    Repo.reload!(poll)
  end

  defp decisions(profile) do
    from(d in GroupRequestDecision,
      where: d.profile_id == ^profile.id,
      order_by: d.id,
      select: {d.role_key, d.decision}
    )
    |> Repo.all()
  end

  describe "asking to join" do
    test "takes the roles the statute lets be asked for, and why", ctx do
      assert {:ok, request} =
               GroupRequests.request_access(ctx.asker, ctx.group, %{
                 "role_keys" => [ctx.neighbour.key, ctx.council.key, ""],
                 "note" => "  Živim u ulazu A.  "
               })

      assert request.role_keys == [ctx.neighbour.key, ctx.council.key]
      assert request.note == "Živim u ulazu A."
      assert request.poll_id == nil
    end

    test "refuses a role nobody may ask for", ctx do
      assert {:error, :role_not_requestable} =
               GroupRequests.request_access(ctx.asker, ctx.group, %{"role_keys" => ["admin"]})
    end

    test "offers only the roles one may ask for", ctx do
      asker = Access.for_profile(ctx.asker, ctx.group)

      assert ctx.group
             |> then(&GroupRequests.requestable_roles(asker, &1))
             |> Enum.map(& &1.name)
             |> Enum.sort() ==
               ["blagajnik", "komsija", "savet"]
    end
  end

  describe "whoever decides" do
    test "admits, gives a role, leaves one for later, and a role the rule votes on gets its vote",
         ctx do
      {:ok, request} =
        GroupRequests.request_access(ctx.asker, ctx.group, %{
          "role_keys" => [ctx.neighbour.key, ctx.treasurer.key, ctx.council.key],
          "note" => "Volim da pomognem."
        })

      assert {:ok, %{admitted: true}} =
               GroupRequests.decide(ctx.owner, ctx.group, {:join, request.id}, %{
                 "admission" => "admit",
                 "roles" => %{ctx.neighbour.key => "grant", ctx.treasurer.key => "later"},
                 "reason" => "Dobrodošao."
               })

      assert Social.member_of_group?(ctx.asker, ctx.group)
      assert ctx.neighbour.key in roles_of(ctx.asker, ctx.group)
      refute Repo.get(GroupJoinRequest, request.id)

      assert %GroupRoleRequest{role_keys: [treasurer_key], note: "Volim da pomognem."} =
               GroupRequests.roles_request_of(ctx.group, ctx.asker)

      assert treasurer_key == ctx.treasurer.key

      poll = request_poll(ctx.group, ctx.asker, :grant)
      assert poll.effect_role_key == ctx.council.key
      assert poll.creator_id == ctx.asker.id
      assert poll.from_request
      assert poll.description == "Volim da pomognem."
      assert poll.value_id, "it is posted in the chat in the name of whoever asked"

      assert decisions(ctx.asker) == [
               {ctx.neighbour.key, :granted},
               {ctx.council.key, :voted}
             ]

      assert %GroupJoinRequestApproval{approver_id: approver_id} =
               Repo.get_by!(GroupJoinRequestApproval, requester_id: ctx.asker.id)

      assert approver_id == ctx.owner.id
    end

    test "needs the right to manage requests, and Admin needs an admin", ctx do
      {:ok, request} =
        GroupRequests.request_access(ctx.asker, ctx.group, %{"role_keys" => [ctx.neighbour.key]})

      assert {:error, :not_permitted} =
               GroupRequests.decide(ctx.member, ctx.group, {:join, request.id}, %{
                 "admission" => "admit"
               })

      gatekeeper = role!(ctx.owner, ctx.group, "vratar", %{"request_mode" => "closed"})

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          gatekeeper.key,
          :manage_join_requests,
          :allow
        )

      {:ok, _member_role} =
        Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, gatekeeper.key)

      assert {:ok, %{admitted: true, granted: [_neighbour]}} =
               GroupRequests.decide(ctx.member, ctx.group, {:join, request.id}, %{
                 "admission" => "admit",
                 "roles" => %{ctx.neighbour.key => "grant"}
               })

      {:ok, _admin} =
        Social.set_role_request_rule(ctx.owner, ctx.group, "admin", %{"request_mode" => "approve"})

      {:ok, _asked} =
        GroupRequests.request_roles(ctx.asker, ctx.group, %{"role_keys" => ["admin"]})

      roles_request = GroupRequests.roles_request_of(ctx.group, ctx.asker)

      assert {:error, :not_permitted} =
               GroupRequests.decide(ctx.member, ctx.group, {:roles, roles_request.id}, %{
                 "roles" => %{"admin" => "grant"}
               })

      assert {:ok, %{granted: [_admin_role]}} =
               GroupRequests.decide(ctx.owner, ctx.group, {:roles, roles_request.id}, %{
                 "roles" => %{"admin" => "grant"}
               })

      assert Access.for_profile(ctx.asker, ctx.group).admin?
      refute GroupRequests.roles_request_of(ctx.group, ctx.asker)
    end

    test "refuses, which the one who asked waits out before asking again", ctx do
      {:ok, request} = GroupRequests.request_access(ctx.asker, ctx.group, %{})

      assert {:ok, %{admitted: false}} =
               GroupRequests.decide(ctx.owner, ctx.group, {:join, request.id}, %{
                 "admission" => "refuse",
                 "reason" => "Samo za stanare."
               })

      refute Repo.get(GroupJoinRequest, request.id)

      assert [
               %GroupRequestDecision{
                 decision: :declined,
                 reason: "Samo za stanare.",
                 role_key: nil
               }
             ] =
               Repo.all(from(d in GroupRequestDecision, where: d.profile_id == ^ctx.asker.id))

      assert {:error, :asked_lately} = GroupRequests.request_access(ctx.asker, ctx.group, %{})
    end

    test "puts admission to a vote only where the rule lets them choose", ctx do
      {:ok, request} = GroupRequests.request_access(ctx.asker, ctx.group, %{})

      assert {:error, :not_permitted} =
               GroupRequests.decide(ctx.owner, ctx.group, {:join, request.id}, %{
                 "admission" => "vote"
               })

      {:ok, _group} =
        Social.set_join_rule(ctx.owner, ctx.group, %{
          "join_mode" => "choose",
          "join_poll" => @rule
        })

      assert {:ok, %{admission_vote: true}} =
               GroupRequests.decide(ctx.owner, ctx.group, {:join, request.id}, %{
                 "admission" => "vote"
               })

      assert %GroupJoinRequest{poll_id: poll_id} = Repo.get!(GroupJoinRequest, request.id)
      assert %Poll{effect: :admit, creator_id: creator_id} = Repo.get!(Poll, poll_id)
      assert creator_id == ctx.asker.id

      assert {:error, :in_vote} =
               GroupRequests.decide(ctx.owner, ctx.group, {:join, request.id}, %{
                 "admission" => "admit"
               })

      assert {:error, :in_vote} = GroupRequests.withdraw(ctx.asker, ctx.group, :join)
    end

    test "cannot put to a vote a role the statute only gives or refuses", ctx do
      {:ok, _asked} =
        GroupRequests.request_roles(ctx.member, ctx.group, %{"role_keys" => [ctx.neighbour.key]})

      request = GroupRequests.roles_request_of(ctx.group, ctx.member)

      assert {:error, :not_permitted} =
               GroupRequests.decide(ctx.owner, ctx.group, {:roles, request.id}, %{
                 "roles" => %{ctx.neighbour.key => "vote"}
               })
    end
  end

  describe "a group that admits by a vote" do
    setup ctx do
      {:ok, group} =
        Social.set_join_rule(ctx.owner, ctx.group, %{"join_mode" => "vote", "join_poll" => @rule})

      %{group: group}
    end

    test "raises the vote as one asks, and its decision admits them with their roles", ctx do
      {:ok, request} =
        GroupRequests.request_access(ctx.asker, ctx.group, %{
          "role_keys" => [ctx.neighbour.key, ctx.council.key],
          "note" => "Komšija iz broja 3."
        })

      poll = Repo.get!(Poll, request.poll_id)
      assert poll.effect == :admit
      assert poll.effect_profile_id == ctx.asker.id
      assert poll.description == "Komšija iz broja 3."
      assert poll.quorum_percent == 50

      assert {:error, :decision} = Polls.delete_poll(ctx.owner, poll)

      vote!(ctx.owner, ctx.owner_account, poll, 0)
      vote!(ctx.member, ctx.member_account, poll, 0)
      assert %Poll{effect_status: :applied} = end_poll!(poll)

      assert Social.member_of_group?(ctx.asker, ctx.group)

      assert %GroupJoinRequestApproval{poll_id: poll_id, approver_id: nil} =
               Repo.get_by!(GroupJoinRequestApproval, requester_id: ctx.asker.id)

      assert poll_id == poll.id

      assert %GroupRoleRequest{role_keys: [neighbour_key]} =
               GroupRequests.roles_request_of(ctx.group, ctx.asker)

      assert neighbour_key == ctx.neighbour.key
      assert request_poll(ctx.group, ctx.asker, :grant).effect_role_key == ctx.council.key
    end

    test "a vote that does not admit ends the request", ctx do
      {:ok, request} = GroupRequests.request_access(ctx.asker, ctx.group, %{})
      poll = Repo.get!(Poll, request.poll_id)

      vote!(ctx.owner, ctx.owner_account, poll, 1)
      vote!(ctx.member, ctx.member_account, poll, 1)
      assert %Poll{effect_status: :rejected} = end_poll!(poll)

      refute Social.member_of_group?(ctx.asker, ctx.group)
      refute Repo.get(GroupJoinRequest, request.id)
      assert {:error, :asked_lately} = GroupRequests.request_access(ctx.asker, ctx.group, %{})
    end

    test "a request sent before the group voted on every one goes to a vote, and only so", ctx do
      {:ok, group} = Social.set_join_rule(ctx.owner, ctx.group, %{"join_mode" => "approve"})
      {:ok, request} = GroupRequests.request_access(ctx.asker, group, %{})

      {:ok, group} =
        Social.set_join_rule(ctx.owner, group, %{"join_mode" => "vote", "join_poll" => @rule})

      assert GroupRequests.admission_choices(group) == [:vote]

      assert {:error, :not_permitted} =
               GroupRequests.decide(ctx.owner, group, {:join, request.id}, %{
                 "admission" => "admit"
               })

      assert {:ok, %{admission_vote: true}} =
               GroupRequests.decide(ctx.owner, group, {:join, request.id}, %{
                 "admission" => "vote"
               })

      assert Repo.get!(GroupJoinRequest, request.id).poll_id
    end

    test "someone invited while the vote runs is in already", ctx do
      {:ok, request} = GroupRequests.request_access(ctx.asker, ctx.group, %{})
      poll = Repo.get!(Poll, request.poll_id)

      {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.asker)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.asker)

      vote!(ctx.owner, ctx.owner_account, poll, 0)
      vote!(ctx.member, ctx.member_account, poll, 0)
      assert %Poll{effect_status: :already_member} = end_poll!(poll)
    end
  end

  describe "a member asking for roles" do
    test "leaves one for whoever decides and puts the one the rule votes on to a vote", ctx do
      assert {:ok, %{voted: [_council], waiting: [_treasurer]}} =
               GroupRequests.request_roles(ctx.member, ctx.group, %{
                 "role_keys" => [ctx.treasurer.key, ctx.council.key],
                 "note" => "Vodim knjige već godinu dana."
               })

      assert %GroupRoleRequest{role_keys: [treasurer_key]} =
               GroupRequests.roles_request_of(ctx.group, ctx.member)

      assert treasurer_key == ctx.treasurer.key
      assert GroupRequests.voting_role_keys(ctx.group, ctx.member) == [ctx.council.key]

      assert {:error, :in_vote} =
               GroupRequests.request_roles(ctx.member, ctx.group, %{
                 "role_keys" => [ctx.council.key]
               })
    end

    test "whoever decides may put a role to a vote where the rule lets them", ctx do
      {:ok, _asked} =
        GroupRequests.request_roles(ctx.member, ctx.group, %{"role_keys" => [ctx.treasurer.key]})

      request = GroupRequests.roles_request_of(ctx.group, ctx.member)

      assert {:ok, %{voted: [_treasurer]}} =
               GroupRequests.decide(ctx.owner, ctx.group, {:roles, request.id}, %{
                 "roles" => %{ctx.treasurer.key => "vote"},
                 "reason" => "Neka odluči skup."
               })

      refute GroupRequests.roles_request_of(ctx.group, ctx.member)
      poll = request_poll(ctx.group, ctx.member, :grant)

      vote!(ctx.owner, ctx.owner_account, poll, 0)
      vote!(ctx.member, ctx.member_account, poll, 0)
      assert %Poll{effect_status: :applied} = end_poll!(poll)
      assert ctx.treasurer.key in roles_of(ctx.member, ctx.group)
    end

    test "a role one holds is not asked for", ctx do
      {:ok, _member_role} =
        Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, ctx.neighbour.key)

      assert {:error, :role_not_requestable} =
               GroupRequests.request_roles(ctx.member, ctx.group, %{
                 "role_keys" => [ctx.neighbour.key]
               })
    end

    test "can be taken back, and goes when the role is deleted", ctx do
      {:ok, _asked} =
        GroupRequests.request_roles(ctx.member, ctx.group, %{"role_keys" => [ctx.neighbour.key]})

      assert :ok = GroupRequests.withdraw(ctx.member, ctx.group, :roles)
      refute GroupRequests.roles_request_of(ctx.group, ctx.member)

      {:ok, _asked} =
        GroupRequests.request_roles(ctx.member, ctx.group, %{
          "role_keys" => [ctx.neighbour.key, ctx.treasurer.key]
        })

      {:ok, request} =
        GroupRequests.request_access(ctx.asker, ctx.group, %{"role_keys" => [ctx.neighbour.key]})

      {:ok, _role} = Social.delete_group_role(ctx.owner, ctx.group, ctx.neighbour.key)

      assert %GroupRoleRequest{role_keys: [treasurer_key]} =
               GroupRequests.roles_request_of(ctx.group, ctx.member)

      assert treasurer_key == ctx.treasurer.key
      assert Repo.get!(GroupJoinRequest, request.id).role_keys == []

      {:ok, _role} = Social.delete_group_role(ctx.owner, ctx.group, ctx.treasurer.key)
      refute GroupRequests.roles_request_of(ctx.group, ctx.member)
    end
  end

  describe "counts" do
    test "what waits for whoever decides: requests not in a vote, and members' requests", ctx do
      {:ok, _request} = GroupRequests.request_access(ctx.asker, ctx.group, %{})

      {:ok, _asked} =
        GroupRequests.request_roles(ctx.member, ctx.group, %{
          "role_keys" => [ctx.treasurer.key, ctx.council.key]
        })

      assert Social.count_pending_group_join_requests(ctx.group) == 2
      assert Social.count_pending_group_join_requests_for_approver(ctx.owner) == 2
      assert Social.nav_counts(ctx.owner).pending_group_join_requests == 2
      assert Social.nav_counts(ctx.member).pending_group_join_requests == 0
    end
  end

  test "Admin is had only by a vote where the group elects its admins", ctx do
    {:ok, _admin} =
      Social.set_role_request_rule(ctx.owner, ctx.group, "admin", %{"request_mode" => "approve"})

    {:ok, group} = Social.set_elects_admins(ctx.owner, ctx.group, true)
    admin = Enum.find(Access.effective_manifest(group).roles, &(&1.key == "admin"))

    assert GroupRequests.mode(admin, group) == :vote

    assert {:ok, %{voted: [_admin]}} =
             GroupRequests.request_roles(ctx.member, group, %{"role_keys" => ["admin"]})
  end
end
