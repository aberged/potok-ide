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

  The form's place on a map, a group with a place picked from a menu or a
  point picked on a map, lives in the form's own fields, which the page
  always renders: picking changes the form's params and builds the changeset
  again, as typing does, so the next keystroke cannot bring an old value back.
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
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupAreas, GroupPlaces, GroupRoutes}
  alias PotokIde.Tags
  alias PotokIdeWeb.Distance

  # Changes from other members are applied after this, like the group's own
  # refreshes; 0 (the test config) applies them at once.
  @debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @spread_ms 1_000
  @default_zone "Etc/UTC"
  # The groups with a place the form's menu offers at a time.
  @place_options_limit 20

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
      # The form's place: the picked group as `%{id, group}` (nil `group` for
      # one the viewer does not see), whether its map shows, where a map with
      # no point opens, and the menu's groups for its search.
      calendar_place_group: nil,
      calendar_place_map?: false,
      calendar_place_center: nil,
      calendar_place_options: [],
      calendar_place_query: "",
      # The map's mode ("point", "area" or "route") and the area or route
      # drawn on it, which stays out of the form's fields (it would go with
      # every key typed): `:unchanged` keeps the saved one, nil removes it,
      # `{:ok, shape}` or `{:error, kind, reason}` is what was drawn.
      calendar_place_mode: "point",
      calendar_place_shape: :unchanged,
      calendar_place_start: %{area: nil, route: nil, route_length: nil},
      # The open event's place (`Events.place/2`) and its link to the map.
      calendar_event_place: nil,
      calendar_event_map_path: nil,
      calendar_root_id: nil,
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
    |> close_form()
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
        |> assign_event_place(event)
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
      calendar_my_reminders: nil,
      calendar_event_place: nil,
      calendar_event_map_path: nil
    )
  end

  # Where the open event stands on a map, as the viewer may see it, and the
  # root's map opened on it; a cancelled event keeps its place but no link.
  defp assign_event_place(socket, %Event{} = event) do
    case Events.place(socket.assigns.current_profile, event) do
      nil ->
        assign(socket, calendar_event_place: nil, calendar_event_map_path: nil)

      place ->
        {root_id, socket} = root_id(socket)

        path =
          if Event.cancelled?(event),
            do: nil,
            else: ~p"/groups/#{root_id}/map?#{[event: event.id]}"

        assign(socket, calendar_event_place: place, calendar_event_map_path: path)
    end
  end

  # The root's id, asked once per page.
  defp root_id(%{assigns: %{group: %Group{is_root: true, id: id}}} = socket), do: {id, socket}
  defp root_id(%{assigns: %{calendar_root_id: id}} = socket) when is_integer(id), do: {id, socket}

  defp root_id(socket) do
    id = Social.root_group_id()
    {id, assign(socket, :calendar_root_id, id)}
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

  defp resolve_occurrence(%Event{} = event, nil), do: {Events.upcoming_occurrence(event), false}

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
        {:noreply, socket |> close_form() |> patch(event: id, on: date)}

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
       |> reset_place(event)
       |> put_form(event, Events.change_event(event, %{}, socket.assigns.calendar_time_zone))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("calendar_edit", _params, socket) do
    case socket.assigns do
      %{calendar_event: %Event{} = event, calendar_can_manage?: true} ->
        # The form starts from the saved area or route, which its map shows.
        event = Events.load_shape(event)

        {:noreply,
         socket
         |> assign(:calendar_notify?, true)
         |> reset_place(event)
         |> put_form(event, Events.change_event(event, %{}, socket.assigns.calendar_time_zone))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("calendar_close_form", _params, socket),
    do: {:noreply, close_form(socket)}

  # The menu of groups with a place opens: the nearest first.
  def handle_event("calendar_place_open", _params, socket) do
    if socket.assigns.calendar_form,
      do: {:noreply, socket |> assign(:calendar_place_query, "") |> load_place_options()},
      else: {:noreply, socket}
  end

  def handle_event("calendar_place_search", %{"calendar_place" => %{"q" => query}}, socket)
      when is_binary(query) do
    if socket.assigns.calendar_form,
      do:
        {:noreply,
         socket
         |> assign(:calendar_place_query, String.slice(query, 0, 120))
         |> load_place_options()},
      else: {:noreply, socket}
  end

  # A group with a place becomes the event's place, in place of a point. Its
  # name fills the words of the place when they are empty or the name of the
  # group picked before, where the author sees and can change them.
  def handle_event("calendar_place_pick", %{"id" => id}, socket) do
    with %Phoenix.HTML.Form{} = form <- socket.assigns.calendar_form,
         id when is_integer(id) <- parse_place_id(id),
         %Group{} = group <- GroupPlaces.get_visible(socket.assigns.current_profile, id) do
      text = String.trim(to_string(form[:location].value || ""))

      location =
        case socket.assigns.calendar_place_group do
          _any when text == "" -> %{"location" => group.name}
          %{group: %Group{name: ^text}} -> %{"location" => group.name}
          _other -> %{}
        end

      {:noreply,
       socket
       |> assign(calendar_place_map?: false, calendar_place_group: %{id: group.id, group: group})
       |> drop_shape()
       |> put_place(
         Map.merge(
           %{
             "place_group_id" => Integer.to_string(group.id),
             "latitude" => "",
             "longitude" => ""
           },
           location
         )
       )}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("calendar_place_clear_group", _params, socket),
    do: {:noreply, put_place(socket, %{"place_group_id" => ""})}

  # The map opens in place of the group, where the group stood or else where
  # the calendar's group stands.
  def handle_event("calendar_place_map", _params, socket) do
    if socket.assigns.calendar_form do
      center =
        case socket.assigns.calendar_place_group do
          %{group: %Group{latitude: lat, longitude: lng}} -> [lat, lng]
          _none -> group_center(socket.assigns.group)
        end

      {:noreply,
       socket
       |> assign(calendar_place_map?: true, calendar_place_center: center)
       |> assign(:calendar_place_mode, shape_kind(socket) || "point")
       |> put_place(%{"place_group_id" => ""})}
    else
      {:noreply, socket}
    end
  end

  # The place leaves the map: its point, area and route, and the map closes.
  def handle_event("calendar_place_clear_point", _params, socket) do
    {:noreply,
     socket
     |> assign(:calendar_place_map?, false)
     |> drop_shape()
     |> put_place(%{"latitude" => "", "longitude" => ""})}
  end

  # A point, an area or a route, as on a group's Location card: a point drops
  # the shape, and so does the other kind of shape. The map is told the mode.
  def handle_event("calendar_place_mode", %{"mode" => mode}, socket)
      when mode in ["point", "area", "route"] do
    if socket.assigns.calendar_form do
      kind = shape_kind(socket)

      socket =
        if mode == "point" or (kind != nil and kind != mode),
          do: drop_shape(socket),
          else: socket

      {:noreply,
       socket
       |> assign(:calendar_place_mode, mode)
       |> put_place(%{})
       |> push_event("calendar_place_map_mode", %{mode: mode})}
    else
      {:noreply, socket}
    end
  end

  # The border the form's map holds, checked at once, with the pin it gets.
  def handle_event("calendar_place_area", params, socket) do
    if socket.assigns.calendar_form do
      {draft, reply} =
        case params["area"] do
          nil ->
            {nil, %{ok: true}}

          json ->
            with {:ok, area} <- GroupAreas.decode(json),
                 {:ok, {lat, lng}} <- GroupAreas.pin_inside(area) do
              {{:ok, area}, %{ok: true, lat: lat, lng: lng}}
            else
              {:error, reason} ->
                {{:error, :area, reason}, %{ok: false, error: shape_error_text(:area, reason)}}
            end
        end

      {:reply, reply, put_shape(socket, draft, reply)}
    else
      {:reply, %{ok: false}, socket}
    end
  end

  # The route the form's map holds, checked at once, with its start (where
  # the pin goes) and its length.
  def handle_event("calendar_place_route", params, socket) do
    if socket.assigns.calendar_form do
      {draft, reply} =
        case params["route"] && GroupRoutes.decode(params["route"]) do
          nil ->
            {nil, %{ok: true}}

          {:ok, route} ->
            {lat, lng} = GroupRoutes.start(route)
            meters = GroupRoutes.meters(route)

            {{:ok, route},
             %{
               ok: true,
               lat: lat,
               lng: lng,
               length: round(meters),
               length_text: Distance.text(meters)
             }}

          {:error, reason} ->
            {{:error, :route, reason}, %{ok: false, error: shape_error_text(:route, reason)}}
        end

      {:reply, reply, put_shape(socket, draft, reply)}
    else
      {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("calendar_validate", %{"event" => params} = all, socket) do
    case socket.assigns.calendar_form_event do
      %Event{} = event ->
        changeset =
          socket
          |> place_changeset(event, fit_monthly_mode(params))
          |> Map.put(:action, :validate)

        {:noreply, socket |> put_flags(all) |> put_form(event, changeset)}

      nil ->
        {:noreply, socket}
    end
  end

  # A border or a route the server refused keeps the form open on it.
  def handle_event("calendar_save", %{"event" => params} = all, socket) do
    if match?({:error, _kind, _reason}, socket.assigns.calendar_place_shape),
      do: handle_event("calendar_validate", all, socket),
      else: save_event(socket, params, all)
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

  defp save_event(socket, params, all) do
    socket = put_flags(socket, all)
    params = params |> fit_monthly_mode() |> put_shape_draft(socket.assigns.calendar_place_shape)
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
         |> close_form()
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
         |> close_form()
         |> put_flash(:error, gettext("You cannot change this event."))}
    end
  end

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
    place_group_id = Ecto.Changeset.get_field(changeset, :place_group_id)
    latitude = Ecto.Changeset.get_field(changeset, :latitude)
    longitude = Ecto.Changeset.get_field(changeset, :longitude)

    socket
    |> assign(
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
        time_zone: Ecto.Changeset.get_field(changeset, :time_zone),
        place_group_id: place_group_id,
        point: if(is_number(latitude) and is_number(longitude), do: [latitude, longitude])
      }
    )
    |> put_place_group(place_group_id)
  end

  # The area or route the form's map shows when it opens, as GeoJSON, with a
  # route's length: what was drawn (`length_text` as the server answered the
  # map), or else what is saved.
  defp start_shape(_event, {:ok, %Geo.MultiPolygon{} = area}, _length_text),
    do: %{area: GroupAreas.to_geojson(area), route: nil, route_length: nil}

  defp start_shape(_event, {:ok, %Geo.MultiLineString{} = route}, length_text),
    do: %{area: nil, route: GroupRoutes.to_geojson(route), route_length: length_text}

  defp start_shape(%Event{} = event, :unchanged, _length_text) do
    %{
      area: GroupAreas.to_geojson(event.area),
      route: GroupRoutes.to_geojson(event.route),
      route_length: event.route && Distance.text(GroupRoutes.meters(event.route))
    }
  end

  defp start_shape(_event, _none_or_error, _length_text),
    do: %{area: nil, route: nil, route_length: nil}

  # The picked group, read again only when another one is picked.
  defp put_place_group(socket, nil), do: assign(socket, :calendar_place_group, nil)

  defp put_place_group(%{assigns: %{calendar_place_group: %{id: id}}} = socket, id), do: socket

  defp put_place_group(socket, id) do
    group = GroupPlaces.get_visible(socket.assigns.current_profile, id)
    assign(socket, :calendar_place_group, %{id: id, group: group})
  end

  # The form's place fields changed by a pick: into the form's params, as if
  # typed, and the changeset built again. A field marked unused is used now,
  # so its errors show.
  defp put_place(socket, place_params) do
    case socket.assigns do
      %{calendar_form: %Phoenix.HTML.Form{} = form, calendar_form_event: %Event{} = event} ->
        unused = Enum.map(Map.keys(place_params), &("_unused_" <> &1))

        params =
          (form.params || %{})
          |> Map.drop(unused)
          |> Map.merge(place_params)

        changeset =
          socket
          |> place_changeset(event, params)
          |> Map.put(:action, :validate)

        put_form(socket, event, changeset)

      _closed ->
        socket
    end
  end

  # The form's changeset with the shape drawn on its map, which no field of
  # the form carries.
  defp place_changeset(socket, %Event{} = event, params) do
    draft = socket.assigns.calendar_place_shape

    params =
      params
      |> Map.drop(["area", "route"])
      |> put_shape_draft(draft)

    event
    |> Events.change_event(params, socket.assigns.calendar_time_zone)
    |> add_shape_draft_error(draft)
  end

  # The shape drawn on the map goes in with the form's fields and takes the
  # other kind's place: `:unchanged` leaves the saved one, nil removes both.
  defp put_shape_draft(params, {:ok, %Geo.MultiPolygon{} = area}),
    do: Map.merge(params, %{"area" => area, "route" => nil})

  defp put_shape_draft(params, {:ok, %Geo.MultiLineString{} = route}),
    do: Map.merge(params, %{"area" => nil, "route" => route})

  defp put_shape_draft(params, nil), do: Map.merge(params, %{"area" => nil, "route" => nil})
  defp put_shape_draft(params, _unchanged_or_error), do: params

  defp add_shape_draft_error(changeset, {:error, :area, reason}),
    do: Ecto.Changeset.add_error(changeset, :area, Group.area_error(reason))

  defp add_shape_draft_error(changeset, {:error, :route, reason}),
    do: Ecto.Changeset.add_error(changeset, :route, Group.route_error(reason))

  defp add_shape_draft_error(changeset, _draft), do: changeset

  defp shape_error_text(:area, reason),
    do: PotokIdeWeb.CoreComponents.translate_error({Group.area_error(reason), []})

  defp shape_error_text(:route, reason),
    do: PotokIdeWeb.CoreComponents.translate_error({Group.route_error(reason), []})

  # What the map drew, and the form again with it.
  defp put_shape(socket, draft, reply) do
    socket
    |> assign(
      calendar_place_shape: draft,
      calendar_place_start:
        start_shape(socket.assigns.calendar_form_event, draft, reply[:length_text])
    )
    |> put_place(%{})
  end

  # No area or route any more: the saved one goes too, and the map is a
  # point's.
  defp drop_shape(socket),
    do:
      assign(socket,
        calendar_place_shape: nil,
        calendar_place_mode: "point",
        calendar_place_start: start_shape(nil, nil, nil)
      )

  # The kind of shape the form holds now, "area", "route" or nil: the drawn
  # one's, or the saved one's while nothing was drawn.
  defp shape_kind(socket) do
    case socket.assigns.calendar_place_shape do
      {:ok, %Geo.MultiPolygon{}} -> "area"
      {:ok, %Geo.MultiLineString{}} -> "route"
      {:error, kind, _reason} -> Atom.to_string(kind)
      nil -> nil
      :unchanged -> event_shape_kind(socket.assigns.calendar_form_event)
    end
  end

  defp event_shape_kind(%Event{area: %Geo.MultiPolygon{}}), do: "area"
  defp event_shape_kind(%Event{route: %Geo.MultiLineString{}}), do: "route"
  defp event_shape_kind(_event), do: nil

  # A new form starts with the event's own place: its map open when it has a
  # point, opening where the calendar's group stands otherwise.
  defp reset_place(socket, %Event{} = event) do
    assign(socket,
      calendar_place_group: nil,
      calendar_place_map?: is_number(event.latitude),
      calendar_place_center: group_center(socket.assigns.group),
      calendar_place_options: [],
      calendar_place_query: "",
      calendar_place_mode: event_shape_kind(event) || "point",
      calendar_place_shape: :unchanged,
      calendar_place_start: start_shape(event, :unchanged, nil)
    )
  end

  defp close_form(socket) do
    assign(socket,
      calendar_form: nil,
      calendar_form_event: nil,
      calendar_place_group: nil,
      calendar_place_map?: false,
      calendar_place_options: [],
      calendar_place_query: "",
      calendar_place_mode: "point",
      calendar_place_shape: :unchanged
    )
  end

  defp load_place_options(socket) do
    options =
      GroupPlaces.search(
        socket.assigns.current_profile,
        socket.assigns.calendar_place_query,
        place_near(socket),
        @place_options_limit
      )

    assign(socket, :calendar_place_options, options)
  end

  # What the menu measures from: the event's point, the picked group, or the
  # calendar's group, whichever stands on the map first.
  defp place_near(socket) do
    case {socket.assigns.calendar_form_values, socket.assigns.calendar_place_group} do
      {%{point: [lat, lng]}, _group} -> {lat, lng}
      {_values, %{group: %Group{latitude: lat, longitude: lng}}} -> {lat, lng}
      _none -> socket.assigns.group |> group_center() |> then(&(&1 && List.to_tuple(&1)))
    end
  end

  defp group_center(%Group{latitude: lat, longitude: lng}) when is_number(lat) and is_number(lng),
    do: [lat, lng]

  defp group_center(_group), do: nil

  defp parse_place_id(id) when is_integer(id) and id > 0, do: id
  defp parse_place_id(id), do: parse_id(id)

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
