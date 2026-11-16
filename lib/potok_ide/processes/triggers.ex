defmodule PotokIde.Processes.Triggers do
  @moduledoc """
  What sets a process drawn in Potok going (`AppProcess.trigger`), and its
  settings (`AppProcess.trigger_config`):

  - `"value"`: a new value of an app's collection, as for an app's own
    process. It has no settings: the collection says it all.
  - `"message"`: a chat message a person writes in the group, not a reply in
    a thread, that holds one of `words` (whole words, in any case) or
    mentions the `role`. One of the two is required, or every message would
    start it.
  - `"subgroup"`: a sub-group made in the group one at a time (a form, a
    preset, a place on the map, an app's `createChild`), with a place on the
    map when `placed`. Records, threads, an app's file groups and what a
    process makes start nothing.
  - `"schedule"`: every day, every week on `weekdays` (1 is Monday) or every
    month on `day` (1..28 or `"last"`), at `time` in `time_zone`.
  - `"manual"`: someone holding one of `roles` starts it from the group's
    Processes tab, with a title and a text.
  - `"process"`: another process drawn in the group calls it
    (`callActivity`), handing over the `fields` it names.
  - `"signal"`: a process drawn in the group sends the signal `name`, and
    what it carries becomes the run's fields.

  Each gives its texts and conditions fields (`fields/2`): a message's
  `text`, a sub-group's `name`, the `title` of a form, a scheduled `date`,
  the fields a call hands over and the name of the process that called
  (`from`).
  """

  alias PotokIde.Events.Recurrence
  alias PotokIde.Social.Value

  @triggers ~w(value message subgroup schedule manual process signal)
  @max_words 10
  @max_fields 10
  @field_format ~r/^[\p{L}\p{Nd}_-]{1,40}$/u
  # What a run another process started always gets: who started it.
  @reserved ~w(from outcome)
  @word_length 2..40
  @every ~w(day week month)
  @time_format ~r/^([01]\d|2[0-3]):([0-5]\d)$/
  # How far ahead a schedule is searched: a month and a bit always holds one.
  @search_days 400

  @doc "Every trigger, in the order the editor offers them."
  def all, do: @triggers

  @doc """
  The settings of a trigger as Potok keeps them, or `{:error, {path, reason}}`
  with the path counted from the settings, such as `{"words", :invalid}`.
  """
  def normalize("value", _config), do: {:ok, %{}}

  def normalize("message", config) when is_map(config) do
    with {:ok, words} <- words(config["words"]),
         {:ok, role} <- optional_key(config["role"], "role") do
      if words == [] and role == nil,
        do: {:error, {"words", :empty}},
        else: {:ok, %{"words" => words, "role" => role}}
    end
  end

  def normalize("subgroup", config) when is_map(config),
    do: {:ok, %{"placed" => config["placed"] in [true, "true"]}}

  def normalize("schedule", config) when is_map(config) do
    with {:ok, every} <- member(config["every"], @every, "every"),
         {:ok, time} <- time(config["time"]),
         {:ok, zone} <- zone(config["time_zone"]),
         {:ok, weekdays} <- weekdays(every, config["weekdays"]),
         {:ok, day} <- month_day(every, config["day"]) do
      {:ok,
       %{
         "every" => every,
         "time" => time,
         "time_zone" => zone,
         "weekdays" => weekdays,
         "day" => day
       }}
    end
  end

  def normalize("manual", config) when is_map(config) do
    with {:ok, roles} <- keys(config["roles"], "roles") do
      {:ok, %{"roles" => if(roles == [], do: ["everyone"], else: roles)}}
    end
  end

  def normalize("process", config) when is_map(config) do
    with {:ok, fields} <- field_names(config["fields"]) do
      {:ok, %{"fields" => fields}}
    end
  end

  def normalize("signal", config) when is_map(config) do
    case PotokIde.Processes.Graph.signal_name(config["name"]) do
      {:ok, name} -> {:ok, %{"name" => name}}
      :error -> {:error, {"name", :invalid}}
    end
  end

  def normalize(trigger, _config) when trigger in @triggers, do: normalize(trigger, %{})
  def normalize(_trigger, _config), do: {:error, {"", :invalid}}

  @doc "The role keys the settings name, which must be the group's."
  def role_refs("message", %{"role" => role}) when is_binary(role), do: [{"role", role}]

  def role_refs("manual", %{"roles" => roles}),
    do: for({role, i} <- Enum.with_index(roles), do: {"roles.#{i}", role})

  def role_refs(_trigger, _config), do: []

  @doc """
  The fields a trigger with its settings gives its texts and conditions, as
  `{{field}}`.
  """
  def fields(trigger, config \\ %{})
  def fields("message", _config), do: ~w(text author)
  def fields("subgroup", _config), do: ~w(name description author)
  def fields("schedule", _config), do: ~w(date time)
  def fields("manual", _config), do: ~w(title text author)
  def fields("process", %{"fields" => fields}) when is_list(fields), do: fields ++ ["from"]
  def fields("process", _config), do: ["from"]
  def fields("signal", _config), do: ["from"]
  def fields(_trigger, _config), do: []

  @doc """
  The type of what a trigger with its settings hands a run, which a process
  drawn in today's language reads under the id of its start
  (`PotokIde.Processes.Scope`). A value of a collection and a signal may
  hold more than Potok knows of.
  """
  def entry(trigger, config \\ %{})
  def entry("value", _config), do: {:record, %{}, true}
  def entry("signal", _config), do: {:record, %{"from" => :text, "signal" => :text}, true}
  def entry(trigger, config), do: {:record, Map.new(fields(trigger, config), &{&1, :text}), false}

  # ---------
  # Messages
  # ---------

  @doc """
  Whether a chat message sets the process going: one of its words in the
  text, or its role mentioned. `role_keys` maps the lowercase role names a
  message mentions to the group's role keys.
  """
  def matches_message?(%{"words" => words, "role" => role}, %Value{} = value, role_keys) do
    text = String.downcase(value.content || "")
    tokens = MapSet.new(Regex.scan(~r/[\p{L}\p{Nd}]+/u, text) |> List.flatten())

    word? = Enum.any?(words, &MapSet.member?(tokens, &1))

    role? =
      is_binary(role) and
        Enum.any?(
          get_in(value.mentions || %{}, ["roles"]) || [],
          &(Map.get(role_keys, &1) == role)
        )

    word? or role?
  end

  def matches_message?(_config, _value, _role_keys), do: false

  # ---------
  # Schedules
  # ---------

  @doc """
  When a schedule starts next after `instant`, a UTC instant. A local time that
  does not exist on a day (the spring-forward gap) moves to the end of the
  gap, as the calendar's does (`Events.Recurrence.to_utc/3`).
  """
  def next_run(
        %{"every" => _, "time" => time, "time_zone" => zone} = config,
        %DateTime{} = instant
      ) do
    time = Time.from_iso8601!(time <> ":00")
    first = Recurrence.local_date(instant, zone)

    0..@search_days
    |> Stream.map(&Date.add(first, &1))
    |> Stream.filter(&on_day?(config, &1))
    |> Stream.map(&Recurrence.to_utc(&1, time, zone))
    |> Enum.find(&(DateTime.compare(&1, instant) == :gt))
  end

  def next_run(_config, _instant), do: nil

  defp on_day?(%{"every" => "day"}, _date), do: true
  defp on_day?(%{"every" => "week", "weekdays" => days}, date), do: Date.day_of_week(date) in days

  defp on_day?(%{"every" => "month", "day" => "last"}, date),
    do: date.day == Date.days_in_month(date)

  defp on_day?(%{"every" => "month", "day" => day}, date), do: date.day == day

  @doc "The local date and time a scheduled run was due, as its fields."
  def schedule_data(%{"time_zone" => zone}, %DateTime{} = due) do
    local = DateTime.shift_zone!(due, zone)

    %{
      "date" => Calendar.strftime(local, "%d. %m. %Y."),
      "time" => Calendar.strftime(local, "%H:%M")
    }
  end

  # ---------
  # Checks
  # ---------

  defp words(nil), do: {:ok, []}

  defp words(text) when is_binary(text), do: text |> String.split(~r/[,\n]/) |> words()

  defp words(list) when is_list(list) do
    words =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("#") |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(words) > @max_words ->
        {:error, {"words", :too_many}}

      Enum.any?(words, &(String.length(&1) not in @word_length)) ->
        {:error, {"words", :invalid}}

      Enum.any?(words, &(not Regex.match?(~r/^[\p{L}\p{Nd}]+$/u, &1))) ->
        {:error, {"words", :invalid}}

      true ->
        {:ok, words}
    end
  end

  defp words(_words), do: {:error, {"words", :invalid}}

  # The names of the fields a process takes from the one that calls it.
  defp field_names(nil), do: {:ok, []}

  defp field_names(text) when is_binary(text),
    do: text |> String.split(~r/[,\n]/) |> field_names()

  defp field_names(list) when is_list(list) do
    names =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      length(names) > @max_fields -> {:error, {"fields", :too_many}}
      Enum.any?(names, &(&1 in @reserved)) -> {:error, {"fields", :reserved}}
      Enum.all?(names, &Regex.match?(@field_format, &1)) -> {:ok, names}
      true -> {:error, {"fields", :invalid}}
    end
  end

  defp field_names(_names), do: {:error, {"fields", :invalid}}

  defp optional_key(nil, _path), do: {:ok, nil}
  defp optional_key("", _path), do: {:ok, nil}
  defp optional_key(key, _path) when is_binary(key) and byte_size(key) <= 64, do: {:ok, key}
  defp optional_key(_key, path), do: {:error, {path, :invalid}}

  defp keys(nil, _path), do: {:ok, []}

  defp keys(keys, path) when is_list(keys) do
    keys = keys |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

    if Enum.all?(keys, &(byte_size(&1) <= 64)) and length(keys) <= 20,
      do: {:ok, keys},
      else: {:error, {path, :invalid}}
  end

  defp keys(_keys, path), do: {:error, {path, :invalid}}

  defp member(value, allowed, path),
    do: if(value in allowed, do: {:ok, value}, else: {:error, {path, :invalid}})

  defp time(time) when is_binary(time) do
    case Regex.run(@time_format, String.slice(time, 0, 5)) do
      [hh_mm | _] -> {:ok, hh_mm}
      nil -> {:error, {"time", :invalid}}
    end
  end

  defp time(_time), do: {:error, {"time", :invalid}}

  defp zone(zone) when is_binary(zone) do
    case DateTime.now(zone) do
      {:ok, _now} -> {:ok, zone}
      _error -> {:error, {"time_zone", :invalid}}
    end
  end

  defp zone(_zone), do: {:error, {"time_zone", :invalid}}

  defp weekdays("week", days) when is_list(days) do
    days =
      days
      |> Enum.map(&to_day/1)
      |> Enum.filter(&(&1 in 1..7))
      |> Enum.uniq()
      |> Enum.sort()

    if days == [], do: {:error, {"weekdays", :empty}}, else: {:ok, days}
  end

  defp weekdays("week", _days), do: {:error, {"weekdays", :empty}}
  defp weekdays(_every, _days), do: {:ok, []}

  defp to_day(day) when is_integer(day), do: day

  defp to_day(day) when is_binary(day) do
    case Integer.parse(day) do
      {n, ""} -> n
      _other -> nil
    end
  end

  defp to_day(_day), do: nil

  defp month_day("month", "last"), do: {:ok, "last"}

  defp month_day("month", day) do
    case to_day(day) do
      n when is_integer(n) and n in 1..28 -> {:ok, n}
      _other -> {:error, {"day", :invalid}}
    end
  end

  defp month_day(_every, _day), do: {:ok, nil}
end
