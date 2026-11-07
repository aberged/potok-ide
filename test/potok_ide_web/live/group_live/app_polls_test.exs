defmodule PotokIdeWeb.GroupLive.AppPollsTest do
  @moduledoc """
  What an app gets of polls: what the rules show its viewer, and no way to vote
  in their name.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("ap-owner")
    {member_account, member} = account_with_profile!("ap-member")
    group = app_group!(owner, [member])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  defp app_group!(owner, members, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
        Map.merge(
          %{
            "name" => "app-#{System.unique_integer([:positive])}",
            "description" => "<p>app</p>",
            "description_format" => :html,
            "uses_api" => true,
            "home_page" => :description
          },
          attrs
        )
      )

    Enum.each(members, &add_member!(owner, group, &1))
    group
  end

  defp open_app(account, group) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => zone()})
      |> live(~p"/groups/#{group.id}/group_home")

    lv
  end

  defp call(lv, method, params \\ %{}) do
    render_hook(lv, "app_api", %{method: method, params: params, app_id: ""})
    assert_reply(lv, reply)
    reply
  end

  test "lists the group's polls with what the viewer may see", ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    vote!(ctx.owner, ctx.owner_account, poll, 0)

    lv = open_app(ctx.member_account, ctx.group)

    assert %{ok: true, polls: [listed], has_more: false} = call(lv, "list_polls")
    assert listed.id == poll.id
    assert listed.can_vote
    assert listed.voters_count == 1
    refute listed.can_see_results
    assert [nil, nil] = Enum.map(listed.options, & &1.votes_count)
  end

  test "the numbers come once the rules show them", ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    vote!(ctx.member, ctx.member_account, poll, 0)

    lv = open_app(ctx.member_account, ctx.group)

    assert %{ok: true, poll: seen} = call(lv, "get_poll", %{id: poll.id})
    assert seen.voted
    assert seen.can_see_results
    assert [1, 0] = Enum.map(seen.options, & &1.votes_count)
    assert [true, false] = Enum.map(seen.options, & &1.mine)
  end

  test "a secret poll gives an app no counts and no choice", ctx do
    poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})
    vote!(ctx.member, ctx.member_account, poll, 0)

    lv = open_app(ctx.owner_account, ctx.group)

    assert %{ok: true, poll: seen} = call(lv, "get_poll", %{id: poll.id})
    assert [nil, nil] = Enum.map(seen.options, & &1.votes_count)
    assert [false, false] = Enum.map(seen.options, & &1.mine)
  end

  test "reaches only the polls of its own group", ctx do
    other = group_with_members!(ctx.owner, [ctx.member])
    poll = create_poll!(ctx.owner, other)

    lv = open_app(ctx.member_account, ctx.group)

    assert %{ok: false, error: "not_found"} = call(lv, "get_poll", %{id: poll.id})
    assert %{ok: false, error: "not_found"} = call(lv, "open_poll", %{id: poll.id})
  end

  test "a visitor of a public group sees its public polls", ctx do
    public = app_group!(ctx.owner, [], %{"is_public" => true})
    poll = create_poll!(ctx.owner, public, %{"is_public" => "true"})
    hidden = create_poll!(ctx.owner, public, %{"question" => "Members?"})
    {visitor_account, _visitor} = account_with_profile!("ap-visitor")

    lv = open_app(visitor_account, public)

    assert %{ok: true, polls: [listed]} = call(lv, "list_polls")
    assert listed.id == poll.id
    assert %{ok: false, error: "not_found"} = call(lv, "get_poll", %{id: hidden.id})
  end

  test "an app has no call that votes, changes or deletes", ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    lv = open_app(ctx.owner_account, ctx.group)

    for method <- ~w(vote vote_poll close_poll reopen_poll delete_poll poll_details) do
      assert %{ok: false, error: "unknown_method"} = call(lv, method, %{id: poll.id})
    end

    assert %{voters_count: 0, closed_at: nil} = Polls.get_poll(poll.id)
  end

  test "voting opens on the page, over the app", ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    lv = open_app(ctx.member_account, ctx.group)

    assert %{ok: true} = call(lv, "open_poll", %{id: poll.id})
    assert has_element?(lv, "#poll-dialog")

    lv |> element("#poll-dialog-card-vote-#{hd(option_ids(poll))}") |> render_click()

    assert %{voters_count: 1} = Polls.get_poll(poll.id)

    assert has_element?(lv, "#poll-dialog", "Your vote is recorded.") or
             has_element?(lv, "#poll-dialog-card")

    lv |> element("#poll-dialog-close") |> render_click()
    refute has_element?(lv, "#poll-dialog")
  end

  test "the form opens on the page, over the app", ctx do
    lv = open_app(ctx.member_account, ctx.group)

    assert %{ok: true} = call(lv, "open_poll_form")
    assert has_element?(lv, "#poll-form-dialog")
  end

  test "the form stays shut for one who may not start a poll", ctx do
    public = app_group!(ctx.owner, [], %{"is_public" => true})
    create_poll!(ctx.owner, public, %{"is_public" => "true"})
    {visitor_account, _visitor} = account_with_profile!("ap-visitor")
    lv = open_app(visitor_account, public)

    assert %{ok: false, error: "forbidden"} = call(lv, "open_poll_form")
    refute has_element?(lv, "#poll-form-dialog")
  end

  test "an app hears which poll changed, and nothing about the vote", ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    lv = open_app(ctx.member_account, ctx.group)
    poll_id = poll.id

    vote!(ctx.owner, ctx.owner_account, poll, 0)

    assert_push_event(lv, "poll_changed", %{id: ^poll_id})
  end

  test "the frame is told the page's language", ctx do
    lv = open_app(ctx.member_account, ctx.group)

    assert render(lv) =~ ~s(lang=&quot;)
  end
end
