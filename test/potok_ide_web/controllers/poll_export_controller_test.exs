defmodule PotokIdeWeb.PollExportControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls

  setup do
    {owner_account, owner} = account_with_profile!("pe-owner")
    {member_account, member} = account_with_profile!("pe-member")
    group = group_with_members!(owner, [member])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  defp download(conn, account, poll, part) do
    conn
    |> log_in_account(account)
    |> get(~p"/polls/#{poll.id}/results.csv?#{[part: part]}")
  end

  test "the organizer gets the results", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    vote!(ctx.member, ctx.member_account, poll, 0)

    conn = download(conn, ctx.owner_account, poll, "results")
    body = response(conn, 200)

    assert response_content_type(conn, :csv) =~ "text/csv"
    assert String.starts_with?(body, "﻿")
    assert body =~ "Sea,1,100"
    assert body =~ "Mountains,0,0"
  end

  test "the voters' file names who voted for what", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    vote!(ctx.member, ctx.member_account, poll, 1)

    body = conn |> download(ctx.owner_account, poll, "voters") |> response(200)

    assert body =~ "pe-member"
    assert body =~ "Mountains"
  end

  test "the voters' file of a secret poll holds no answers", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})
    vote!(ctx.member, ctx.member_account, poll, 1)

    body = conn |> download(ctx.owner_account, poll, "voters") |> response(200)

    assert body =~ "pe-member"
    refute body =~ "Mountains"
  end

  test "an open secret poll gives no results to anyone", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})

    conn |> download(ctx.owner_account, poll, "results") |> response(404)
  end

  test "a member without the right gets neither", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group, %{"results_when" => "closed"})

    conn |> download(ctx.member_account, poll, "results") |> response(404)
    build_conn() |> download(ctx.member_account, poll, "voters") |> response(404)
  end

  test "those outside get nothing", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group)
    {:ok, closed} = Polls.close_poll(ctx.owner, poll)
    {outsider_account, _outsider} = account_with_profile!("pe-outside")

    conn |> download(outsider_account, closed, "results") |> response(404)
  end

  test "logged-out visitors are sent to log in", %{conn: conn} = ctx do
    poll = create_poll!(ctx.owner, ctx.group)

    conn = get(conn, ~p"/polls/#{poll.id}/results.csv")

    assert redirected_to(conn) =~ "/accounts/log-in"
  end

  test "an answer that could start a formula is marked as text", %{conn: conn} = ctx do
    options = %{"0" => %{"text" => "=1+1"}, "1" => %{"text" => "@sum"}}
    poll = create_poll!(ctx.owner, ctx.group, %{"options" => options})

    body = conn |> download(ctx.owner_account, poll, "results") |> response(200)

    assert body =~ "'=1+1"
    assert body =~ "'@sum"
  end

  test "a cell with the separator is quoted", %{conn: conn} = ctx do
    options = %{"0" => %{"text" => "Yes, gladly"}, "1" => %{"text" => "No"}}
    poll = create_poll!(ctx.owner, ctx.group, %{"options" => options})

    body = conn |> download(ctx.owner_account, poll, "results") |> response(200)

    assert body =~ ~s("Yes, gladly")
  end
end
