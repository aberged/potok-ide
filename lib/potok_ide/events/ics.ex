defmodule PotokIde.Events.ICS do
  @moduledoc """
  An event as an iCalendar file (RFC 5545), for "Add to my calendar".

  One-off timed events are written in UTC. Repeating timed events are
  written in the event's zone (`TZID`, without a VTIMEZONE block, which
  Google and Apple calendars accept), so their copies keep the wall-clock
  time across daylight saving changes like the original. All-day events use
  dates. `SEQUENCE` and the stable `UID` let a calendar replace an imported
  copy when the event changes or is cancelled.
  """

  alias PotokIde.Events.{Event, Recurrence}

  @weekdays %{1 => "MO", 2 => "TU", 3 => "WE", 4 => "TH", 5 => "FR", 6 => "SA", 7 => "SU"}

  @doc """
  The calendar file of `event`. Options: `:host` (for the UID), `:url` (a
  link back to the event) and `:now` (the time stamp).
  """
  def render(%Event{} = event, opts) do
    host = Keyword.fetch!(opts, :host)
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))

    [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Potok//Calendar//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:event-#{event.id}@#{host}",
      "DTSTAMP:#{utc(now)}",
      "SEQUENCE:#{event.sequence}",
      "SUMMARY:#{escape(event.title)}",
      event.description != "" && "DESCRIPTION:#{escape(event.description)}",
      event.location != "" && "LOCATION:#{escape(event.location)}",
      opts[:url] && "URL:#{opts[:url]}",
      times(event),
      rrule(event),
      exdate(event),
      "STATUS:#{if Event.cancelled?(event), do: "CANCELLED", else: "CONFIRMED"}",
      "END:VEVENT",
      "END:VCALENDAR"
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.map_join(&(fold(&1) <> "\r\n"))
  end

  defp times(%Event{all_day: true} = event) do
    [
      "DTSTART;VALUE=DATE:#{date(Recurrence.start_date(event))}",
      "DTEND;VALUE=DATE:#{date(Recurrence.local_date(event.ends_at, event.time_zone))}"
    ]
  end

  defp times(%Event{recurrence: :none} = event) do
    ["DTSTART:#{utc(event.starts_at)}", "DTEND:#{utc(event.ends_at)}"]
  end

  defp times(%Event{} = event) do
    [
      "DTSTART;TZID=#{event.time_zone}:#{local(event.starts_at, event.time_zone)}",
      "DTEND;TZID=#{event.time_zone}:#{local(event.ends_at, event.time_zone)}"
    ]
  end

  defp rrule(%Event{recurrence: :none}), do: nil

  defp rrule(%Event{} = event) do
    start = Recurrence.start_date(event)

    parts =
      [
        "FREQ=#{event.recurrence |> Atom.to_string() |> String.upcase()}",
        "INTERVAL=#{event.recurrence_interval}"
      ] ++ by_parts(event, start) ++ until_part(event)

    "RRULE:" <> Enum.join(parts, ";")
  end

  defp by_parts(%Event{recurrence: :weekly} = event, start) do
    days =
      case event.recurrence_weekdays do
        [] -> [Date.day_of_week(start)]
        days -> days
      end

    ["BYDAY=#{Enum.map_join(days, ",", &@weekdays[&1])}", "WKST=MO"]
  end

  defp by_parts(%Event{recurrence: :monthly, recurrence_monthly: :day_of_month}, start),
    do: ["BYMONTHDAY=#{start.day}"]

  defp by_parts(%Event{recurrence: :monthly, recurrence_monthly: :nth_weekday}, start),
    do: ["BYDAY=#{Recurrence.week_of_month(start)}#{@weekdays[Date.day_of_week(start)]}"]

  defp by_parts(%Event{recurrence: :monthly, recurrence_monthly: :last_weekday}, start),
    do: ["BYDAY=-1#{@weekdays[Date.day_of_week(start)]}"]

  defp by_parts(%Event{recurrence: :yearly}, start),
    do: ["BYMONTH=#{start.month}", "BYMONTHDAY=#{start.day}"]

  defp by_parts(%Event{}, _start), do: []

  # With a TZID start, UNTIL must be in UTC: the end of the last local date.
  defp until_part(%Event{recurrence_until: nil}), do: []
  defp until_part(%Event{all_day: true, recurrence_until: until}), do: ["UNTIL=#{date(until)}"]

  defp until_part(%Event{recurrence_until: until, time_zone: zone}),
    do: ["UNTIL=#{utc(Recurrence.to_utc(until, ~T[23:59:59], zone))}"]

  defp exdate(%Event{excluded_dates: []}), do: nil
  defp exdate(%Event{recurrence: :none}), do: nil

  defp exdate(%Event{all_day: true, excluded_dates: dates}),
    do: "EXDATE;VALUE=DATE:#{Enum.map_join(dates, ",", &date/1)}"

  defp exdate(%Event{excluded_dates: dates} = event) do
    times =
      Enum.map_join(dates, ",", fn date ->
        local(Recurrence.build(event, date).starts_at, event.time_zone)
      end)

    "EXDATE;TZID=#{event.time_zone}:#{times}"
  end

  defp utc(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp local(%DateTime{} = datetime, zone),
    do: datetime |> DateTime.shift_zone!(zone) |> Calendar.strftime("%Y%m%dT%H%M%S")

  defp date(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(~r/\r\n|\r|\n/, "\\n")
  end

  # Lines longer than 75 octets continue on lines that start with a space,
  # never inside a UTF-8 character.
  defp fold(line) when byte_size(line) <= 75, do: line

  defp fold(line) do
    {chunks, current} =
      line
      |> String.codepoints()
      |> Enum.reduce({[], ""}, fn char, {chunks, current} ->
        # Continuation lines lose one octet to the leading space.
        limit = if chunks == [], do: 75, else: 74

        if byte_size(current) + byte_size(char) > limit,
          do: {[current | chunks], char},
          else: {chunks, current <> char}
      end)

    [current | chunks] |> Enum.reverse() |> Enum.join("\r\n ")
  end
end
