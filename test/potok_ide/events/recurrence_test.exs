defmodule PotokIde.Events.RecurrenceTest do
  use ExUnit.Case, async: true

  alias PotokIde.Events.{Event, Occurrence, Recurrence}

  @zone "Europe/Belgrade"

  defp timed(date, time, minutes, attrs \\ []) do
    starts_at = Recurrence.to_utc(date, time, @zone)

    struct!(
      %Event{
        time_zone: @zone,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, minutes * 60)
      },
      attrs
    )
  end

  defp all_day(date, days, attrs) do
    struct!(
      %Event{
        time_zone: @zone,
        all_day: true,
        starts_at: Recurrence.to_utc(date, ~T[00:00:00], @zone),
        ends_at: Recurrence.to_utc(Date.add(date, days), ~T[00:00:00], @zone)
      },
      attrs
    )
  end

  defp dates(event, from, count) do
    event |> Recurrence.dates_from(from) |> Enum.take(count)
  end

  describe "to_utc/3" do
    test "moves a time in the spring-forward gap to the end of the gap" do
      assert Recurrence.to_utc(~D[2027-03-28], ~T[02:30:00], @zone) == ~U[2027-03-28 01:00:00Z]
    end

    test "takes the earlier instant of a time that happens twice" do
      assert Recurrence.to_utc(~D[2026-10-25], ~T[02:30:00], @zone) == ~U[2026-10-25 00:30:00Z]
    end
  end

  describe "dates_from/2" do
    test "a one-off event has its start date only" do
      event = timed(~D[2026-11-07], ~T[18:00:00], 60)

      assert dates(event, ~D[2026-11-01], 5) == [~D[2026-11-07]]
      assert dates(event, ~D[2026-11-08], 5) == []
      assert dates(%{event | excluded_dates: [~D[2026-11-07]]}, ~D[2026-11-01], 5) == []
    end

    test "daily with an interval, up to and including the until date" do
      event =
        timed(~D[2026-11-01], ~T[08:00:00], 30,
          recurrence: :daily,
          recurrence_interval: 2,
          recurrence_until: ~D[2026-11-07]
        )

      assert dates(event, ~D[2026-10-01], 10) ==
               [~D[2026-11-01], ~D[2026-11-03], ~D[2026-11-05], ~D[2026-11-07]]

      assert dates(event, ~D[2026-11-04], 10) == [~D[2026-11-05], ~D[2026-11-07]]
    end

    test "weekly on Monday and Wednesday of every second week" do
      event =
        timed(~D[2026-11-04], ~T[18:00:00], 90,
          recurrence: :weekly,
          recurrence_interval: 2,
          recurrence_weekdays: [1, 3]
        )

      # The Monday of the first week is before the start, so it is skipped.
      assert dates(event, ~D[2026-11-01], 5) ==
               [~D[2026-11-04], ~D[2026-11-16], ~D[2026-11-18], ~D[2026-11-30], ~D[2026-12-02]]
    end

    test "monthly on the second Tuesday" do
      event =
        timed(~D[2026-11-10], ~T[19:00:00], 60,
          recurrence: :monthly,
          recurrence_monthly: :nth_weekday
        )

      assert dates(event, ~D[2026-11-01], 3) == [~D[2026-11-10], ~D[2026-12-08], ~D[2027-01-12]]
    end

    test "monthly on the last Friday" do
      event =
        timed(~D[2026-11-27], ~T[19:00:00], 60,
          recurrence: :monthly,
          recurrence_monthly: :last_weekday
        )

      assert dates(event, ~D[2026-11-01], 3) == [~D[2026-11-27], ~D[2026-12-25], ~D[2027-01-29]]
    end

    test "monthly on day 31 skips the months without it" do
      event = timed(~D[2026-01-31], ~T[12:00:00], 60, recurrence: :monthly)

      assert dates(event, ~D[2026-01-01], 7) == [
               ~D[2026-01-31],
               ~D[2026-03-31],
               ~D[2026-05-31],
               ~D[2026-07-31],
               ~D[2026-08-31],
               ~D[2026-10-31],
               ~D[2026-12-31]
             ]
    end

    test "yearly on Feb 29 only in leap years" do
      event = all_day(~D[2028-02-29], 1, recurrence: :yearly)

      assert dates(event, ~D[2028-01-01], 3) == [~D[2028-02-29], ~D[2032-02-29], ~D[2036-02-29]]
    end

    test "leaves out cancelled dates" do
      event =
        timed(~D[2026-11-02], ~T[18:00:00], 60,
          recurrence: :weekly,
          excluded_dates: [~D[2026-11-09]]
        )

      assert dates(event, ~D[2026-11-01], 3) == [~D[2026-11-02], ~D[2026-11-16], ~D[2026-11-23]]
    end

    test "jumps to the requested date in a long series" do
      event = timed(~D[2000-01-01], ~T[07:00:00], 15, recurrence: :daily)

      assert dates(event, ~D[2026-11-02], 1) == [~D[2026-11-02]]
    end
  end

  describe "occurrences/3" do
    test "keep the wall-clock time across the end of daylight saving time" do
      event = timed(~D[2026-10-22], ~T[18:00:00], 60, recurrence: :weekly)

      assert [first, second] =
               Recurrence.occurrences(event, ~U[2026-10-20 00:00:00Z], ~U[2026-11-01 00:00:00Z])

      assert first.starts_at == ~U[2026-10-22 16:00:00Z]
      assert second.date == ~D[2026-10-29]
      assert second.starts_at == ~U[2026-10-29 17:00:00Z]
      assert second.ends_at == ~U[2026-10-29 18:00:00Z]
    end

    test "a daily time in the gap starts at the end of the gap that day" do
      event = timed(~D[2027-03-27], ~T[02:30:00], 30, recurrence: :daily)

      starts =
        event
        |> Recurrence.occurrences(~U[2027-03-26 00:00:00Z], ~U[2027-03-30 00:00:00Z])
        |> Enum.map(& &1.starts_at)

      assert starts == [
               ~U[2027-03-27 01:30:00Z],
               ~U[2027-03-28 01:00:00Z],
               ~U[2027-03-29 00:30:00Z]
             ]
    end

    test "all-day occurrences start at local midnight and keep their days" do
      event = all_day(~D[2026-10-24], 2, recurrence: :weekly)

      assert [first, second] =
               Recurrence.occurrences(event, ~U[2026-10-23 00:00:00Z], ~U[2026-11-02 00:00:00Z])

      assert {first.starts_at, first.ends_at} ==
               {~U[2026-10-23 22:00:00Z], ~U[2026-10-25 23:00:00Z]}

      assert {second.starts_at, second.ends_at} ==
               {~U[2026-10-30 23:00:00Z], ~U[2026-11-01 23:00:00Z]}
    end

    test "include an occurrence that started before the window and is still on" do
      event = timed(~D[2026-11-06], ~T[23:00:00], 120)

      assert [%Occurrence{date: ~D[2026-11-06]}] =
               Recurrence.occurrences(event, ~U[2026-11-06 23:30:00Z], ~U[2026-11-08 00:00:00Z])

      assert [] =
               Recurrence.occurrences(event, ~U[2026-11-07 00:00:00Z], ~U[2026-11-08 00:00:00Z])
    end
  end

  describe "next_occurrence_after/2" do
    test "matches a brute-force search" do
      events = [
        timed(~D[2026-10-20], ~T[18:00:00], 60,
          recurrence: :weekly,
          recurrence_weekdays: [2, 4, 6],
          excluded_dates: [~D[2026-10-29]]
        ),
        timed(~D[2026-09-30], ~T[02:30:00], 45, recurrence: :monthly, recurrence_interval: 2),
        timed(~D[2026-10-12], ~T[09:00:00], 30,
          recurrence: :monthly,
          recurrence_monthly: :nth_weekday
        ),
        all_day(~D[2026-10-31], 1, recurrence: :daily, recurrence_interval: 3)
      ]

      from = ~U[2026-09-01 00:00:00Z]
      to = ~U[2027-06-01 00:00:00Z]

      for event <- events do
        all = Recurrence.occurrences(event, from, to)

        for hours <- 0..6000//37 do
          instant = DateTime.add(from, hours * 3600)
          expected = Enum.find(all, &(DateTime.compare(&1.starts_at, instant) == :gt))

          assert Recurrence.next_occurrence_after(event, instant) == expected
        end
      end
    end

    test "is nil after the last occurrence" do
      event =
        timed(~D[2026-11-02], ~T[18:00:00], 60,
          recurrence: :daily,
          recurrence_until: ~D[2026-11-04]
        )

      assert Recurrence.next_occurrence_after(event, ~U[2026-11-04 18:00:00Z]) == nil
    end
  end

  test "occurs_on?/2 and occurrence/2" do
    event = timed(~D[2026-11-04], ~T[18:00:00], 60, recurrence: :weekly)

    assert Recurrence.occurs_on?(event, ~D[2026-11-11])
    refute Recurrence.occurs_on?(event, ~D[2026-11-12])
    refute Recurrence.occurs_on?(event, ~D[2026-10-28])

    assert %Occurrence{starts_at: ~U[2026-11-11 17:00:00Z]} =
             Recurrence.occurrence(event, ~D[2026-11-11])

    assert Recurrence.occurrence(event, ~D[2026-11-12]) == nil
  end

  test "monthly_modes_for/1" do
    assert Recurrence.monthly_modes_for(~D[2026-11-10]) == [:day_of_month, :nth_weekday]

    assert Recurrence.monthly_modes_for(~D[2026-11-27]) ==
             [:day_of_month, :nth_weekday, :last_weekday]

    assert Recurrence.monthly_modes_for(~D[2026-11-30]) == [:day_of_month, :last_weekday]
  end
end
