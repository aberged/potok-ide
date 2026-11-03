defmodule PotokIdeWeb.GroupLive.Show.CalendarState do
  @moduledoc """
  The calendar tab of `GroupLive.Show`: its assigns, URL params, events and
  live updates. `GroupLive.Show` delegates every `"calendar_*"` event and
  `{:calendar, _}` message here.

  The URL holds the month (`?month=2026-11`), the list mode (`mode=list`) and
  the open occurrence (`event=12&on=2026-11-07`); the event form and the
  "with sub-groups" switch live in assigns. Times are shown in the viewer's
  zone, which the browser sends when the socket connects, as it sends the
  root calendar's filters (its groups' events, public events).
  """

  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      get_connect_params: 1,
      push_event: 3,
      push_patch: 2,
      put_flash: 3,
      stream: 4
    ]

  alias PotokIde.Events
  alias PotokIde.Events.{Event, Occurrence, Recurrence}
  alias PotokIde.Social.{Access, Group}
  alias PotokIde.Tags

  # Changes from other members are applied after this, like the group's own
  # refreshes; 0 (the test config) applies them at once.
  @debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @spread_ms 1_000
  @default_zone "Etc/UTC"

  ## Setup

  @doc "The viewer's zone, sent by the browser on connect."
  def connect_time_zone(socket) do
    with true <- connected?(socket),
         %{"time_zone" => zone} when is_binary(zone) <- get_connect_params(socket),
         true <- valid_zone?(zone) do
      zone
    else
      _ -> @default_zone
    end
  end

  defp valid_zone?(zone), do: match?({:ok, _}, DateTime.now(zone))

  # The root calendar's filters as the viewer left them (`calendar_filters`
  # in app.js); both are on until then.
  defp connect_filters(socket) do
    filters =
      with true <- connected?(socket),
           %{"calendar_filters" => %{} = filters} <- get_connect_params(socket) do
        filters
      else
        _ -> %{}
      end

    {filters["groups"] != false, filters["public"] != false}
  end

  def init(socket, params) do
    {show_groups?, show_public?} = connect_filters(socket)

    socket
    |> assign(
      calendar_time_zone: connect_time_zone(socket),
      calendar_include_subgroups?: false,
      calendar_show_groups?: show_groups?,
      calendar_show_public?: show_public?,
      calendar_group_ids: [],
      calendar_public: false,
      calendar_subscribed: MapSet.new(),
      calendar_weeks: [],
      calendar_by_day: %{},
      calendar_occurrences_empty?: true,
      calendar_event: nil,
      calendar_occurrence: nil,
      calendar_occurrence_cancelled?: false,
      calendar_summary: nil,
      calendar_can_manage?: false,
      calendar_event_member?: false,
      calendar_my_reminders: nil,
      calendar_form: nil,
      calendar_form_event: nil,
      calendar_form_values: nil,
      calendar_announce?: true,
      calendar_notify?: true,
      calendar_pending: MapSet.new(),
      calendar_flush_scheduled?: false
    )
    |> Phoenix.LiveView.stream_configure(:calendar_occurrences,
      dom_id: &"calendar-occurrence-#{&1.event.id}-#{&1.date}"
    )
    |> stream(:calendar_occurrences, [], reset: true)
    |> assign_params(params)
  end

  ## URL params

  @doc "Takes the calendar's URL params into assigns, without loading anything."
  def assign_params(socket, params) do
    zone = socket.assigns.calendar_time_zone
    today = today(zone)
    on = parse_date(params["on"])

    month =
      case parse_month(params["month"]) do
        %Date{} = month -> month
        nil when not is_nil(on) -> Date.beginning_of_month(on)
        nil -> Date.beginning_of_month(today)
      end

    selected =
      cond do
        on && same_month?(on, month) -> on
        same_month?(today, month) -> today
        true -> month
      end

    assign(socket,
      calendar_month: month,
      calendar_mode: if(params["mode"] == "list", do: "list", else: "month"),
      calendar_event_id: parse_id(params["event"]),
      calendar_on: on,
      calendar_selected_date: selected
    )
  end

  @doc """
  Applies new URL params on the calendar tab, reloading only what changed.
  """
  def handle_params(socket, params) do
    before =
      Map.take(socket.assigns, [:calendar_month, :calendar_mode, :calendar_event_id, :calendar_on])

    socket = assign_params(socket, params)

    # The list is a stream: its items reach the page only while it is shown,
    # so switching to it streams them again.
    socket =
      if socket.assigns.calendar_month != before.calendar_month or
           socket.assigns.calendar_mode != before.calendar_mode,
         do: load_month(socket),
         else: socket

    if {socket.assigns.calendar_event_id, socket.assigns.calendar_on} !=
         {before.calendar_event_id, before.calendar_on},
       do: load_detail(socket),
       else: socket
  end

  @doc "Whether the params differ from what the tab shows."
  def params_changed?(socket, params) do
    zone = socket.assigns.calendar_time_zone
    month = parse_month(params["month"])
    on = parse_date(params["on"])

    (month || (on && Date.beginning_of_month(on)) || Date.beginning_of_month(today(zone))) !=
      socket.assigns.calendar_month or
      if(params["mode"] == "list", do: "list", else: "month") != socket.assigns.calendar_mode or
      parse_id(params["event"]) != socket.assigns.calendar_event_id or
      on != socket.assigns.calendar_on
  end

  defp parse_month(value) when is_binary(value) do
    case Date.from_iso8601(value <> "-01") do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_month(_value), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp same_month?(%Date{} = a, %Date{} = b), do: a.year == b.year and a.month == b.month

  @doc "The calendar URL of the socket's group with `changes` to the current params."
  def calendar_path(socket, changes \\ []) do
    assigns = socket.assigns
    event_id = Keyword.get(changes, :event, assigns.calendar_event_id)
    on = Keyword.get(changes, :on, if(event_id, do: assigns.calendar_on))
    month = Keyword.get(changes, :month, assigns.calendar_month)
    mode = Keyword.get(changes, :mode, assigns.calendar_mode)

    query =
      [
        {"month", Calendar.strftime(month, "%Y-%m")},
        mode == "list" && {"mode", "list"},
        event_id && {"event", event_id},
        on && {"on", Date.to_iso8601(on)}
      ]
      |> Enum.filter(& &1)

    ~p"/groups/#{assigns.group.id}/calendar?#{query}"
  end

  ## Loading

  @doc """
  Loads the tab when it is the active one, or drops its subscriptions when
  it is not. Runs with every reload of the group's panel, so it follows
  membership and profile changes.
  """
  def maybe_load(socket, %Group{} = group, "calendar") do
    assigns = socket.assigns
    member? = assigns.access.member?

    group_ids =
      if (group.is_root and not assigns.calendar_show_groups?) or not member?,
        do: [],
        else:
          Events.calendar_group_ids(
            assigns.current_profile,
            group,
            assigns.calendar_include_subgroups?
          )

    # The root calendar shows every public event; a group's calendar shows
    # its own public events to those who are no members.
    public =
      cond do
        group.is_root -> assigns.calendar_show_public?
        member? -> false
        true -> [group.id]
      end

    topics =
      case public do
        true -> [:public | group_ids]
        false -> group_ids
        public_ids -> public_ids ++ group_ids
      end

    socket
    |> assign(calendar_group_ids: group_ids, calendar_public: public)
    |> sync_subscriptions(topics)
    |> load_month()
    |> load_detail()
  end

  def maybe_load(socket, _group, _active_tab) do
    socket
    |> sync_subscriptions([])
    |> assign(:calendar_form, nil)
  end

  # `topics` are group ids and `:public` (see `Events.subscribe/1`).
  defp sync_subscriptions(socket, topics) do
    if connected?(socket) do
      wanted = MapSet.new(topics)
      current = socket.assigns.calendar_subscribed

      current |> MapSet.difference(wanted) |> Enum.each(&Events.unsubscribe/1)
      wanted |> MapSet.difference(current) |> Enum.each(&Events.subscribe/1)

      assign(socket, :calendar_subscribed, wanted)
    else
      socket
    end
  end

  # The weeks of the month (Monday first) with each day's occurrences, and
  # the month's occurrences for the list.
  defp load_month(socket) do
    zone = socket.assigns.calendar_time_zone
    month = socket.assigns.calendar_month
    today = today(zone)
    grid_start = Date.add(month, 1 - Date.day_of_week(month))
    month_end = Date.end_of_month(month)
    grid_end = Date.add(month_end, 7 - Date.day_of_week(month_end))

    occurrences =
      Events.list_occurrences(
        socket.assigns.calendar_group_ids,
        Recurrence.to_utc(grid_start, ~T[00:00:00], zone),
        Recurrence.to_utc(Date.add(grid_end, 1), ~T[00:00:00], zone),
        public: socket.assigns.calendar_public
      )

    by_day =
      Enum.reduce(Enum.reverse(occurrences), %{}, fn occurrence, acc ->
        occurrence
        |> local_days(zone)
        |> Enum.reduce(acc, fn date, acc ->
          Map.update(acc, date, [occurrence], &[occurrence | &1])
        end)
      end)

    weeks =
      grid_start
      |> Date.range(grid_end)
      |> Enum.map(fn date ->
        %{
          date: date,
          in_month?: same_month?(date, month),
          today?: date == today,
          occurrences: Map.get(by_day, date, [])
        }
      end)
      |> Enum.chunk_every(7)

    in_month =
      Enum.filter(occurrences, fn occurrence ->
        Enum.any?(local_days(occurrence, zone), &same_month?(&1, month))
      end)

    socket
    |> assign(:calendar_weeks, weeks)
    |> assign(:calendar_by_day, by_day)
    |> assign(:calendar_occurrences_empty?, in_month == [])
    |> stream(:calendar_occurrences, in_month, reset: true)
  end

  @doc """
  The local days an occurrence covers: an all-day one its dates in the
  event's zone, a timed one the viewer's days from its start to its end.
  """
  def local_days(%Occurrence{event: %Event{all_day: true} = event} = occurrence, _zone) do
    last = Date.add(Recurrence.local_date(occurrence.ends_at, event.time_zone), -1)
    Date.range(occurrence.date, Enum.max([last, occurrence.date], Date)) |> Enum.to_list()
  end

  def local_days(%Occurrence{} = occurrence, zone) do
    first = Recurrence.local_date(occurrence.starts_at, zone)
    # An occurrence that ends at midnight does not reach the next day.
    last = Recurrence.local_date(DateTime.add(occurrence.ends_at, -1), zone)
    Date.range(first, Enum.max([last, first], Date)) |> Enum.to_list()
  end

  defp load_detail(%{assigns: %{calendar_event_id: nil}} = socket), do: clear_detail(socket)

  defp load_detail(socket) do
    profile = socket.assigns.current_profile

    case Events.get_event(profile, socket.assigns.calendar_event_id) do
      {:ok, event} ->
        {occurrence, cancelled?} = resolve_occurrence(event, socket.assigns.calendar_on)
        group = socket.assigns.group

        access =
          if event.group_id == group.id,
            do: socket.assigns.access,
            else: Access.for_profile(profile, event.group)

        socket
        |> assign(:calendar_event, Tags.put_tags(event, profile, :event))
        |> assign(:calendar_occurrence, occurrence)
        |> assign(:calendar_occurrence_cancelled?, cancelled?)
        |> assign(
          :calendar_can_manage?,
          event.group_id == group.id and Events.can_manage?(access, profile, event)
        )
        |> assign(:calendar_event_member?, access.member?)
        |> assign(:calendar_my_reminders, Events.member_reminders(profile, event))
        |> load_summary()

      {:error, :not_found} ->
        socket
        |> clear_detail()
        |> put_flash(:error, gettext("That event was not found."))
    end
  end

  @doc "Reads the tags of the open event again, when it is `event_id`."
  def refresh_event_tags(
        %{assigns: %{calendar_event: %Event{id: event_id} = event}} = socket,
        event_id
      ),
      do:
        assign(
          socket,
          :calendar_event,
          Tags.put_tags(event, socket.assigns.current_profile, :event)
        )

  def refresh_event_tags(socket, _event_id), do: socket

  defp clear_detail(socket) do
    assign(socket,
      calendar_event: nil,
      calendar_occurrence: nil,
      calendar_occurrence_cancelled?: false,
      calendar_summary: nil,
      calendar_can_manage?: false,
      calendar_event_member?: false,
      calendar_my_reminders: nil
    )
  end

  # The occurrence on `date`, or for a cancelled date that date marked
  # cancelled; without a date the one on now or next (the first one of an
  # event that is over).
  defp resolve_occurrence(%Event{} = event, %Date{} = date) do
    cond do
      occurrence = Recurrence.occurrence(event, date) -> {occurrence, false}
      date in event.excluded_dates -> {Recurrence.build(event, date), true}
      true -> resolve_occurrence(event, nil)
    end
  end

  defp resolve_occurrence(%Event{} = event, nil) do
    span = DateTime.diff(event.ends_at, event.starts_at)
    since = DateTime.add(DateTime.utc_now(:second), -span - 1)

    {Recurrence.next_occurrence_after(event, since) ||
       Recurrence.build(event, Recurrence.start_date(event)), false}
  end

  defp load_summary(%{assigns: %{calendar_occurrence: %Occurrence{} = occurrence}} = socket) do
    assign(
      socket,
      :calendar_summary,
      Events.response_summary(occurrence.event, occurrence.date, socket.assigns.current_profile)
    )
  end

  defp load_summary(socket), do: assign(socket, :calendar_summary, nil)

  ## Events

  def handle_event("calendar_prev_month", _params, socket),
    do: {:noreply, patch(socket, month: shift_month(socket.assigns.calendar_month, -1))}

  def handle_event("calendar_next_month", _params, socket),
    do: {:noreply, patch(socket, month: shift_month(socket.assigns.calendar_month, 1))}

  def handle_event("calendar_today", _params, socket) do
    month = Date.beginning_of_month(today(socket.assigns.calendar_time_zone))
    {:noreply, patch(socket, month: month, event: nil)}
  end

  def handle_event("calendar_set_mode", %{"view" => mode}, socket) when mode in ["month", "list"],
    do: {:noreply, patch(socket, mode: mode)}

  def handle_event("calendar_toggle_subgroups", _params, socket) do
    socket = update_in_assign(socket, :calendar_include_subgroups?, &not/1)
    {:noreply, maybe_load(socket, socket.assigns.group, "calendar")}
  end

  def handle_event("calendar_toggle_groups", _params, socket),
    do: toggle_filter(socket, :calendar_show_groups?)

  def handle_event("calendar_toggle_public", _params, socket),
    do: toggle_filter(socket, :calendar_show_public?)

  def handle_event("calendar_select_day", %{"date" => date}, socket) do
    case parse_date(date) do
      %Date{} = date -> {:noreply, assign(socket, :calendar_selected_date, date)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("calendar_open", %{"id" => id, "date" => date}, socket) do
    case {parse_id(id), parse_date(date)} do
      {id, %Date{} = date} when is_integer(id) ->
        {:noreply, socket |> assign(:calendar_form, nil) |> patch(event: id, on: date)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar_close", _params, socket),
    do: {:noreply, patch(socket, event: nil, on: nil)}

  def handle_event("calendar_new", _params, socket) do
    if Events.can_create?(socket.assigns.access, socket.assigns.group) do
      event = Events.new_event(socket.assigns.calendar_selected_date)

      {:noreply,
       socket
       |> assign(:calendar_announce?, Access.can?(socket.assigns.access, :post_values))
       |> put_form(event, Events.change_event(event, %{}, socket.assigns.calendar_time_zone))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("calendar_edit", _params, socket) do
    case socket.assigns do
      %{calendar_event: %Event{} = event, calendar_can_manage?: true} ->
        {:noreply,
         socket
         |> assign(:calendar_notify?, true)
         |> put_form(event, Events.change_event(event, %{}, socket.assigns.calendar_time_zone))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar_close_form", _params, socket),
    do: {:noreply, assign(socket, calendar_form: nil, calendar_form_event: nil)}

  def handle_event("calendar_validate", %{"event" => params} = all, socket) do
    case socket.assigns.calendar_form_event do
      %Event{} = event ->
        changeset =
          event
          |> Events.change_event(fit_monthly_mode(params), socket.assigns.calendar_time_zone)
          |> Map.put(:action, :validate)

        {:noreply, socket |> put_flags(all) |> put_form(event, changeset)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar_save", %{"event" => params} = all, socket) do
    socket = put_flags(socket, all)
    params = fit_monthly_mode(params)
    profile = socket.assigns.current_profile

    result =
      case socket.assigns.calendar_form_event do
        %Event{id: nil} ->
          Events.create_event(
            profile,
            socket.assigns.group,
            params,
            socket.assigns.calendar_time_zone,
            announce: socket.assigns.calendar_announce?
          )

        %Event{} = event ->
          Events.update_event(profile, event, params, notify: socket.assigns.calendar_notify?)

        nil ->
          {:error, :not_found}
      end

    case result do
      {:ok, event} ->
        date = Recurrence.start_date(event)

        {:noreply,
         socket
         |> assign(calendar_form: nil, calendar_form_event: nil)
         |> load_month()
         |> put_flash(:info, gettext("The event was saved."))
         |> patch(event: event.id, on: date, month: Date.beginning_of_month(date))
         |> force_detail_reload()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_form(
           socket,
           socket.assigns.calendar_form_event,
           Map.put(changeset, :action, :insert)
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(calendar_form: nil, calendar_form_event: nil)
         |> put_flash(:error, gettext("You cannot change this event."))}
    end
  end

  def handle_event("calendar_respond", %{"status" => status}, socket)
      when status in ["going", "maybe", "declined"] do
    with %Event{} = event <- socket.assigns.calendar_event,
         %Occurrence{} = occurrence <- socket.assigns.calendar_occurrence do
      status = String.to_existing_atom(status)
      # Pressing the current answer takes it back.
      status = if socket.assigns.calendar_summary.mine == status, do: nil, else: status

      case Events.respond(socket.assigns.current_profile, event, occurrence.date, status) do
        {:ok, _response} ->
          {:noreply, load_summary(socket)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("You cannot answer this event."))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("calendar_save_reminders", params, socket) do
    minutes = get_in(params, ["reminders", "reminder_minutes"]) || []

    update_reminders(socket, %{"reminder_minutes" => minutes})
  end

  def handle_event("calendar_default_reminders", _params, socket),
    do: update_reminders(socket, :default)

  def handle_event("calendar_cancel_event", _params, socket) do
    with %Event{} = event <- socket.assigns.calendar_event,
         {:ok, _cancelled} <- Events.cancel_event(socket.assigns.current_profile, event) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("The event was cancelled."))
       |> load_month()
       |> load_detail()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("You cannot change this event."))}
    end
  end

  def handle_event("calendar_cancel_occurrence", _params, socket) do
    with %Event{} = event <- socket.assigns.calendar_event,
         %Occurrence{} = occurrence <- socket.assigns.calendar_occurrence,
         {:ok, _event} <-
           Events.cancel_occurrence(socket.assigns.current_profile, event, occurrence.date) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("This occurrence was cancelled."))
       |> load_month()
       |> load_detail()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("You cannot change this event."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Only the root calendar has these filters. The browser keeps them for the
  # next visits (`calendar_filters` in app.js).
  defp toggle_filter(%{assigns: %{group: %Group{is_root: true}}} = socket, key) do
    socket = update_in_assign(socket, key, &not/1)

    {:noreply,
     socket
     |> maybe_load(socket.assigns.group, "calendar")
     |> push_event("calendar_filters", %{
       groups: socket.assigns.calendar_show_groups?,
       public: socket.assigns.calendar_show_public?
     })}
  end

  defp toggle_filter(socket, _key), do: {:noreply, socket}

  defp update_reminders(socket, attrs) do
    case socket.assigns.calendar_event do
      %Event{} = event ->
        case Events.set_member_reminders(socket.assigns.current_profile, event, attrs) do
          {:ok, _setting} ->
            {:noreply,
             socket
             |> assign(
               :calendar_my_reminders,
               Events.member_reminders(socket.assigns.current_profile, event)
             )
             |> put_flash(:info, gettext("Your reminders were saved."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Your reminders could not be saved."))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  # A monthly rule the new start date does not allow falls back to the day
  # of the month, so moving the start never makes the form invalid.
  defp fit_monthly_mode(%{"start_date" => start, "recurrence_monthly" => mode} = params) do
    with %Date{} = date <- parse_date(start),
         false <- mode in Enum.map(Recurrence.monthly_modes_for(date), &Atom.to_string/1) do
      Map.put(params, "recurrence_monthly", "day_of_month")
    else
      _ -> params
    end
  end

  defp fit_monthly_mode(params), do: params

  defp put_flags(socket, params) do
    socket
    |> assign(:calendar_announce?, Map.get(params, "announce", "true") == "true")
    |> assign(:calendar_notify?, Map.get(params, "notify", "true") == "true")
  end

  defp put_form(socket, %Event{} = event, %Ecto.Changeset{} = changeset) do
    start_date = Ecto.Changeset.get_field(changeset, :start_date)
    all_day? = Ecto.Changeset.get_field(changeset, :all_day)

    assign(socket,
      calendar_form: to_form(changeset, as: :event),
      calendar_form_event: event,
      calendar_form_values: %{
        new?: is_nil(event.id),
        all_day?: all_day?,
        recurrence: Ecto.Changeset.get_field(changeset, :recurrence),
        weekdays: Ecto.Changeset.get_field(changeset, :recurrence_weekdays) || [],
        start_date: start_date,
        start_weekday: start_date && Date.day_of_week(start_date),
        monthly: Ecto.Changeset.get_field(changeset, :recurrence_monthly),
        monthly_modes:
          if(start_date, do: Recurrence.monthly_modes_for(start_date), else: [:day_of_month]),
        reminder_choices: Event.reminder_choices(%Event{all_day: all_day?}),
        reminders: Ecto.Changeset.get_field(changeset, :reminder_minutes) || [],
        time_zone: Ecto.Changeset.get_field(changeset, :time_zone)
      }
    )
  end

  ## Live updates

  @doc "Handles `{:calendar, message}` messages of `PotokIde.Events`."
  def handle_info({:events_changed, _group_id}, socket), do: {:noreply, schedule(socket, :events)}

  def handle_info({:responses_changed, event_id, date}, socket) do
    case socket.assigns do
      %{calendar_event: %Event{id: ^event_id}, calendar_occurrence: %Occurrence{date: ^date}} ->
        {:noreply, schedule(socket, :responses)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:flush, socket) do
    pending = socket.assigns.calendar_pending

    socket =
      socket
      |> assign(calendar_pending: MapSet.new(), calendar_flush_scheduled?: false)
      |> apply_pending(pending)

    {:noreply, socket}
  end

  defp schedule(socket, kind) do
    if @debounce_ms == 0 do
      apply_pending(socket, MapSet.new([kind]))
    else
      socket = update_in_assign(socket, :calendar_pending, &MapSet.put(&1, kind))

      if socket.assigns.calendar_flush_scheduled? do
        socket
      else
        Process.send_after(self(), {:calendar, :flush}, @debounce_ms + :rand.uniform(@spread_ms))
        assign(socket, :calendar_flush_scheduled?, true)
      end
    end
  end

  defp apply_pending(%{assigns: %{active_tab: "calendar"}} = socket, pending) do
    cond do
      MapSet.member?(pending, :events) -> socket |> load_month() |> load_detail()
      MapSet.member?(pending, :responses) -> load_summary(socket)
      true -> socket
    end
  end

  defp apply_pending(socket, _pending), do: socket

  ## Helpers

  def today(zone), do: Recurrence.local_date(DateTime.utc_now(), zone)

  defp shift_month(%Date{} = month, months) do
    index = month.year * 12 + month.month - 1 + months
    Date.new!(div(index, 12), rem(index, 12) + 1, 1)
  end

  defp patch(socket, changes), do: push_patch(socket, to: calendar_path(socket, changes))

  # After saving, the patch may point at the event that is already open.
  defp force_detail_reload(socket), do: assign(socket, :calendar_event_id, nil)

  defp update_in_assign(socket, key, fun), do: assign(socket, key, fun.(socket.assigns[key]))
end
