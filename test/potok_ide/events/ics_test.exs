defmodule PotokIde.Events.ICSTest do
  use ExUnit.Case, async: true

  alias PotokIde.Events.{Event, ICS, Recurrence}

  @zone "Europe/Belgrade"
  @now ~U[2026-11-02 10:00:00Z]

  defp event(date, time, minutes, attrs) do
    starts_at = Recurrence.to_utc(date, time, @zone)

    struct!(
      %Event{
        id: 7,
        title: "Training",
        time_zone: @zone,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, minutes * 60)
      },
      attrs
    )
  end

  defp lines(event) do
    event
    |> ICS.render(host: "potok.rs", url: "https://potok.rs/groups/1/calendar?event=7", now: @now)
    |> String.split("\r\n", trim: true)
  end

  test "a one-off event in UTC" do
    lines = lines(event(~D[2026-11-07], ~T[18:00:00], 90, location: "Hall 2"))

    assert List.first(lines) == "BEGIN:VCALENDAR"
    assert List.last(lines) == "END:VCALENDAR"
    assert "UID:event-7@potok.rs" in lines
    assert "DTSTAMP:20261102T100000Z" in lines
    assert "DTSTART:20261107T170000Z" in lines
    assert "DTEND:20261107T183000Z" in lines
    assert "LOCATION:Hall 2" in lines
    assert "STATUS:CONFIRMED" in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "RRULE"))
  end

  test "a weekly event in its zone, with its end and cancelled dates" do
    lines =
      lines(
        event(~D[2026-11-04], ~T[18:00:00], 60,
          recurrence: :weekly,
          recurrence_interval: 2,
          recurrence_weekdays: [1, 3],
          recurrence_until: ~D[2026-12-31],
          excluded_dates: [~D[2026-11-16]],
          sequence: 3
        )
      )

    assert "DTSTART;TZID=Europe/Belgrade:20261104T180000" in lines
    assert "DTEND;TZID=Europe/Belgrade:20261104T190000" in lines
    assert "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;UNTIL=20261231T225959Z" in lines
    assert "EXDATE;TZID=Europe/Belgrade:20261116T180000" in lines
    assert "SEQUENCE:3" in lines
  end

  test "monthly and yearly rules" do
    rule = fn attrs ->
      ~D[2026-11-27]
      |> event(~T[19:00:00], 60, attrs)
      |> lines()
      |> Enum.find(&String.starts_with?(&1, "RRULE:"))
    end

    assert rule.(recurrence: :monthly) == "RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=27"

    assert rule.(recurrence: :monthly, recurrence_monthly: :nth_weekday) ==
             "RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=4FR"

    assert rule.(recurrence: :monthly, recurrence_monthly: :last_weekday) ==
             "RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR"

    assert rule.(recurrence: :yearly) == "RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYMONTHDAY=27"
  end

  test "an all-day event uses dates with an exclusive end" do
    event = %{
      event(~D[2026-11-07], ~T[00:00:00], 2 * 24 * 60,
        all_day: true,
        recurrence: :yearly,
        recurrence_until: ~D[2030-11-07],
        excluded_dates: [~D[2027-11-07]]
      )
      | ends_at: Recurrence.to_utc(~D[2026-11-09], ~T[00:00:00], @zone)
    }

    lines = lines(event)

    assert "DTSTART;VALUE=DATE:20261107" in lines
    assert "DTEND;VALUE=DATE:20261109" in lines
    assert "RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYMONTHDAY=7;UNTIL=20301107" in lines
    assert "EXDATE;VALUE=DATE:20271107" in lines
  end

  test "escapes text, folds long lines without splitting characters, marks cancellations" do
    description = "Bring: water, shoes; a towel\nŠčćđž " <> String.duplicate("ž", 60)

    ics =
      event(~D[2026-11-07], ~T[18:00:00], 60,
        description: description,
        cancelled_at: @now
      )
      |> ICS.render(host: "potok.rs", now: @now)

    physical = String.split(ics, "\r\n", trim: true)
    assert Enum.all?(physical, &(byte_size(&1) <= 75))
    assert Enum.all?(physical, &String.valid?/1)

    unfolded = String.replace(ics, "\r\n ", "")
    assert unfolded =~ "DESCRIPTION:Bring: water\\, shoes\\; a towel\\nŠčćđž "
    assert unfolded =~ "STATUS:CANCELLED"
  end
end
