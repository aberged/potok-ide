defmodule PotokIdeWeb.GroupLive.RequestsFlowTest do
  @moduledoc """
  Asking to join with roles and asking for roles as a member, on the group
  page, and deciding both there and on the requests page.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Polls.Poll
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupJoinRequest, GroupRequests}

  @rule %{
    "quorum_percent" => "50",
    "majority" => "simple",
    "hours" => "24",
    "unique_votes" => "yes",
    "shared_votes" => "as_one"
  }

  setup do
    {owner_account, owner} = account_with_profile!("rf-owner")
    {member_account, member} = account_with_profile!("rf-member")
    {asker_account, asker} = account_with_profile!("rf-asker")
    group = group_with_members!(owner, [member], %{"is_public" => true})
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    {:ok, neighbour} = Social.create_group_role(owner, group, %{"name" => "komsija"})
    {:ok, council} = Social.create_group_role(owner, group, %{"name" => "savet"})

    {:ok, _role} =
      Social.set_role_request_rule(owner, group, neighbour.key, %{"request_mode" => "approve"})

    {:ok, _role} =
      Social.set_role_request_rule(owner, group, council.key, %{
        "request_mode" => "vote",
        "request_poll" => @rule
      })

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      asker: asker,
      asker_account: asker_account,
      group: Social.get_group!(group.id),
      neighbour: neighbour,
      council: council
    }
  end

  defp page(account, path) do
    {:ok, view, _html} = build_conn() |> log_in_account(account) |> live(path)
    view
  end

  test "asking to join, one picks roles, reads how each is had, and says why", ctx do
    view = page(ctx.asker_account, ~p"/groups/#{ctx.group.id}")

    view |> element("#group-request-access") |> render_click()

    assert has_element?(
             view,
             "#request-dialog-role-#{ctx.neighbour.key}",
             "gives the role or refuses it"
           )

    assert has_element?(
             view,
             "#request-dialog-role-#{ctx.council.key}",
             "the whole group reads your request"
           )

    refute has_element?(view, "#request-dialog-role-admin")

    view
    |> form("#request-form",
      request: %{role_keys: [ctx.neighbour.key, ctx.council.key], note: "Stanujem u broju 5."}
    )
    |> render_submit()

    refute has_element?(view, "#request-dialog")
    assert has_element?(view, "#group-request-access-pending")

    assert %GroupJoinRequest{note: "Stanujem u broju 5.", role_keys: keys} =
             Repo.get_by!(GroupJoinRequest, requester_id: ctx.asker.id)

    assert Enum.sort(keys) == Enum.sort([ctx.neighbour.key, ctx.council.key])
  end

  test "whoever decides reads the request, admits and gives a role, saying why", ctx do
    {:ok, request} =
      GroupRequests.request_access(ctx.asker, ctx.group, %{
        "role_keys" => [ctx.neighbour.key],
        "note" => "Komšija sam."
      })

    view = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")

    assert has_element?(view, "#group-join-request-#{request.id}-note", "Komšija sam.")
    assert has_element?(view, "#group-join-request-#{request.id}-roles", "komsija")
    refute has_element?(view, "#group-accept-join-request-#{request.id}")

    view |> element("#group-decide-join-request-#{request.id}") |> render_click()
    assert has_element?(view, "#request-decision-note", "Komšija sam.")

    view
    |> form("#request-decision-form",
      decision: %{
        admission: "admit",
        roles: %{ctx.neighbour.key => "grant"},
        reason: "Dobrodošao."
      }
    )
    |> render_submit()

    refute has_element?(view, "#request-decision-dialog")
    assert Social.member_of_group?(ctx.asker, ctx.group)
    assert ctx.neighbour.key in Access.for_profile(ctx.asker, ctx.group).role_keys
  end

  test "a member asks for roles, and whoever decides gives one", ctx do
    member_view = page(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

    member_view |> element("#group-members-ask-roles") |> render_click()

    member_view
    |> form("#request-form",
      request: %{role_keys: [ctx.neighbour.key], note: "Pomažem oko ulaza."}
    )
    |> render_submit()

    request = GroupRequests.roles_request_of(ctx.group, ctx.member)
    assert request.role_keys == [ctx.neighbour.key]

    view = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")
    assert has_element?(view, "#group-role-request-#{request.id}-note", "Pomažem oko ulaza.")

    view |> element("#group-decide-role-request-#{request.id}") |> render_click()

    view
    |> form("#request-decision-form", decision: %{roles: %{ctx.neighbour.key => "grant"}})
    |> render_submit()

    assert ctx.neighbour.key in Access.for_profile(ctx.member, ctx.group).role_keys
    refute GroupRequests.roles_request_of(ctx.group, ctx.member)
  end

  test "where a vote admits, the request shows as voted on, to both sides", ctx do
    {:ok, _group} =
      Social.set_join_rule(ctx.owner, ctx.group, %{"join_mode" => "vote", "join_poll" => @rule})

    {:ok, request} = GroupRequests.request_access(ctx.asker, ctx.group, %{"note" => "Molim."})

    view = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")
    assert has_element?(view, "#group-join-request-#{request.id}-voting")
    refute has_element?(view, "#group-decide-join-request-#{request.id}")

    asker_view = page(ctx.asker_account, ~p"/groups/#{ctx.group.id}")

    assert has_element?(
             asker_view,
             "#group-request-access-pending",
             "The group votes on your request"
           )

    poll = Repo.get!(Poll, request.poll_id)
    chat = page(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

    assert has_element?(
             chat,
             "#value-poll-card-#{poll.value_id}",
             "becomes a member of the group"
           )
  end

  test "on the requests page whoever decides sees members' requests, and the one who asked takes one back",
       ctx do
    {:ok, _asked} =
      GroupRequests.request_roles(ctx.member, ctx.group, %{"role_keys" => [ctx.neighbour.key]})

    request = GroupRequests.roles_request_of(ctx.group, ctx.member)

    owner_view = page(ctx.owner_account, ~p"/requests")
    assert has_element?(owner_view, "#approval-role-request-#{request.id}")

    owner_view |> element("#role-request-decide-#{request.id}") |> render_click()

    owner_view
    |> form("#request-decision-form",
      decision: %{roles: %{ctx.neighbour.key => "refuse"}, reason: "Ima nas dovoljno."}
    )
    |> render_submit()

    refute GroupRequests.roles_request_of(ctx.group, ctx.member)

    member_view = page(ctx.member_account, ~p"/requests?section=created")
    assert has_element?(member_view, "#my-request-decisions", "Ima nas dovoljno.")

    {:ok, caretaker} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "domar"})

    {:ok, _role} =
      Social.set_role_request_rule(ctx.owner, ctx.group, caretaker.key, %{
        "request_mode" => "approve"
      })

    {:ok, _asked} =
      GroupRequests.request_roles(ctx.member, ctx.group, %{"role_keys" => [caretaker.key]})

    waiting = GroupRequests.roles_request_of(ctx.group, ctx.member)
    member_view = page(ctx.member_account, ~p"/requests?section=created")
    assert has_element?(member_view, "#my-role-request-#{waiting.id}", "domar")

    member_view |> element("#my-role-request-#{waiting.id}-withdraw") |> render_click()

    refute has_element?(member_view, "#my-role-request-#{waiting.id}")
    refute GroupRequests.roles_request_of(ctx.group, ctx.member)
  end
end
