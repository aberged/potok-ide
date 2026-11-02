defmodule PotokIdeWeb.GroupLive.CalendarTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.Event
  alias PotokIde.Repo
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("cal-owner")
    {member_account, member} = account_with_profile!("cal-member")
    group = group_with_members!(owner, [member], %{"is_public" => true})
    # A day well inside next month, so it is always to come.
    date = today() |> Date.end_of_month() |> Date.add(10)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      date: date
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => zone()})
    |> live(path)
  end

  defp month(date), do: Calendar.strftime(date, "%Y-%m")

  defp calendar_path(group, date, extra \\ []) do
    extra = Enum.map(extra, fn {key, value} -> {key, to_param(value)} end)
    ~p"/groups/#{group.id}/calendar?#{[{:month, month(date)} | extra]}"
  end

  defp to_param(%Date{} = date), do: Date.to_iso8601(date)
  defp to_param(value), do: value

  test "members have the calendar, others do not", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))
    assert has_element?(lv, "#group-panel-calendar")
    assert has_element?(lv, "#group-tab-calendar")
    assert has_element?(lv, "#calendar-day-#{ctx.date}")

    {outsider_account, _outsider} = account_with_profile!("cal-outsider")
    {:ok, lv, _html} = live_as(outsider_account, calendar_path(ctx.group, ctx.date))
    refute has_element?(lv, "#group-panel-calendar")
    refute has_element?(lv, "#group-tab-calendar")
  end

  test "shows the month's events and moves between months", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))

    assert has_element?(lv, "#calendar-day-#{ctx.date} #calendar-chip-#{event.id}-#{ctx.date}")

    lv |> element("#calendar-next-month") |> render_click()
    next = ctx.date |> Date.end_of_month() |> Date.add(1)
    assert_patch(lv, calendar_path(ctx.group, next))
    refute has_element?(lv, "#calendar-chip-#{event.id}-#{ctx.date}")

    lv |> element("#calendar-view-list") |> render_click()
    assert_patch(lv, calendar_path(ctx.group, next, mode: "list"))
    assert has_element?(lv, "#calendar-list-empty")

    {:ok, lv, _html} =
      live_as(ctx.member_account, calendar_path(ctx.group, ctx.date, mode: "list"))

    assert has_element?(lv, "#calendar-list #calendar-occurrence-#{event.id}-#{ctx.date}")
  end

  test "a member adds an event that is announced in the chat", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))

    lv |> element("#calendar-day-#{ctx.date}") |> render_click()
    lv |> element("#calendar-new-event") |> render_click()
    assert has_element?(lv, "#calendar-event-form")

    lv
    |> form("#calendar-event-form", event: %{"title" => " ", "start_time" => "18:00"})
    |> render_submit()

    assert has_element?(lv, "#calendar-event-form")
    assert Repo.aggregate(Event, :count) == 0

    lv
    |> form("#calendar-event-form",
      event: %{
        "title" => "Board games",
        "start_date" => Date.to_iso8601(ctx.date),
        "start_time" => "19:00",
        "end_date" => Date.to_iso8601(ctx.date),
        "end_time" => "22:00",
        "location" => "Club",
        "recurrence" => "none"
      }
    )
    |> render_submit()

    event = Repo.one!(Event)
    assert event.title == "Board games"
    assert event.time_zone == zone()
    assert event.creator_id == ctx.member.id
    assert_patch(lv, calendar_path(ctx.group, ctx.date, event: event.id, on: ctx.date))
    assert has_element?(lv, "#calendar-event-detail #calendar-event-title", "Board games")
    assert has_element?(lv, "#calendar-chip-#{event.id}-#{ctx.date}")

    {:ok, chat, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
    assert has_element?(chat, "#value-event-card-#{event.value_id}")
    refute has_element?(chat, "#value-edit-#{event.value_id}")
  end

  test "a weekly event repeats on the chosen weekdays", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))
    lv |> element("#calendar-day-#{ctx.date}") |> render_click()
    lv |> element("#calendar-new-event") |> render_click()

    lv
    |> form("#calendar-event-form", event: %{"recurrence" => "weekly"})
    |> render_change()

    assert has_element?(lv, "#calendar-form-weekdays")
    other_day = rem(Date.day_of_week(ctx.date), 7) + 1

    lv
    |> form("#calendar-event-form",
      event: %{
        "title" => "Training",
        "recurrence" => "weekly",
        "recurrence_weekdays" => ["", to_string(other_day)]
      }
    )
    |> render_submit()

    event = Repo.one!(Event)

    assert event.recurrence_weekdays ==
             Enum.sort([Date.day_of_week(ctx.date), other_day])

    assert has_element?(lv, "#calendar-chip-#{event.id}-#{Date.add(ctx.date, 1)}")
    assert has_element?(lv, "#calendar-event-recurrence")
  end

  test "answers and own reminders", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))

    {:ok, lv, _html} =
      live_as(
        ctx.member_account,
        calendar_path(ctx.group, ctx.date, event: event.id, on: ctx.date)
      )

    assert has_element?(lv, "#calendar-rsvp-going-count", "0")
    lv |> element("#calendar-rsvp-going") |> render_click()
    assert has_element?(lv, ~s(#calendar-rsvp-going[aria-pressed="true"]))
    assert has_element?(lv, "#calendar-rsvp-going-count", "1")
    assert has_element?(lv, "#calendar-rsvp-going-profiles")

    # Pressing it again takes the answer back.
    lv |> element("#calendar-rsvp-going") |> render_click()
    assert has_element?(lv, "#calendar-rsvp-going-count", "0")

    refute has_element?(lv, "#calendar-default-reminders")

    lv
    |> form("#calendar-my-reminders-form", reminders: %{"reminder_minutes" => ["", "1440"]})
    |> render_submit()

    assert Events.member_reminders(ctx.member, event) == [1440]
    assert has_element?(lv, "#calendar-default-reminders")

    lv |> element("#calendar-default-reminders") |> render_click()
    assert Events.member_reminders(ctx.member, event) == nil
  end

  test "only the author and managers change or cancel an event", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    path = calendar_path(ctx.group, ctx.date, event: event.id, on: ctx.date)

    {:ok, lv, _html} = live_as(ctx.member_account, path)
    assert has_element?(lv, "#calendar-ics")
    refute has_element?(lv, "#calendar-edit-event")
    refute has_element?(lv, "#calendar-cancel-event")

    {:ok, lv, _html} = live_as(ctx.owner_account, path)
    lv |> element("#calendar-edit-event") |> render_click()

    lv
    |> form("#calendar-event-form", event: %{"start_time" => "17:00", "end_time" => "18:00"})
    |> render_submit(%{"notify" => "false"})

    assert Repo.reload!(event).starts_at ==
             PotokIde.Events.Recurrence.to_utc(ctx.date, ~T[17:00:00], zone())

    lv |> element("#calendar-cancel-event") |> render_click()
    assert Event.cancelled?(Repo.reload!(event))
    assert has_element?(lv, "#calendar-event-cancelled")
    refute has_element?(lv, "#calendar-chip-#{event.id}-#{ctx.date}")
  end

  test "sub-groups' events show with the switch, and every group's in the root", ctx do
    sub = group_with_members!(ctx.owner, [ctx.member], %{parent: ctx.group})
    event = create_event!(ctx.owner, sub, event_attrs(ctx.date, %{"title" => "Sub meeting"}))
    chip = "#calendar-chip-#{event.id}-#{ctx.date}"

    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))
    refute has_element?(lv, chip)

    lv |> element("#calendar-subgroups-toggle") |> render_click()
    assert has_element?(lv, chip)

    lv |> element(chip) |> render_click()
    assert has_element?(lv, "#calendar-open-group")
    refute has_element?(lv, "#calendar-edit-event")

    root = Social.get_root_group!()
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(root, ctx.date))
    assert has_element?(lv, chip)
    refute has_element?(lv, "#calendar-new-event")
    refute has_element?(lv, "#calendar-subgroups-toggle")
  end

  test "events added by others appear while the calendar is open", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))

    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    assert has_element?(lv, "#calendar-chip-#{event.id}-#{ctx.date}")

    {:ok, _} = Events.cancel_event(ctx.owner, event)
    refute has_element?(lv, "#calendar-chip-#{event.id}-#{ctx.date}")
  end

  test "an unknown event shows the calendar with a message", ctx do
    {:ok, lv, _html} =
      live_as(ctx.member_account, calendar_path(ctx.group, ctx.date, event: 999_999))

    assert has_element?(lv, "#calendar-grid")
    refute has_element?(lv, "#calendar-event-detail")
  end
end
