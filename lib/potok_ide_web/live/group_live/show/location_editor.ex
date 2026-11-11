defmodule PotokIdeWeb.GroupLive.Show.LocationEditor do
  @moduledoc """
  The parts of a place picked on a map (`location_picker.js`), shared by a
  group's Location card and an event's place: the switch between a point, an
  area and a route, its hints and tools, and what the map's hook reads from
  the page (the ids of the tools and its messages). `prefix` names the ids of
  the tools, as `group` gives `group-area-undo`.
  """
  use PotokIdeWeb, :html

  @doc """
  The data attributes of a map with the area and route tools named by
  `prefix`, and the messages it shows, for `{...}` on its element.
  """
  def picker_attrs(prefix) do
    [
      {"data-area-undo", "#{prefix}-area-undo"},
      {"data-area-remove-corner", "#{prefix}-area-remove-corner"},
      {"data-area-restart", "#{prefix}-area-restart"},
      {"data-area-import", "#{prefix}-area-import"},
      {"data-area-status", "#{prefix}-area-status"},
      {"data-area-choices", "#{prefix}-area-choices"},
      {"data-route-undo", "#{prefix}-route-undo"},
      {"data-route-remove-point", "#{prefix}-route-remove-point"},
      {"data-route-reverse", "#{prefix}-route-reverse"},
      {"data-route-restart", "#{prefix}-route-restart"},
      {"data-route-import", "#{prefix}-route-import"},
      {"data-msg-crosses", gettext("The border crosses itself: move a corner.")},
      {"data-msg-corners", gettext("An area needs at least three corners.")},
      {"data-msg-fixed",
       gettext(
         "A border from a file (points: %{points}, parts: %{parts}). Bring another file or draw it again to change it.",
         points: "%{points}",
         parts: "%{parts}"
       )},
      {"data-msg-no-area", gettext("The file holds no area (Polygon or MultiPolygon).")},
      {"data-msg-not-geographic",
       gettext(
         "The file's coordinates are not longitude and latitude (WGS 84, EPSG:4326). Convert it, for example in QGIS or on mapshaper.org."
       )},
      {"data-msg-file", gettext("The file is not GeoJSON.")},
      {"data-msg-too-big", gettext("The file is larger than 5 MB.")},
      {"data-msg-simplified",
       gettext("The border was simplified to %{to} of its %{from} points.",
         to: "%{to}",
         from: "%{from}"
       )},
      {"data-msg-pick", gettext("The file holds %{count} areas. Pick one:", count: "%{count}")},
      {"data-msg-unnamed", gettext("Area %{number}", number: "%{number}")},
      {"data-msg-route-points", gettext("A route needs at least two points.")},
      {"data-msg-route-length", gettext("Length: %{length}.", length: "%{length}")},
      {"data-msg-route-fixed",
       gettext(
         "A route from a file (points: %{points}, parts: %{parts}). Bring another file or draw it again to change it.",
         points: "%{points}",
         parts: "%{parts}"
       )},
      {"data-msg-no-route", gettext("The file holds no route (a track or a line).")},
      {"data-msg-route-file", gettext("The file is not GPX, KML or GeoJSON.")},
      {"data-msg-kmz",
       gettext("A KMZ file is a zipped KML: unzip it and bring the KML file inside.")},
      {"data-msg-route-too-big", gettext("The file is larger than 20 MB.")},
      {"data-msg-route-simplified",
       gettext("The route was simplified to %{to} of its %{from} points.",
         to: "%{to}",
         from: "%{from}"
       )},
      {"data-msg-route-pick",
       gettext("The file holds %{count} routes. Pick one:", count: "%{count}")},
      {"data-msg-route-unnamed", gettext("Route %{number}", number: "%{number}")}
    ]
  end

  attr :id, :string,
    required: true,
    doc: "the switch's; each mode's button adds `-point` and so on"

  attr :mode, :string, required: true, doc: ~s{"point", "area" or "route"}
  attr :event, :string, required: true, doc: "sent with the mode picked"
  attr :class, :any, default: nil

  @doc "The switch between a point, an area and a route."
  def mode_switch(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-label={gettext("A point, an area or a route")}
      class={["grid grid-cols-3 gap-1 rounded-2xl bg-base-200 p-1", @class]}
    >
      <button
        :for={
          {mode, icon, label} <- [
            {"point", "hero-map-pin", gettext("Point")},
            {"area", "hero-viewfinder-circle", gettext("Area")},
            {"route", "hero-arrow-turn-up-right", gettext("Route")}
          ]
        }
        id={"#{@id}-#{mode}"}
        type="button"
        role="radio"
        aria-checked={to_string(@mode == mode)}
        phx-click={@event}
        phx-value-mode={mode}
        class={[
          "inline-flex min-w-0 cursor-pointer items-center justify-center gap-1.5 rounded-xl px-2 py-1.5 text-sm font-semibold transition duration-150 ease-out active:scale-95 sm:px-3",
          if(@mode == mode,
            do: "bg-base-100 text-base-content shadow-sm",
            else: "text-base-content/65 hover:text-base-content"
          )
        ]}
      >
        <.icon name={icon} class="size-4" />
        {label}
      </button>
    </div>
    """
  end

  attr :prefix, :string, required: true
  attr :mode, :string, required: true

  @doc "How an area or a route is drawn, for the mode on screen."
  def shape_hint(assigns) do
    ~H"""
    <p :if={@mode == "area"} id={"#{@prefix}-area-hint"} class="mb-3 text-xs text-base-content/65">
      {gettext(
        "An area, such as a local community's, covers its whole border: tap the map to put its corners, drag a corner to move it, and tap the dot between two corners to add one. A border can also come from a GeoJSON file. Its pin stands inside it by itself."
      )}
    </p>
    <p
      :if={@mode == "route"}
      id={"#{@prefix}-route-hint"}
      class="mb-3 text-xs text-base-content/65"
    >
      {gettext(
        "A route, such as a walk, a race or a bike path, runs along a line: tap the map to add its points in order, drag a point to move it, and tap the dot between two points to add one. A route can also come from a GPX, KML or GeoJSON file. Its pin stands at its start."
      )}
    </p>
    """
  end

  attr :prefix, :string, required: true
  attr :mode, :string, required: true

  @doc """
  The tools of an area and of a route, shown for their mode. The map's hook
  enables them as the drawing allows.
  """
  def shape_tools(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-area-tools"}
      class={["mt-3 flex flex-wrap gap-2", @mode != "area" && "hidden"]}
    >
      <.tool id={"#{@prefix}-area-undo"} icon="hero-arrow-uturn-left" label={gettext("Undo")} />
      <.tool
        id={"#{@prefix}-area-remove-corner"}
        icon="hero-minus-circle"
        label={gettext("Remove corner")}
      />
      <.tool id={"#{@prefix}-area-restart"} icon="hero-arrow-path" label={gettext("Draw again")} />
      <.button id={"#{@prefix}-area-import"} type="button" variant="soft" size="sm">
        <.icon name="hero-arrow-up-tray" class="size-4" />
        {gettext("GeoJSON file")}
      </.button>
    </div>
    <div
      id={"#{@prefix}-route-tools"}
      class={["mt-3 flex flex-wrap gap-2", @mode != "route" && "hidden"]}
    >
      <.tool id={"#{@prefix}-route-undo"} icon="hero-arrow-uturn-left" label={gettext("Undo")} />
      <.tool
        id={"#{@prefix}-route-remove-point"}
        icon="hero-minus-circle"
        label={gettext("Remove point")}
      />
      <.tool
        id={"#{@prefix}-route-reverse"}
        icon="hero-arrows-right-left"
        label={gettext("Reverse direction")}
      />
      <.tool id={"#{@prefix}-route-restart"} icon="hero-arrow-path" label={gettext("Draw again")} />
      <.button id={"#{@prefix}-route-import"} type="button" variant="soft" size="sm">
        <.icon name="hero-arrow-up-tray" class="size-4" />
        {gettext("GPX, KML or GeoJSON file")}
      </.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  # A tool starts disabled; the map's hook enables it, and patches leave that
  # to the hook.
  defp tool(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      variant="soft"
      size="sm"
      disabled
      phx-mounted={JS.ignore_attributes(["disabled"])}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.button>
    """
  end
end
