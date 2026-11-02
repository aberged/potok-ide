defmodule PotokIdeWeb.EventIcsControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.EventsFixtures

  setup do
    {owner_account, owner} = account_with_profile!("ics-owner")
    group = group_with_members!(owner, [])
    event = create_event!(owner, group, event_attrs(Date.add(today(), 3)))

    %{owner_account: owner_account, event: event}
  end

  test "a member downloads the calendar file", %{conn: conn} = ctx do
    conn =
      conn
      |> log_in_account(ctx.owner_account)
      |> get(~p"/events/#{ctx.event.id}/event.ics")

    assert response(conn, 200) =~ "BEGIN:VEVENT"
    assert response_content_type(conn, :ics) =~ "text/calendar"

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="event-#{ctx.event.id}.ics")]
  end

  test "others get nothing", %{conn: conn} = ctx do
    {outsider_account, _outsider} = account_with_profile!("ics-outsider")

    conn
    |> log_in_account(outsider_account)
    |> get(~p"/events/#{ctx.event.id}/event.ics")
    |> response(404)

    build_conn()
    |> log_in_account(ctx.owner_account)
    |> get(~p"/events/nope/event.ics")
    |> response(404)
  end

  test "logged-out visitors are sent to the login page", %{conn: conn} = ctx do
    conn = get(conn, ~p"/events/#{ctx.event.id}/event.ics")
    assert redirected_to(conn) == ~p"/accounts/log-in"
  end
end
