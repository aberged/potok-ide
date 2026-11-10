defmodule PotokIdeWeb.GroupLive.Show.RootMapState do
  @moduledoc """
  The map tab of the root group (`/groups/:root/map`): every group with a place
  the viewer sees, at any depth. `GroupLive.Show` delegates every
  `"root_map_*"` event here.

  The browser draws the map (`root_map.js`) and asks for what lies in its view
  as it moves; the server gathers the groups into clusters on a grid
  (`Social.list_map_cells/4`), so a phone draws a few hundred markers however
  many groups there are. The filters live here, in assigns: the root's
  sub-group filters (public groups, membership, kind, name), the pins groups
  show (any of those picked), the areas they lie in, and a time frame, any
  time until the viewer picks another. They are not remembered, except the
  public groups switch, which is the same one as in the sub-groups tab.

  An area (`GroupAreas`) is only the shape of its group: the filters keep it
  or leave it out like any group, its pin gathers into clusters like any
  other, and once it is wide enough on the screen its border is drawn under
  the pins as well. Everything the map says comes from that one set
  (`Social.list_map_cells/4`): the pins, the borders, the count, the list of
  a crowded spot and the areas a tap finds. The chosen areas of the area
  filter stay outlined whatever the filters. The browser asks for borders by
  itself and keeps them.

  A route (`GroupRoutes`) is the same: its pin, at its start, gathers with the
  others, and once it is wide enough its line is drawn over the areas. The
  area filter keeps a route that passes through a chosen area. `?route=ID`
  opens the map on one route, drawn whatever the filters.

  Three layers, places, areas and routes, are switched on the map, and the
  browser remembers them.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3]

  alias PotokIde.RateLimit
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas, GroupPins, GroupPresets, GroupRoutes}
  alias PotokIdeWeb.GroupLive.Show.{AppApi, GroupSheet}

  @periods ~w(24h 7d 30d 12m any)
  @default_period "any"
  @spot_limit 50
  # Borders one request may ask for.
  @shapes_limit 100
  # Areas a filter may hold, the ones its menu offers at a time, and the areas
  # a tap on the map lists.
  @area_filter_limit 10
  @area_options_limit 30
  @here_limit 6

  @doc "The time frames of the menu, in its order."
  def periods, do: @periods

  def init(socket) do
    socket
    |> assign(
      root_map_filters: default_filters(),
      root_map_view: nil,
      root_map_extent: nil,
      root_map_total: nil,
      root_map_truncated?: false,
      root_map_spot: nil,
      root_map_error?: false,
      root_map_empty_closed?: false,
      root_map_layers: %{places: true, areas: true, routes: true},
      root_map_here: nil,
      root_map_fit: nil,
      root_map_area_param: nil,
      root_map_route_param: nil,
      root_map_route: nil,
      root_map_area_query: "",
      root_map_area_options: nil,
      root_map_area_chosen: []
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
      to: nil,
      areas: [],
      pins: []
    }
  end

  @doc """
  Why a map that holds no group is empty: `:area` while chosen areas hold
  none, `:filters` while the viewer narrowed it beyond where it starts,
  `:public` while the public groups the viewer is not in are hidden
  (`public?` is the switch), `:none` when it would hold none at all.
  """
  def empty_reason(filters, public?) do
    cond do
      filters.areas != [] -> :area
      Map.delete(filters, :areas) != Map.delete(default_filters(), :areas) -> :filters
      not public? -> :public
      true -> :none
    end
  end

  ## Loading

  @doc """
  Counts the groups the filters keep when the tab opens; the map asks for its
  view by itself. Another tab drops what the map held.
  """
  def maybe_load(socket, %Group{is_root: true}, "map") do
    socket = if socket.assigns.root_map_area_options, do: socket, else: load_area_options(socket)
    if socket.assigns.root_map_extent, do: socket, else: load_extent(socket)
  end

  def maybe_load(socket, _group, _active_tab) do
    assign(socket,
      root_map_view: nil,
      root_map_extent: nil,
      root_map_total: nil,
      root_map_truncated?: false,
      root_map_spot: nil,
      root_map_error?: false,
      root_map_here: nil,
      root_map_area_options: nil
    )
  end

  @doc """
  `?area=ID` opens the map on that area: its pins from any time, the map
  fitted to it once the browser asks for its view. `?route=ID` opens it on
  that route: from any time, fitted to the route, which is drawn whatever
  the filters. An area or a route the viewer cannot see is left out.
  """
  def assign_params(socket, params) do
    socket
    |> assign_area_param(params["area"])
    |> assign_route_param(params["route"])
  end

  defp assign_area_param(socket, param) do
    with true <- param != socket.assigns.root_map_area_param,
         true <- root?(socket),
         {id, ""} <- Integer.parse(to_string(param)),
         [%Group{}] <- GroupAreas.get_visible(socket.assigns.current_profile, [id]) do
      filters = %{
        socket.assigns.root_map_filters
        | areas: [id],
          period: "any",
          from: nil,
          to: nil
      }

      socket
      |> assign(:root_map_area_param, param)
      |> assign(:root_map_filters, filters)
      |> assign(:root_map_extent, nil)
      |> assign(:root_map_fit, GroupAreas.extent(socket.assigns.current_profile, [id]))
      |> assign_chosen()
      |> assign_range_form(%{})
    else
      _other -> assign(socket, :root_map_area_param, param)
    end
  end

  defp assign_route_param(socket, param) do
    with true <- param != socket.assigns.root_map_route_param,
         true <- root?(socket),
         {id, ""} <- Integer.parse(to_string(param)),
         %Group{} = route <- GroupRoutes.get_visible(socket.assigns.current_profile, id) do
      filters = %{socket.assigns.root_map_filters | period: "any", from: nil, to: nil}

      socket
      |> assign(
        root_map_route_param: param,
        root_map_route: route,
        root_map_filters: filters,
        root_map_extent: nil,
        root_map_fit: GroupRoutes.bounds(route)
      )
      |> assign_range_form(%{})
    else
      _other ->
        if param != socket.assigns.root_map_route_param,
          do: assign(socket, root_map_route_param: param, root_map_route: nil),
          else: socket
    end
  end

  @doc "Whether the link's area or route changed while the map stays open."
  def params_changed?(socket, params) do
    params["area"] != socket.assigns.root_map_area_param or
      params["route"] != socket.assigns.root_map_route_param
  end

  def handle_params(socket, params) do
    route = socket.assigns.root_map_route
    socket = assign_params(socket, params)

    if socket.assigns.root_map_fit || socket.assigns.root_map_route != route,
      do: refresh(socket),
      else: socket
  end

  # A new count brings the empty state back, closed or not.
  defp load_extent(socket) do
    socket = assign(socket, :root_map_empty_closed?, false)

    case Social.map_extent(socket.assigns.current_profile, social_filters(socket.assigns)) do
      {:ok, extent} -> assign(socket, root_map_extent: extent, root_map_error?: false)
      {:error, :timeout} -> assign(socket, root_map_extent: nil, root_map_error?: true)
    end
  end

  # What the view holds under the filters, as the browser draws it: pins and
  # clusters, the areas drawn as borders and the routes as lines, the chosen
  # areas of the filter as outlines, the route of the link, and once a box to
  # fit. With every layer off it holds nothing but that route.
  defp load_view(socket) do
    %{root_map_view: %{bbox: bbox, zoom: zoom}, root_map_layers: layers} = socket.assigns

    view =
      if any_layer?(layers),
        do:
          Social.list_map_cells(
            socket.assigns.current_profile,
            social_filters(socket.assigns),
            bbox,
            zoom
          ),
        else: {:ok, nil}

    view_payload(socket, view)
  end

  defp view_payload(socket, {:ok, nil}),
    do:
      view_payload(
        socket,
        {:ok, %{places: [], clusters: [], areas: [], routes: [], total: nil, truncated: false}}
      )

  defp view_payload(socket, {:ok, view}) do
    layers = socket.assigns.root_map_layers

    chosen =
      if layers.areas,
        do:
          Enum.map(
            socket.assigns.root_map_area_chosen,
            &(&1 |> area_payload() |> Map.put(:ctx, true))
          ),
        else: []

    linked = socket.assigns.root_map_route

    routes =
      for route <- view.routes, is_nil(linked) or route.id != linked.id do
        route_payload(route)
      end

    routes =
      if linked, do: routes ++ [linked |> route_payload() |> Map.put(:ctx, true)], else: routes

    payload = %{
      ok: true,
      places: Enum.map(view.places, &AppApi.place_payload/1),
      clusters: view.clusters,
      total: view.total,
      areas: Enum.map(view.areas, &area_payload/1) ++ chosen,
      routes: routes,
      chosen: socket.assigns.root_map_filters.areas,
      layers: layers
    }

    payload =
      if socket.assigns.root_map_fit,
        do: Map.put(payload, :fit, socket.assigns.root_map_fit),
        else: payload

    {payload,
     assign(socket,
       root_map_total: view.total,
       root_map_truncated?: view.truncated,
       root_map_error?: false,
       root_map_fit: nil
     )}
  end

  defp view_payload(socket, {:error, :timeout}),
    do: {%{ok: false}, assign(socket, root_map_error?: true)}

  # An area as the browser draws it: what its pin shows, where its name
  # stands (its pin), its box, and what its border is cached by.
  defp area_payload(%Group{} = group) do
    group
    |> AppApi.place_payload()
    |> Map.merge(%{v: GroupAreas.version(group.updated_at), bbox: GroupAreas.bbox(group)})
  end

  # A route as the browser draws it: what its pin shows, its box, and what
  # its line is cached by.
  defp route_payload(%Group{} = group) do
    group
    |> AppApi.place_payload()
    |> Map.merge(%{v: GroupAreas.version(group.updated_at), bbox: GroupRoutes.bbox(group)})
  end

  defp any_layer?(layers), do: Enum.any?(Map.values(layers))

  # After a filter changed: the count and the view in one go, the cards of
  # the old set closed, the empty state back.
  defp refresh(socket) do
    socket =
      if socket.assigns.root_map_here,
        do: push_event(socket, "root_map_select_area", %{id: nil}),
        else: socket

    socket = assign(socket, root_map_spot: nil, root_map_here: nil, root_map_empty_closed?: false)
    %{root_map_view: view, root_map_layers: layers} = socket.assigns
    view = if view && any_layer?(layers), do: view

    case Social.load_map(socket.assigns.current_profile, social_filters(socket.assigns), view) do
      {:ok, %{extent: extent, view: loaded}} ->
        socket = assign(socket, root_map_extent: extent, root_map_error?: false)

        if socket.assigns.root_map_view do
          {payload, socket} = view_payload(socket, {:ok, loaded})
          push_event(socket, "root_map_data", payload)
        else
          socket
        end

      {:error, :timeout} ->
        assign(socket, root_map_extent: nil, root_map_error?: true)
    end
  end

  # After a layer changed: the view again; the count does not change.
  defp reload_view(socket) do
    if socket.assigns.root_map_view do
      {payload, socket} = load_view(socket)
      push_event(socket, "root_map_data", payload)
    else
      socket
    end
  end

  @doc """
  The filters as `Social.list_map_cells/4` takes them: with the chosen areas,
  the layers, and the zoom of the view, which says the areas wide enough for
  a border, the routes wide enough for a line and the areas a tap finds.
  """
  def social_filters(assigns) do
    filters = assigns.root_map_filters
    {from, to} = moments(filters, Map.get(assigns, :calendar_time_zone, "Etc/UTC"))
    layers = Map.get(assigns, :root_map_layers) || %{areas: false}
    view = Map.get(assigns, :root_map_view) || %{}

    %{
      search: filters.search,
      preset: filters.preset,
      relation: filters.relation,
      public?: assigns.show_public_sub_groups == true,
      time: filters.time,
      from: from,
      to: to,
      areas: filters.areas,
      pins: filters.pins,
      places?: Map.get(layers, :places, true),
      shapes?: layers.areas,
      routes?: Map.get(layers, :routes, false),
      zoom: Map.get(view, :zoom)
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

  # The browser's view: `bbox` is `[west, south, east, north]`, `layers` the
  # ones it remembers.
  def handle_event("root_map_view", %{"bbox" => bbox, "zoom" => zoom} = params, socket) do
    with true <- root?(socket),
         [_, _, _, _] = bbox <- numbers(bbox),
         zoom when is_integer(zoom) and zoom in 0..24 <- zoom,
         :ok <- RateLimit.hit(:root_map_view, socket.assigns.current_profile.id) do
      {payload, socket} =
        socket
        |> assign(:root_map_view, %{bbox: bbox, zoom: zoom})
        |> assign(:root_map_layers, layers(params["layers"], socket.assigns.root_map_layers))
        |> load_view()

      {:reply, payload, socket}
    else
      {:error, :rate_limited, _retry_after} ->
        {:reply, %{ok: false, error: "rate_limited"}, socket}

      _invalid ->
        {:reply, %{ok: false}, socket}
    end
  end

  # The borders the browser lacks, simplified for its zoom.
  def handle_event("root_map_shapes", %{"ids" => ids, "zoom" => zoom}, socket)
      when is_list(ids) and is_integer(zoom) and zoom in 0..24 do
    ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.take(@shapes_limit)

    with true <- root?(socket),
         :ok <- RateLimit.hit(:root_map_view, socket.assigns.current_profile.id) do
      shapes =
        for shape <- GroupAreas.shapes(socket.assigns.current_profile, ids, zoom) do
          %{id: shape.id, v: shape.version, geojson: Jason.Fragment.new(shape.geojson)}
        end

      {:reply, %{ok: true, level: GroupAreas.level(zoom), shapes: shapes}, socket}
    else
      _refused -> {:reply, %{ok: false}, socket}
    end
  end

  # A tap on the map, off the pins: the areas drawn there, smallest first.
  def handle_event("root_map_here", %{"lat" => lat, "lng" => lng, "zoom" => zoom}, socket)
      when is_number(lat) and is_number(lng) and is_integer(zoom) and zoom in 0..24 do
    with true <- root?(socket),
         true <- socket.assigns.root_map_layers.areas,
         true <- abs(lat) <= 90 and abs(lng) <= 100_000 do
      lng = lng - 360.0 * Float.floor((lng + 180.0) / 360.0)

      areas =
        case Social.list_map_areas_at(
               socket.assigns.current_profile,
               social_filters(socket.assigns),
               {lat, lng},
               zoom,
               @here_limit
             ) do
          {:ok, areas} -> areas
          {:error, :timeout} -> []
        end

      ids = Enum.map(areas, & &1.id)
      here = if areas == [], do: nil, else: %{areas: areas, selected: List.first(ids)}

      {:reply, %{ids: ids}, socket |> assign(:root_map_spot, nil) |> assign(:root_map_here, here)}
    else
      _no -> {:reply, %{ids: []}, assign(socket, :root_map_here, nil)}
    end
  end

  def handle_event("root_map_here_pick", %{"id" => id}, socket) do
    with %{areas: areas} = here <- socket.assigns.root_map_here,
         {id, ""} <- Integer.parse(to_string(id)),
         true <- Enum.any?(areas, &(&1.id == id)) do
      {:noreply,
       socket
       |> assign(:root_map_here, %{here | selected: id})
       |> push_event("root_map_select_area", %{id: id})}
    else
      _other -> {:noreply, socket}
    end
  end

  def handle_event("root_map_here_close", _params, socket) do
    {:noreply,
     socket |> assign(:root_map_here, nil) |> push_event("root_map_select_area", %{id: nil})}
  end

  # Fits the map to one area.
  def handle_event("root_map_area_fit", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         [_, _] = bounds <- GroupAreas.extent(socket.assigns.current_profile, [id]) do
      {:noreply, push_event(socket, "root_map_fit", %{bounds: bounds})}
    else
      _none -> {:noreply, socket}
    end
  end

  # An area into the filter or out of it; one put in fits the map to the
  # chosen areas.
  def handle_event("root_map_area", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile
    chosen = socket.assigns.root_map_filters.areas

    with true <- root?(socket),
         {id, ""} <- Integer.parse(to_string(id)) do
      cond do
        id in chosen ->
          {:noreply, socket |> put_areas(List.delete(chosen, id)) |> refresh()}

        length(chosen) < @area_filter_limit and GroupAreas.get_visible(profile, [id]) != [] ->
          areas = chosen ++ [id]

          {:noreply,
           socket
           |> put_areas(areas)
           |> assign(:root_map_fit, GroupAreas.extent(profile, areas))
           |> refresh()}

        true ->
          {:noreply, socket}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  # Only inside one area, from its card: that area alone in the filter, or
  # none when it already is.
  def handle_event("root_map_area_only", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    with true <- root?(socket),
         {id, ""} <- Integer.parse(to_string(id)) do
      cond do
        socket.assigns.root_map_filters.areas == [id] ->
          {:noreply, socket |> put_areas([]) |> refresh()}

        GroupAreas.get_visible(profile, [id]) != [] ->
          {:noreply,
           socket
           |> put_areas([id])
           |> assign(:root_map_fit, GroupAreas.extent(profile, [id]))
           |> refresh()}

        true ->
          {:noreply, socket}
      end
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("root_map_area_clear", _params, socket) do
    if socket.assigns.root_map_filters.areas == [],
      do: {:noreply, socket},
      else: {:noreply, socket |> put_areas([]) |> refresh()}
  end

  def handle_event("root_map_area_search", %{"root_map_area" => %{"q" => query}}, socket)
      when is_binary(query) do
    {:noreply,
     socket
     |> assign(:root_map_area_query, String.slice(query, 0, 120))
     |> load_area_options()}
  end

  # A layer on or off; the browser remembers the choice.
  def handle_event("root_map_layer", %{"layer" => layer}, socket)
      when layer in ["places", "areas", "routes"] do
    if root?(socket) do
      key = Map.fetch!(%{"places" => :places, "areas" => :areas, "routes" => :routes}, layer)
      layers = Map.update!(socket.assigns.root_map_layers, key, &(not &1))

      socket =
        socket
        |> assign(:root_map_layers, layers)
        |> assign(:root_map_here, if(layers.areas, do: socket.assigns.root_map_here))
        |> push_event("root_map_layers", layers)

      {:noreply, reload_view(socket)}
    else
      {:noreply, socket}
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
      {:noreply,
       socket
       |> assign(:root_map_spot, %{groups: groups, more?: more?})
       |> assign(:root_map_here, nil)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("root_map_spot_close", _params, socket),
    do: {:noreply, assign(socket, :root_map_spot, nil)}

  # The empty state steps aside so the map behind it shows, until the
  # filters change.
  def handle_event("root_map_empty_close", _params, socket),
    do: {:noreply, assign(socket, :root_map_empty_closed?, true)}

  # The count already holds the box; it is loaded only when it is not there.
  def handle_event("root_map_fit", _params, socket) do
    socket = if socket.assigns.root_map_extent, do: socket, else: load_extent(socket)

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

  # A pin in or out of the filter; the filter keeps the catalogue's order.
  def handle_event("root_map_pin", %{"pin" => key}, socket) when is_binary(key) do
    pins = socket.assigns.root_map_filters.pins

    cond do
      key in pins ->
        put_filter(socket, :pins, List.delete(pins, key))

      key in pin_keys() ->
        put_filter(socket, :pins, Enum.filter(pin_keys(), &(&1 == key or &1 in pins)))

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("root_map_pin_clear", _params, socket), do: put_filter(socket, :pins, [])

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
     |> assign_chosen()
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

  # What the pin filter takes, in the menu's order: its kind's pin, the
  # group's picture, then the icons.
  defp pin_keys, do: ["kind", GroupPins.picture() | GroupPins.icon_keys()]

  defp put_areas(socket, areas) do
    socket
    |> assign(:root_map_filters, %{socket.assigns.root_map_filters | areas: areas})
    |> assign_chosen()
  end

  # The chosen areas by name, for the filter's button and menu.
  defp assign_chosen(socket) do
    ids = socket.assigns.root_map_filters.areas

    chosen =
      if ids == [], do: [], else: GroupAreas.get_visible(socket.assigns.current_profile, ids)

    assign(socket, :root_map_area_chosen, chosen)
  end

  defp load_area_options(socket) do
    options =
      GroupAreas.search(
        socket.assigns.current_profile,
        socket.assigns.root_map_area_query,
        @area_options_limit
      )

    assign(socket, :root_map_area_options, options)
  end

  # The layers the browser remembers; anything else keeps the ones shown. A
  # browser that remembers no routes (from before they were a layer) keeps
  # the routes shown.
  defp layers(%{"places" => places, "areas" => areas} = remembered, current)
       when is_boolean(places) and is_boolean(areas) do
    routes = remembered["routes"]

    %{
      places: places,
      areas: areas,
      routes: if(is_boolean(routes), do: routes, else: Map.get(current, :routes, true))
    }
  end

  defp layers(_other, current), do: current

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
