defmodule PotokIdeWeb.GroupLive.Show.RootMapState do
  @moduledoc """
  The map tab of the root group (`/groups/:root/map`): every group with a place
  the viewer sees, at any depth. `GroupLive.Show` delegates every
  `"root_map_*"` event here.

  The browser draws the map (`root_map.js`) and asks for what lies in its view
  as it moves; the server gathers the groups into clusters on a grid
  (`Social.list_map_cells/4`), so a phone draws a few hundred markers however
  many groups there are. The filters live here, in assigns: the root's
  sub-group filters (public groups, membership, kind, name) and a time frame,
  the last 30 days of when groups were made until the viewer picks another.
  They are not remembered, except the public groups switch, which is the same
  one as in the sub-groups tab.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias PotokIde.RateLimit
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupPresets}
  alias PotokIdeWeb.GroupLive.Show.{AppApi, GroupSheet}

  @periods ~w(24h 7d 30d 12m any)
  @default_period "30d"
  @spot_limit 50

  @doc "The time frames of the menu, in its order."
  def periods, do: @periods

  def init(socket) do
    socket
    |> assign(
      root_map_filters: default_filters(),
      root_map_view: nil,
      root_map_extent: nil,
      root_map_total: nil,
      root_map_spot: nil,
      root_map_error?: false
    )
    |> assign_range_form(%{})
  end

  defp default_filters do
    %{
      search: "",
      preset: nil,
      relation: nil,
      time: :created,
      period: @default_period,
      from: nil,
      to: nil
    }
  end

  @doc """
  Why a map that holds no group is empty: `:filters` while the viewer
  narrowed it beyond where it starts, `:time` while only the starting time
  frame keeps groups out, `:none` when it would hold none at any time.
  """
  def empty_reason(filters) do
    any_time? = filters.period == "any"

    cond do
      filters.search != "" or filters.preset != nil or filters.relation != nil -> :filters
      filters.period not in [@default_period, "any"] -> :filters
      filters.time == :active and not any_time? -> :filters
      not any_time? -> :time
      true -> :none
    end
  end

  ## Loading

  @doc """
  Counts the groups the filters keep when the tab opens; the map asks for its
  view by itself. Another tab drops what the map held.
  """
  def maybe_load(socket, %Group{is_root: true}, "map") do
    if socket.assigns.root_map_extent, do: socket, else: load_extent(socket)
  end

  def maybe_load(socket, _group, _active_tab) do
    assign(socket,
      root_map_view: nil,
      root_map_extent: nil,
      root_map_total: nil,
      root_map_spot: nil,
      root_map_error?: false
    )
  end

  defp load_extent(socket) do
    case Social.map_extent(socket.assigns.current_profile, social_filters(socket.assigns)) do
      {:ok, extent} -> assign(socket, root_map_extent: extent, root_map_error?: false)
      {:error, :timeout} -> assign(socket, root_map_extent: nil, root_map_error?: true)
    end
  end

  # What the view holds under the filters, as the browser draws it.
  defp load_view(socket) do
    %{root_map_view: %{bbox: bbox, zoom: zoom}} = socket.assigns

    case Social.list_map_cells(
           socket.assigns.current_profile,
           social_filters(socket.assigns),
           bbox,
           zoom
         ) do
      {:ok, cells} ->
        {%{
           ok: true,
           places: Enum.map(cells.places, &AppApi.place_payload/1),
           clusters: cells.clusters,
           total: cells.total
         }, assign(socket, root_map_total: cells.total, root_map_error?: false)}

      {:error, :timeout} ->
        {%{ok: false}, assign(socket, root_map_error?: true)}
    end
  end

  # After a filter changed: the count again, and the view to the map.
  defp refresh(socket) do
    socket = socket |> assign(:root_map_spot, nil) |> load_extent()

    if socket.assigns.root_map_view do
      {payload, socket} = load_view(socket)
      push_event(socket, "root_map_data", payload)
    else
      socket
    end
  end

  @doc "The filters as `Social.list_map_cells/4` takes them."
  def social_filters(assigns) do
    filters = assigns.root_map_filters
    {from, to} = moments(filters, Map.get(assigns, :calendar_time_zone, "Etc/UTC"))

    %{
      search: filters.search,
      preset: filters.preset,
      relation: filters.relation,
      public?: assigns.show_public_sub_groups == true,
      time: filters.time,
      from: from,
      to: to
    }
  end

  defp moments(%{period: "custom", from: from, to: to}, zone),
    do: {from && day_start(from, zone), to && day_start(Date.add(to, 1), zone)}

  defp moments(%{period: period}, _zone) do
    now = DateTime.utc_now()

    case period do
      "24h" -> {DateTime.add(now, -1, :day), nil}
      "7d" -> {DateTime.add(now, -7, :day), nil}
      "30d" -> {DateTime.add(now, -30, :day), nil}
      "12m" -> {DateTime.add(now, -365, :day), nil}
      _any -> {nil, nil}
    end
  end

  # Midnight in the viewer's zone, or the first moment of a day that skips it.
  defp day_start(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, moment} -> moment
      {:ambiguous, first, _second} -> first
      {:gap, _before, just_after} -> just_after
      {:error, _reason} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  ## Events

  # The browser's view: `bbox` is `[west, south, east, north]`.
  def handle_event("root_map_view", %{"bbox" => bbox, "zoom" => zoom}, socket) do
    with true <- root?(socket),
         [_, _, _, _] = bbox <- numbers(bbox),
         zoom when is_integer(zoom) and zoom in 0..24 <- zoom,
         :ok <- RateLimit.hit(:root_map_view, socket.assigns.current_profile.id) do
      {payload, socket} =
        socket
        |> assign(:root_map_view, %{bbox: bbox, zoom: zoom})
        |> load_view()

      {:reply, payload, socket}
    else
      {:error, :rate_limited, _retry_after} ->
        {:reply, %{ok: false, error: "rate_limited"}, socket}

      _invalid ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("root_map_open", %{"id" => id}, socket) do
    with true <- root?(socket),
         {id, ""} <- Integer.parse(to_string(id)),
         %Group{} = group <-
           Social.get_visible_group_below(
             socket.assigns.group,
             socket.assigns.current_profile,
             id
           ) do
      {:noreply, socket |> assign(:root_map_spot, nil) |> GroupSheet.open(group)}
    else
      _not_found -> {:noreply, socket}
    end
  end

  # A cluster that cannot spread any further: its groups in a list.
  def handle_event("root_map_spot", %{"bounds" => [south_west, north_east]}, socket) do
    with true <- root?(socket),
         [south, west] <- numbers(south_west),
         [north, east] <- numbers(north_east),
         {:ok, {groups, more?}} <-
           Social.list_map_spot(
             socket.assigns.current_profile,
             social_filters(socket.assigns),
             [[south, west], [north, east]],
             @spot_limit
           ) do
      {:noreply, assign(socket, :root_map_spot, %{groups: groups, more?: more?})}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("root_map_spot_close", _params, socket),
    do: {:noreply, assign(socket, :root_map_spot, nil)}

  def handle_event("root_map_fit", _params, socket) do
    socket = load_extent(socket)

    case socket.assigns.root_map_extent do
      %{bounds: [_, _] = bounds} ->
        {:noreply, push_event(socket, "root_map_fit", %{bounds: bounds})}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("root_map_search", %{"root_map_search" => %{"q" => query}}, socket)
      when is_binary(query),
      do: put_filter(socket, :search, query |> String.trim() |> String.slice(0, 120))

  def handle_event("root_map_clear_search", _params, socket),
    do: put_filter(socket, :search, "")

  def handle_event("root_map_preset", %{"preset" => preset}, socket) do
    cond do
      preset == "" -> put_filter(socket, :preset, nil)
      preset in GroupPresets.filter_keys() -> put_filter(socket, :preset, preset)
      true -> {:noreply, socket}
    end
  end

  def handle_event("root_map_relation", %{"relation" => relation}, socket) do
    cond do
      relation == "" -> put_filter(socket, :relation, nil)
      relation in Social.child_group_relations() -> put_filter(socket, :relation, relation)
      true -> {:noreply, socket}
    end
  end

  def handle_event("root_map_time", %{"time" => time}, socket) do
    case time do
      "created" -> put_filter(socket, :time, :created)
      "active" -> put_filter(socket, :time, :active)
      _other -> {:noreply, socket}
    end
  end

  def handle_event("root_map_period", %{"period" => period}, socket) when period in @periods do
    filters = %{socket.assigns.root_map_filters | period: period, from: nil, to: nil}

    {:noreply,
     socket
     |> assign(:root_map_filters, filters)
     |> assign_range_form(%{})
     |> refresh()}
  end

  # Dates the viewer picked, in their zone: either end may stay open.
  def handle_event("root_map_range", %{"root_map_range" => params}, socket) when is_map(params) do
    case {parse_date(params["from"]), parse_date(params["to"])} do
      {nil, nil} ->
        {:noreply, socket}

      {from, to} ->
        {from, to} = if from && to && Date.after?(from, to), do: {to, from}, else: {from, to}
        filters = %{socket.assigns.root_map_filters | period: "custom", from: from, to: to}

        {:noreply,
         socket
         |> assign(:root_map_filters, filters)
         |> assign_range_form(%{"from" => date_value(from), "to" => date_value(to)})
         |> refresh()}
    end
  end

  # The same switch as the sub-groups tab's: the browser keeps the choice.
  def handle_event("root_map_toggle_public", _params, socket) do
    if root?(socket) do
      show? = not socket.assigns.show_public_sub_groups

      {:noreply,
       socket
       |> assign(:show_public_sub_groups, show?)
       |> push_event("sub_groups_public", %{shown: show?})
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("root_map_clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:root_map_filters, default_filters())
     |> assign_range_form(%{})
     |> refresh()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp put_filter(socket, key, value) do
    if root?(socket) and Map.fetch!(socket.assigns.root_map_filters, key) != value do
      {:noreply,
       socket
       |> assign(:root_map_filters, Map.put(socket.assigns.root_map_filters, key, value))
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  defp root?(socket), do: match?(%Group{is_root: true}, socket.assigns.group)

  defp assign_range_form(socket, params),
    do: assign(socket, :root_map_range_form, to_form(params, as: :root_map_range))

  defp numbers(list) when is_list(list) do
    if Enum.all?(list, &(is_number(&1) and abs(&1) <= 100_000)), do: list
  end

  defp numbers(_other), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp date_value(nil), do: ""
  defp date_value(date), do: Date.to_iso8601(date)
end
