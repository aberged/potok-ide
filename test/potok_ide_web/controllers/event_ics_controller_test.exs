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

  test "the file says where the event takes place, as the one who asks sees it", %{conn: conn} do
    {owner_account, owner} = account_with_profile!("ics-geo-owner")
    {member_account, member} = account_with_profile!("ics-geo-member")
    group = group_with_members!(owner, [member])

    # A spot only the owner is in.
    spot = group_with_members!(owner, [], %{"latitude" => 45.25, "longitude" => 19.85})

    event =
      create_event!(
        owner,
        group,
        event_attrs(Date.add(today(), 3), %{"place_group_id" => "#{spot.id}"})
      )

    body =
      conn
      |> log_in_account(owner_account)
      |> get(~p"/events/#{event.id}/event.ics")
      |> response(200)

    assert body =~ "GEO:45.250000;19.850000"

    body =
      build_conn()
      |> log_in_account(member_account)
      |> get(~p"/events/#{event.id}/event.ics")
      |> response(200)

    refute body =~ "GEO:"
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
