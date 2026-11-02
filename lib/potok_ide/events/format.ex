defmodule PotokIde.Events.Format do
  @moduledoc """
  Dates, times and repeat rules of events as text in the current Gettext
  locale, for the calendar and for notifications. Times are shown in 24-hour
  format; date patterns are translated whole, so each language orders the
  day and month its own way.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Events.{Event, Occurrence, Recurrence}

  def month_name(1), do: dgettext("events", "January")
  def month_name(2), do: dgettext("events", "February")
  def month_name(3), do: dgettext("events", "March")
  def month_name(4), do: dgettext("events", "April")
  def month_name(5), do: dgettext("events", "May")
  def month_name(6), do: dgettext("events", "June")
  def month_name(7), do: dgettext("events", "July")
  def month_name(8), do: dgettext("events", "August")
  def month_name(9), do: dgettext("events", "September")
  def month_name(10), do: dgettext("events", "October")
  def month_name(11), do: dgettext("events", "November")
  def month_name(12), do: dgettext("events", "December")

  def month_short(1), do: dgettext("events", "Jan")
  def month_short(2), do: dgettext("events", "Feb")
  def month_short(3), do: dgettext("events", "Mar")
  def month_short(4), do: dgettext("events", "Apr")
  def month_short(5), do: dpgettext("events", "short month", "May")
  def month_short(6), do: dgettext("events", "Jun")
  def month_short(7), do: dgettext("events", "Jul")
  def month_short(8), do: dgettext("events", "Aug")
  def month_short(9), do: dgettext("events", "Sep")
  def month_short(10), do: dgettext("events", "Oct")
  def month_short(11), do: dgettext("events", "Nov")
  def month_short(12), do: dgettext("events", "Dec")

  def weekday_name(1), do: dgettext("events", "Monday")
  def weekday_name(2), do: dgettext("events", "Tuesday")
  def weekday_name(3), do: dgettext("events", "Wednesday")
  def weekday_name(4), do: dgettext("events", "Thursday")
  def weekday_name(5), do: dgettext("events", "Friday")
  def weekday_name(6), do: dgettext("events", "Saturday")
  def weekday_name(7), do: dgettext("events", "Sunday")

  def weekday_short(1), do: dgettext("events", "Mon")
  def weekday_short(2), do: dgettext("events", "Tue")
  def weekday_short(3), do: dgettext("events", "Wed")
  def weekday_short(4), do: dgettext("events", "Thu")
  def weekday_short(5), do: dgettext("events", "Fri")
  def weekday_short(6), do: dgettext("events", "Sat")
  def weekday_short(7), do: dgettext("events", "Sun")

  @doc "\"November 2026\", the title of a month."
  def month_year(year, month) do
    dgettext("events", "%{month} %{year}", month: month_name(month), year: year)
  end

  @doc "\"Nov 7\""
  def day_month(%Date{} = date) do
    dgettext("events", "%{month} %{day}", month: month_short(date.month), day: date.day)
  end

  @doc "\"Fri, Nov 7\", with the year when it is not `today`'s."
  def date(%Date{} = date, %Date{} = today) do
    if date.year == today.year do
      dgettext("events", "%{weekday}, %{month} %{day}",
        weekday: weekday_short(Date.day_of_week(date)),
        month: month_short(date.month),
        day: date.day
      )
    else
      dgettext("events", "%{weekday}, %{month} %{day}, %{year}",
        weekday: weekday_short(Date.day_of_week(date)),
        month: month_short(date.month),
        day: date.day,
        year: date.year
      )
    end
  end

  @doc "\"18:00\""
  def time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  def time(%DateTime{} = datetime), do: datetime |> DateTime.to_time() |> time()

  def time(%DateTime{} = datetime, zone), do: datetime |> DateTime.shift_zone!(zone) |> time()

  @doc """
  When an occurrence is, in `zone` (all-day ones in the event's own zone):
  "Fri, Nov 7 · 18:00–19:30", "Fri, Nov 7 18:00 – Sat, Nov 8 02:00",
  "Fri, Nov 7" or "Fri, Nov 7 – Sun, Nov 9".
  """
  def occurrence(%Occurrence{event: %Event{all_day: true} = event} = occurrence, _zone, today) do
    last_day = Date.add(Recurrence.local_date(occurrence.ends_at, event.time_zone), -1)

    if Date.compare(last_day, occurrence.date) == :gt do
      dgettext("events", "%{start} – %{end}",
        start: date(occurrence.date, today),
        end: date(last_day, today)
      )
    else
      date(occurrence.date, today)
    end
  end

  def occurrence(%Occurrence{} = occurrence, zone, today) do
    starts_at = DateTime.shift_zone!(occurrence.starts_at, zone)
    ends_at = DateTime.shift_zone!(occurrence.ends_at, zone)
    start_date = DateTime.to_date(starts_at)
    end_date = DateTime.to_date(ends_at)

    cond do
      occurrence.starts_at == occurrence.ends_at ->
        dgettext("events", "%{date} · %{time}",
          date: date(start_date, today),
          time: time(starts_at)
        )

      start_date == end_date ->
        dgettext("events", "%{date} · %{start}–%{end}",
          date: date(start_date, today),
          start: time(starts_at),
          end: time(ends_at)
        )

      true ->
        dgettext("events", "%{start} – %{end}",
          start: "#{date(start_date, today)} #{time(starts_at)}",
          end: "#{date(end_date, today)} #{time(ends_at)}"
        )
    end
  end

  @doc "How often the event repeats, or nil for a one-off event."
  def recurrence(%Event{recurrence: :none}), do: nil

  def recurrence(%Event{} = event) do
    rule = rule(event, Recurrence.start_date(event))

    case event.recurrence_until do
      nil ->
        rule

      until ->
        dgettext("events", "%{rule}, until %{date}",
          rule: rule,
          date: date(until, Recurrence.start_date(event))
        )
    end
  end

  defp rule(%Event{recurrence: :daily, recurrence_interval: 1}, _start),
    do: dgettext("events", "Every day")

  defp rule(%Event{recurrence: :daily, recurrence_interval: n}, _start),
    do: dngettext("events", "Every %{count} day", "Every %{count} days", n)

  defp rule(%Event{recurrence: :weekly} = event, start) do
    days =
      case event.recurrence_weekdays do
        [] -> [Date.day_of_week(start)]
        days -> days
      end
      |> Enum.map_join(", ", &weekday_short/1)

    case event.recurrence_interval do
      1 ->
        dgettext("events", "Every week on %{days}", days: days)

      n ->
        dngettext(
          "events",
          "Every %{count} week on %{days}",
          "Every %{count} weeks on %{days}",
          n,
          days: days
        )
    end
  end

  defp rule(%Event{recurrence: :monthly} = event, start) do
    day = monthly_day(event.recurrence_monthly, start)

    case event.recurrence_interval do
      1 ->
        dgettext("events", "Every month on %{day}", day: day)

      n ->
        dngettext(
          "events",
          "Every %{count} month on %{day}",
          "Every %{count} months on %{day}",
          n,
          day: day
        )
    end
  end

  defp rule(%Event{recurrence: :yearly} = event, start) do
    case event.recurrence_interval do
      1 ->
        dgettext("events", "Every year on %{date}", date: day_month(start))

      n ->
        dngettext(
          "events",
          "Every %{count} year on %{date}",
          "Every %{count} years on %{date}",
          n,
          date: day_month(start)
        )
    end
  end

  @doc """
  The day a monthly event repeats on, for a start date: "day 31",
  "the 2nd Tuesday", "the last Friday".
  """
  def monthly_day(:day_of_month, %Date{day: day}),
    do: dgettext("events", "day %{day}", day: day)

  def monthly_day(:nth_weekday, %Date{} = start) do
    dgettext("events", "the %{ordinal} %{weekday}",
      ordinal: ordinal(Recurrence.week_of_month(start)),
      weekday: weekday_name(Date.day_of_week(start))
    )
  end

  def monthly_day(:last_weekday, %Date{} = start), do: last_weekday(Date.day_of_week(start))

  defp ordinal(1), do: dgettext("events", "1st")
  defp ordinal(2), do: dgettext("events", "2nd")
  defp ordinal(3), do: dgettext("events", "3rd")
  defp ordinal(4), do: dgettext("events", "4th")

  # Whole phrases, since in some languages "last" agrees with the weekday.
  defp last_weekday(1), do: dgettext("events", "the last Monday")
  defp last_weekday(2), do: dgettext("events", "the last Tuesday")
  defp last_weekday(3), do: dgettext("events", "the last Wednesday")
  defp last_weekday(4), do: dgettext("events", "the last Thursday")
  defp last_weekday(5), do: dgettext("events", "the last Friday")
  defp last_weekday(6), do: dgettext("events", "the last Saturday")
  defp last_weekday(7), do: dgettext("events", "the last Sunday")

  @doc "A reminder choice: \"15 minutes before\", \"1 day before\", \"At 09:00 on the day\"."
  def reminder(0, true = _all_day?), do: dgettext("events", "At 09:00 on the day")
  def reminder(0, _all_day?), do: dgettext("events", "When it starts")

  def reminder(minutes, _all_day?) when rem(minutes, 1440) == 0 do
    days = div(minutes, 1440)

    if days == 7,
      do: dgettext("events", "1 week before"),
      else: dngettext("events", "%{count} day before", "%{count} days before", days)
  end

  def reminder(minutes, _all_day?) when rem(minutes, 60) == 0,
    do: dngettext("events", "%{count} hour before", "%{count} hours before", div(minutes, 60))

  def reminder(minutes, _all_day?),
    do: dngettext("events", "%{count} minute before", "%{count} minutes before", minutes)
end
