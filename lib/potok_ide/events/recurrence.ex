defmodule PotokIde.Events.Recurrence do
  @moduledoc """
  The occurrences of an event. The rules are the ones of RFC 5545 that the
  calendar offers, so an exported RRULE yields the same dates:

    * daily: every `recurrence_interval` days
    * weekly: on `recurrence_weekdays` of every n-th week, weeks starting on
      Monday from the week of the start date
    * monthly: on the start's day of the month (months without that day are
      skipped), or on the start's nth or last weekday (2nd Tuesday, last Friday)
    * yearly: on the start's month and day (Feb 29 only in leap years)

  Dates are computed in the event's zone and each occurrence keeps the
  wall-clock start of the first one. A local time that does not exist (the
  spring-forward gap) moves to the end of the gap, and one that happens twice
  takes the earlier instant. Timed occurrences last as many seconds as the
  first one, all-day ones as many days.
  """

  alias PotokIde.Events.{Event, Occurrence}

  # How many periods (days, weeks, months or years) in a row may have no date
  # before a search gives up; only an impossible rule gets that far.
  @max_empty_periods 2_000

  @doc """
  The UTC instant of a local date and time in `zone`.
  """
  def to_utc(%Date{} = date, %Time{} = time, zone) when is_binary(zone) do
    naive = NaiveDateTime.new!(date, Time.truncate(time, :second))

    local =
      case DateTime.from_naive(naive, zone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, after_gap} -> after_gap
      end

    local |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  def local_date(%DateTime{} = datetime, zone) when is_binary(zone) do
    datetime |> DateTime.shift_zone!(zone) |> DateTime.to_date()
  end

  @doc "The local date of the event's first occurrence."
  def start_date(%Event{} = event), do: local_date(event.starts_at, event.time_zone)

  @doc """
  The monthly rules a start date allows: its day of the month, its nth
  weekday when that is one of the first four, and its last weekday when it
  falls in the month's last seven days.
  """
  def monthly_modes_for(%Date{} = date) do
    [
      :day_of_month,
      week_of_month(date) <= 4 && :nth_weekday,
      last_week_of_month?(date) && :last_weekday
    ]
    |> Enum.filter(& &1)
  end

  @doc "Which occurrence of its weekday in the month a date is (1 to 5)."
  def week_of_month(%Date{day: day}), do: div(day - 1, 7) + 1

  def last_week_of_month?(%Date{} = date), do: date.day + 7 > Date.days_in_month(date)

  @doc """
  The local start dates of the event's occurrences on or after `from`, in
  order, as a lazy stream. Cancelled dates are left out, and the stream ends
  after `recurrence_until` (or after the only date of a one-off event).
  """
  def dates_from(%Event{recurrence: :none} = event, %Date{} = from) do
    first = start_date(event)

    if Date.compare(first, from) != :lt and first not in event.excluded_dates,
      do: [first],
      else: []
  end

  def dates_from(%Event{} = event, %Date{} = from) do
    first = start_date(event)
    from = Enum.max([from, first], Date)
    excluded = MapSet.new(event.excluded_dates)

    event
    |> first_period(first, from)
    |> Stream.iterate(&(&1 + 1))
    |> Stream.transform(0, fn period, empty ->
      case period_dates(event, first, period) do
        [] when empty >= @max_empty_periods -> {:halt, empty}
        [] -> {[], empty + 1}
        dates -> {dates, 0}
      end
    end)
    |> Stream.filter(&(Date.compare(&1, from) != :lt))
    |> take_until(event.recurrence_until)
    |> Stream.reject(&MapSet.member?(excluded, &1))
  end

  @doc "Whether the event has an occurrence starting on the local `date`."
  def occurs_on?(%Event{} = event, %Date{} = date) do
    event |> dates_from(date) |> Enum.take(1) == [date]
  end

  @doc "The occurrence starting on the local `date`, or nil."
  def occurrence(%Event{} = event, %Date{} = date) do
    if occurs_on?(event, date), do: build(event, date)
  end

  @doc """
  The occurrences that overlap `[from, to)`. An occurrence without length
  counts when it starts in the window.
  """
  def occurrences(%Event{} = event, %DateTime{} = from, %DateTime{} = to) do
    zone = event.time_zone
    span = DateTime.diff(event.ends_at, event.starts_at)
    # A day of margin on each side covers zone offsets and DST changes.
    from_date = local_date(DateTime.add(from, -(span + 86_400)), zone)
    to_date = local_date(DateTime.add(to, 86_400), zone)

    event
    |> dates_from(from_date)
    |> Stream.take_while(&(Date.compare(&1, to_date) != :gt))
    |> Stream.map(&build(event, &1))
    |> Enum.filter(&overlaps?(&1, from, to))
  end

  @doc """
  The first occurrence starting on or after the local `from` for which `fun`
  holds. `fun` must turn true at some point and stay true (say, a start after
  an instant), or a series without end is searched forever.
  """
  def find(%Event{} = event, %Date{} = from, fun) when is_function(fun, 1) do
    event
    |> dates_from(from)
    |> Stream.map(&build(event, &1))
    |> Enum.find(fun)
  end

  @doc "The first occurrence that starts after `instant`, or nil."
  def next_occurrence_after(%Event{} = event, %DateTime{} = instant) do
    span = DateTime.diff(event.ends_at, event.starts_at)
    from = local_date(DateTime.add(instant, -(span + 86_400)), event.time_zone)

    find(event, from, &(DateTime.compare(&1.starts_at, instant) == :gt))
  end

  @doc "The occurrence on a local date the caller knows is part of the series."
  def build(%Event{} = event, %Date{} = date) do
    first = start_date(event)
    zone = event.time_zone

    {starts_at, ends_at} =
      cond do
        # The stored instants, even when the local start is ambiguous.
        date == first ->
          {event.starts_at, event.ends_at}

        event.all_day ->
          days = Date.diff(local_date(event.ends_at, zone), first)
          {to_utc(date, ~T[00:00:00], zone), to_utc(Date.add(date, days), ~T[00:00:00], zone)}

        true ->
          time = event.starts_at |> DateTime.shift_zone!(zone) |> DateTime.to_time()
          starts_at = to_utc(date, time, zone)
          {starts_at, DateTime.add(starts_at, DateTime.diff(event.ends_at, event.starts_at))}
      end

    %Occurrence{event: event, date: date, starts_at: starts_at, ends_at: ends_at}
  end

  defp overlaps?(%Occurrence{starts_at: starts_at, ends_at: ends_at}, from, to) do
    DateTime.compare(starts_at, to) == :lt and
      (DateTime.compare(ends_at, from) == :gt or
         (starts_at == ends_at and DateTime.compare(starts_at, from) != :lt))
  end

  defp take_until(dates, nil), do: dates
  defp take_until(dates, until), do: Stream.take_while(dates, &(Date.compare(&1, until) != :gt))

  # The period that holds `from`, found by arithmetic so that a series which
  # started years ago is not walked from its start.
  defp first_period(%Event{recurrence: :daily} = event, first, from),
    do: div(Date.diff(from, first), event.recurrence_interval)

  defp first_period(%Event{recurrence: :weekly} = event, first, from),
    do: div(Date.diff(from, week_start(first)), 7 * event.recurrence_interval)

  defp first_period(%Event{recurrence: :monthly} = event, first, from),
    do: div(month_index(from) - month_index(first), event.recurrence_interval)

  defp first_period(%Event{recurrence: :yearly} = event, first, from),
    do: div(from.year - first.year, event.recurrence_interval)

  defp period_dates(%Event{recurrence: :daily} = event, first, period) do
    [Date.add(first, period * event.recurrence_interval)]
  end

  defp period_dates(%Event{recurrence: :weekly} = event, first, period) do
    week = Date.add(week_start(first), 7 * period * event.recurrence_interval)

    weekdays =
      case event.recurrence_weekdays do
        [] -> [Date.day_of_week(first)]
        weekdays -> Enum.sort(weekdays)
      end

    weekdays
    |> Enum.map(&Date.add(week, &1 - 1))
    |> Enum.filter(&(Date.compare(&1, first) != :lt))
  end

  defp period_dates(%Event{recurrence: :monthly} = event, first, period) do
    {year, month} = add_months(first, period * event.recurrence_interval)
    monthly_date(event.recurrence_monthly, first, year, month)
  end

  defp period_dates(%Event{recurrence: :yearly} = event, first, period) do
    case Date.new(first.year + period * event.recurrence_interval, first.month, first.day) do
      {:ok, date} -> [date]
      {:error, _reason} -> []
    end
  end

  defp monthly_date(:day_of_month, first, year, month) do
    case Date.new(year, month, first.day) do
      {:ok, date} -> [date]
      {:error, _reason} -> []
    end
  end

  defp monthly_date(:nth_weekday, first, year, month) do
    month_start = Date.new!(year, month, 1)
    offset = Integer.mod(Date.day_of_week(first) - Date.day_of_week(month_start), 7)
    date = Date.add(month_start, offset + 7 * (week_of_month(first) - 1))

    if date.month == month, do: [date], else: []
  end

  defp monthly_date(:last_weekday, first, year, month) do
    month_end = Date.new!(year, month, Date.days_in_month(Date.new!(year, month, 1)))
    offset = Integer.mod(Date.day_of_week(month_end) - Date.day_of_week(first), 7)

    [Date.add(month_end, -offset)]
  end

  defp week_start(date), do: Date.add(date, 1 - Date.day_of_week(date))

  defp month_index(%Date{year: year, month: month}), do: year * 12 + month - 1

  defp add_months(%Date{} = date, months) do
    index = month_index(date) + months
    {div(index, 12), rem(index, 12) + 1}
  end
end
