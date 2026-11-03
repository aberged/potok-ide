defmodule PotokIde.Events.Event do
  @moduledoc """
  An event in a group's calendar, once or repeating.

  `starts_at` and `ends_at` are the first occurrence. Repeats keep its
  wall-clock time in `time_zone` (see `PotokIde.Events.Recurrence`), so an
  occurrence is named by its local start date. An all-day event starts and
  ends at local midnight; `ends_at` is the midnight after its last day.

  `reminder_minutes` are the organizer's reminders, before the start of a
  timed occurrence or before 09:00 on the day of an all-day one. Members can
  pick their own (`PotokIde.Events.MemberSetting`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Events.Recurrence

  @recurrences [:none, :daily, :weekly, :monthly, :yearly]
  @monthly_modes [:day_of_month, :nth_weekday, :last_weekday]

  @timed_reminder_minutes [0, 5, 15, 30, 60, 120, 1440, 2880, 10080]
  @all_day_reminder_minutes [0, 1440, 2880, 10080]
  @max_reminders 5
  @max_excluded_dates 200
  @max_duration_days 31

  schema "group_events" do
    field :title, :string
    field :description, :string, default: ""
    field :location, :string, default: ""
    field :all_day, :boolean, default: false
    # Seen by every profile, not only the group's members; set by those with
    # `publish_events` (`PotokIde.Events` drops the change for others).
    field :is_public, :boolean, default: false
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :time_zone, :string

    field :recurrence, Ecto.Enum, values: @recurrences, default: :none
    field :recurrence_interval, :integer, default: 1
    # ISO weekdays (1 = Monday) of a weekly event, always with the start's.
    field :recurrence_weekdays, {:array, :integer}, default: []
    # Which day a monthly event repeats on; the nth or last weekday is the
    # one of the start date.
    field :recurrence_monthly, Ecto.Enum, values: @monthly_modes, default: :day_of_month
    # The last local date an occurrence may start on.
    field :recurrence_until, :date
    # Single occurrences that were cancelled, by local start date.
    field :excluded_dates, {:array, :date}, default: []

    field :reminder_minutes, {:array, :integer}, default: []
    # Set by `PotokIde.Events.Reminders`, never cast: reminders up to
    # `reminded_through` are handled, and the next one is due at
    # `next_reminder_at` (nil when there is none).
    field :reminded_through, :utc_datetime
    field :next_reminder_at, :utc_datetime

    field :cancelled_at, :utc_datetime
    # Raised when the schedule changes, so calendar apps replace an imported copy.
    field :sequence, :integer, default: 0

    # The form edits local dates and times in `time_zone`.
    field :start_date, :date, virtual: true
    field :start_time, :time, virtual: true
    field :end_date, :date, virtual: true
    field :end_time, :time, virtual: true
    # The tags the viewing profile sees (`PotokIde.Tags.put_tags/3`): the
    # public ones and its own private ones.
    field :tags, {:array, :any}, virtual: true, default: []

    belongs_to :group, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile
    # The chat value that announced the event.
    belongs_to :value, PotokIde.Social.Value

    timestamps(type: :utc_datetime)
  end

  def recurrences, do: @recurrences
  def monthly_modes, do: @monthly_modes
  def max_reminders, do: @max_reminders
  def max_excluded_dates, do: @max_excluded_dates

  def reminder_choices(%__MODULE__{all_day: true}), do: @all_day_reminder_minutes
  def reminder_choices(%__MODULE__{}), do: @timed_reminder_minutes

  def cancelled?(%__MODULE__{cancelled_at: cancelled_at}), do: not is_nil(cancelled_at)

  def recurring?(%__MODULE__{recurrence: recurrence}), do: recurrence != :none

  @doc """
  Fills the form fields from `starts_at` and `ends_at`, in the event's zone.
  The end date of an all-day event is its last day.
  """
  def with_form_fields(%__MODULE__{starts_at: %DateTime{} = starts_at} = event) do
    local_start = DateTime.shift_zone!(starts_at, event.time_zone)
    local_end = DateTime.shift_zone!(event.ends_at, event.time_zone)

    end_date =
      if event.all_day,
        do: Date.add(DateTime.to_date(local_end), -1),
        else: DateTime.to_date(local_end)

    %{
      event
      | start_date: DateTime.to_date(local_start),
        start_time: local_start |> DateTime.to_time() |> Time.truncate(:second),
        end_date: end_date,
        end_time: local_end |> DateTime.to_time() |> Time.truncate(:second)
    }
  end

  def with_form_fields(%__MODULE__{} = event), do: event

  @doc """
  The form changeset. `time_zone` is the viewer's: a new event takes it, an
  existing one keeps its own, and the form's dates and times are read in
  that zone. `group_id`, `creator_id` and the reminder fields are set by the
  caller, never cast.
  """
  def changeset(%__MODULE__{} = event, attrs, time_zone) do
    attrs = normalize_list_attrs(attrs)

    event
    |> with_form_fields()
    |> change(time_zone: event.time_zone || time_zone)
    |> cast(attrs, [
      :title,
      :description,
      :location,
      :all_day,
      :is_public,
      :start_date,
      :start_time,
      :end_date,
      :end_time,
      :recurrence,
      :recurrence_interval,
      :recurrence_weekdays,
      :recurrence_monthly,
      :recurrence_until,
      :reminder_minutes
    ])
    |> update_change(:title, &trim/1)
    |> update_change(:location, &trim/1)
    |> put_blank(:description)
    |> put_blank(:location)
    |> validate_required([:title, :start_date])
    |> validate_length(:title, max: 200)
    |> validate_length(:location, max: 300)
    |> validate_length(:description, max: 5000)
    |> validate_start_time()
    |> put_default_end()
    |> put_instants()
    |> validate_recurrence()
    |> validate_reminders()
    |> check_constraint(:ends_at, name: :group_events_ends_after_start)
  end

  @doc "Cancels the single occurrence on `date`."
  def exclude_date_changeset(%__MODULE__{} = event, %Date{} = date) do
    excluded = Enum.sort(Enum.uniq([date | event.excluded_dates]), Date)

    event
    |> change(excluded_dates: excluded)
    |> validate_length(:excluded_dates, max: @max_excluded_dates)
  end

  # Checkbox groups send a hidden "" so that clearing every box is a change.
  defp normalize_list_attrs(attrs) when is_map(attrs) do
    Enum.reduce(["recurrence_weekdays", "reminder_minutes"], attrs, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, values} when is_list(values) -> Map.put(acc, key, Enum.reject(values, &(&1 == "")))
        _ -> acc
      end
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # The columns are NOT NULL, and casting "" yields nil.
  defp put_blank(changeset, field) do
    if get_field(changeset, field) == nil,
      do: put_change(changeset, field, ""),
      else: changeset
  end

  defp validate_start_time(changeset) do
    if get_field(changeset, :all_day),
      do: changeset,
      else: validate_required(changeset, [:start_time])
  end

  # A missing end is the start day, an hour after the start.
  defp put_default_end(changeset) do
    start_date = get_field(changeset, :start_date)
    start_time = get_field(changeset, :start_time)

    changeset =
      if get_field(changeset, :end_date) == nil and start_date,
        do: put_change(changeset, :end_date, start_date),
        else: changeset

    if get_field(changeset, :end_time) == nil and start_time and
         not get_field(changeset, :all_day) do
      {end_time, days} = add_hour(start_time)

      changeset
      |> put_change(:end_time, end_time)
      |> update_change(:end_date, &(&1 && Date.add(&1, days)))
    else
      changeset
    end
  end

  defp add_hour(time) do
    seconds = Time.diff(time, ~T[00:00:00]) + 3600
    {Time.add(~T[00:00:00], rem(seconds, 86_400)), div(seconds, 86_400)}
  end

  defp put_instants(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_instants(changeset) do
    zone = get_field(changeset, :time_zone)
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    {starts_at, ends_at} =
      if get_field(changeset, :all_day) do
        {Recurrence.to_utc(start_date, ~T[00:00:00], zone),
         Recurrence.to_utc(Date.add(end_date, 1), ~T[00:00:00], zone)}
      else
        {Recurrence.to_utc(start_date, get_field(changeset, :start_time), zone),
         Recurrence.to_utc(end_date, get_field(changeset, :end_time), zone)}
      end

    cond do
      DateTime.compare(ends_at, starts_at) == :lt ->
        add_error(changeset, end_field(changeset), "must not be before the start")

      DateTime.diff(ends_at, starts_at) > @max_duration_days * 86_400 ->
        add_error(changeset, :end_date, "must be at most %{count} days after the start",
          count: @max_duration_days
        )

      true ->
        changeset
        |> put_change(:starts_at, starts_at)
        |> put_change(:ends_at, ends_at)
    end
  end

  defp end_field(changeset) do
    if get_field(changeset, :all_day) or
         get_field(changeset, :end_date) != get_field(changeset, :start_date),
       do: :end_date,
       else: :end_time
  end

  defp validate_recurrence(changeset) do
    case get_field(changeset, :recurrence) do
      :none ->
        changeset
        |> put_change(:recurrence_weekdays, [])
        |> put_change(:recurrence_until, nil)

      recurrence ->
        changeset
        |> validate_required([:recurrence_interval])
        |> validate_number(:recurrence_interval,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: 99
        )
        |> put_weekdays(recurrence)
        |> validate_monthly_mode(recurrence)
        |> validate_until()
    end
  end

  # A weekly event always repeats on the weekday it starts on, so the start
  # is its first occurrence (calendar apps expect DTSTART to match the rule).
  defp put_weekdays(changeset, :weekly) do
    case get_field(changeset, :start_date) do
      %Date{} = start_date ->
        weekdays = get_field(changeset, :recurrence_weekdays) || []

        if Enum.all?(weekdays, &(&1 in 1..7)) do
          days = Enum.sort(Enum.uniq([Date.day_of_week(start_date) | weekdays]))
          put_change(changeset, :recurrence_weekdays, days)
        else
          add_error(changeset, :recurrence_weekdays, "is invalid")
        end

      nil ->
        changeset
    end
  end

  defp put_weekdays(changeset, _recurrence), do: put_change(changeset, :recurrence_weekdays, [])

  defp validate_monthly_mode(changeset, :monthly) do
    start_date = get_field(changeset, :start_date)
    mode = get_field(changeset, :recurrence_monthly)

    if start_date && mode not in Recurrence.monthly_modes_for(start_date),
      do: add_error(changeset, :recurrence_monthly, "does not match the start date"),
      else: changeset
  end

  defp validate_monthly_mode(changeset, _recurrence),
    do: put_change(changeset, :recurrence_monthly, :day_of_month)

  defp validate_until(changeset) do
    start_date = get_field(changeset, :start_date)
    until = get_field(changeset, :recurrence_until)

    if start_date && until && Date.compare(until, start_date) == :lt,
      do: add_error(changeset, :recurrence_until, "must not be before the start"),
      else: changeset
  end

  # Choices that do not fit are dropped, such as "5 minutes before" when an
  # event becomes all-day.
  defp validate_reminders(changeset) do
    choices =
      if get_field(changeset, :all_day),
        do: @all_day_reminder_minutes,
        else: @timed_reminder_minutes

    minutes =
      (get_field(changeset, :reminder_minutes) || [])
      |> Enum.filter(&(&1 in choices))
      |> Enum.uniq()
      |> Enum.sort()

    changeset
    |> put_change(:reminder_minutes, minutes)
    |> validate_length(:reminder_minutes, max: @max_reminders)
  end
end
