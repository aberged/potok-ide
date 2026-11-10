defmodule PotokIdeWeb.PinIcons do
  @moduledoc """
  How the pins of `PotokIde.Social.GroupPins` look and what they are called:
  a drop in the pin's tone with a white Heroicons glyph (24, solid).

  The glyphs' paths are read from `deps/heroicons` while compiling, so the
  pins in a group's settings and in a map app are drawn from one source, and
  a map gets them from the page (`map_config`) instead of carrying its own.
  Being paths and not `hero-*` classes, they need nothing from Tailwind.
  """
  use Phoenix.Component
  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Social.GroupPins
  alias PotokIdeWeb.GroupLive.Show.CreateMenu

  # The dependency is a sparse checkout of `optimized`, which Mix reports as its path.
  @heroicons Mix.Project.deps_paths()[:heroicons]
  @optimized if(File.dir?(Path.join(@heroicons, "24")),
               do: @heroicons,
               else: Path.join(@heroicons, "optimized")
             )
  @solid_dir Path.join(@optimized, "24/solid")
  # The small glyphs, the avatar's `hero-*-micro`.
  @micro_dir Path.join(@optimized, "16/solid")

  # A drop on a 32 x 40 box: a circle of radius 14 around (16, 15) with its
  # point at the bottom. The glyph sits in the circle at 18 px.
  @drop "M16 38.5C11 33 2 24 2 15a14 14 0 1 1 28 0c0 9-9 18-14 23.5Z"
  @glyph_transform "translate(7 6) scale(0.75)"

  # A picked pin keeps its group's kind in a white disc of radius 5.5 around
  # (26.5, 6.5), at the top right as on the avatar: the 16 px glyph at 7.5 px.
  @mark_transform "translate(22.75 2.75) scale(0.46875)"

  read_paths = fn dir, name ->
    file = Path.join(dir, name <> ".svg")
    Module.put_attribute(__MODULE__, :external_resource, file)

    paths =
      ~r/<path\b([^>]*)\/>/
      |> Regex.scan(File.read!(file), capture: :all_but_first)
      |> Enum.map(fn [attrs] ->
        [_, d] = Regex.run(~r/\bd="([^"]+)"/, attrs)
        %{d: d, evenodd: String.contains?(attrs, ~s(fill-rule="evenodd"))}
      end)

    if paths == [], do: raise("no paths in #{file}")
    paths
  end

  @paths Map.new(GroupPins.heroicons(), &{&1, read_paths.(@solid_dir, &1)})

  # A group without a kind has no mark, on its avatar or on its pin.
  @marks (for {kind, icon} <- GroupPins.kinds(), kind != "none", into: %{} do
            {kind, read_paths.(@micro_dir, icon)}
          end)

  @doc "The drop's outline, for a map to draw the same pin."
  def drop, do: @drop

  @doc "Where the glyph goes in the drop, as an SVG transform."
  def glyph_transform, do: @glyph_transform

  @doc "The paths of the Heroicons glyph `name`."
  def paths(name), do: Map.fetch!(@paths, name)

  @doc "Where the kind's mark goes on a picked pin, as an SVG transform."
  def mark_transform, do: @mark_transform

  @doc """
  The small glyph of the kind `kind` that a picked pin keeps in its corner,
  as on the avatar; nil for a group without a kind.
  """
  def mark(kind), do: Map.get(@marks, kind)

  @doc """
  What a map needs to draw every pin: the drop, the tones, the kinds and the
  icons with their names in the viewer's language. Each kind also has the
  `mark` a picked pin shows in its corner, placed by `mark_transform`.
  """
  def catalogue do
    %{
      drop: @drop,
      glyph_transform: @glyph_transform,
      mark_transform: @mark_transform,
      tones: Map.new(GroupPins.tones(), fn {tone, color} -> {Atom.to_string(tone), color} end),
      kinds:
        for {kind, icon} <- GroupPins.kinds() do
          %{
            key: kind,
            title: kind_label(kind),
            tone: "kind",
            paths: paths(icon),
            mark: mark(kind)
          }
        end,
      icons:
        for {key, icon, tone} <- GroupPins.icons() do
          %{key: key, title: label(key), tone: Atom.to_string(tone), paths: paths(icon)}
        end
    }
  end

  @doc """
  The tone and glyph `group` shows: its own pin, or its kind's. A pin of its
  own keeps the kind's `mark` in its corner.
  """
  def look(group) do
    kind = GroupPins.kind(group)

    case GroupPins.pin(group) do
      nil -> kind_look(kind)
      "picture" -> %{kind_look(kind) | picture: true, mark: mark(kind)}
      key -> %{icon_look(key) | mark: mark(kind)}
    end
  end

  @doc "The tone and glyph of the kind `kind`."
  def kind_look(kind) do
    {^kind, icon} = List.keyfind(GroupPins.kinds(), kind, 0)
    %{color: GroupPins.tone_color(:kind), paths: paths(icon), picture: false, mark: nil}
  end

  @doc "The tone and glyph of the icon pin `key`."
  def icon_look(key) do
    {^key, icon, tone} = List.keyfind(GroupPins.icons(), key, 0)
    %{color: GroupPins.tone_color(tone), paths: paths(icon), picture: false, mark: nil}
  end

  @doc """
  The icon pins in the sections of a list, as `%{title, keys}`: places, the
  community, nature, and reports with alerts.
  """
  def sections do
    GroupPins.icons()
    |> Enum.chunk_by(fn {_key, _icon, tone} -> section_title(tone) end)
    |> Enum.map(fn [{_key, _icon, tone} | _] = chunk ->
      %{title: section_title(tone), keys: Enum.map(chunk, &elem(&1, 0))}
    end)
  end

  @doc "The title of the section of pins in `tone`."
  def section_title(:places), do: gettext("Places and services")
  def section_title(:community), do: gettext("Community and events")
  def section_title(:nature), do: gettext("Nature and sights")
  def section_title(_reports), do: gettext("Reports and safety")

  @doc "The name of a kind on a map: the preset's, an app's or none."
  def kind_label(kind) do
    case Enum.find(CreateMenu.kinds(), &(&1.key == kind)) do
      %{title: title} ->
        title

      nil ->
        case kind do
          "map" -> gettext("Map")
          "app" -> gettext("App")
          _none -> gettext("No kind")
        end
    end
  end

  @doc "The name of the icon pin `key`."
  def label("shop"), do: gettext("Shop")
  def label("market"), do: gettext("Market")
  def label("food"), do: gettext("Food and drink")
  def label("home"), do: gettext("Home and lodging")
  def label("office"), do: gettext("Company")
  def label("institution"), do: gettext("Institution and culture")
  def label("school"), do: gettext("School")
  def label("health"), do: gettext("Health")
  def label("repair"), do: gettext("Repairs")
  def label("transport"), do: gettext("Transport and delivery")
  def label("money"), do: gettext("Money and ATM")
  def label("municipality"), do: gettext("Municipality")
  def label("event"), do: gettext("Event")
  def label("show"), do: gettext("Show and tickets")
  def label("association"), do: gettext("Association")
  def label("help"), do: gettext("Help and volunteering")
  def label("meetup"), do: gettext("Meeting point")
  def label("sport"), do: gettext("Sport")
  def label("music"), do: gettext("Music")
  def label("art"), do: gettext("Art")
  def label("local_community"), do: gettext("Local community")
  def label("nature"), do: gettext("Nature and outings")
  def label("sight"), do: gettext("Sight and viewpoint")
  def label("favorite"), do: gettext("Recommended")
  def label("place"), do: gettext("Place")
  def label("problem"), do: gettext("Problem to report")
  def label("emergency"), do: gettext("Danger")
  def label("safety"), do: gettext("Safety")
  def label("waste"), do: gettext("Waste and recycling")
  def label("power"), do: gettext("Power and outages")
  def label("idea"), do: gettext("Idea and initiative")

  attr :id, :string,
    required: true,
    doc: "unique on the page: the SVG's, and it names the picture's clip"

  attr :color, :string, required: true
  attr :paths, :list, required: true
  attr :picture_url, :string, default: nil, doc: "the group's picture, drawn in the drop"
  attr :mark, :list, default: nil, doc: "the kind's small glyph, in the top right corner"
  attr :class, :any, default: "h-10 w-8"

  @doc """
  A pin as an SVG: the drop with a glyph, or with the group's picture, and
  the kind's mark when the group picked its pin (`look/1`).
  """
  def pin(assigns) do
    assigns =
      assign(assigns,
        drop: @drop,
        glyph_transform: @glyph_transform,
        mark_transform: @mark_transform,
        mark_color: GroupPins.tone_color(:kind)
      )

    ~H"""
    <svg id={@id} viewBox="0 0 32 40" class={@class} aria-hidden="true" focusable="false">
      <defs :if={@picture_url}>
        <clipPath id={"#{@id}-clip"}><circle cx="16" cy="15" r="12" /></clipPath>
      </defs>
      <path
        d={@drop}
        fill={@color}
        stroke="#ffffff"
        stroke-width="1.75"
        stroke-linejoin="round"
      />
      <image
        :if={@picture_url}
        href={@picture_url}
        x="4"
        y="3"
        width="24"
        height="24"
        preserveAspectRatio="xMidYMid slice"
        clip-path={"url(##{@id}-clip)"}
      />
      <g :if={!@picture_url} transform={@glyph_transform} fill="#ffffff">
        <path
          :for={path <- @paths}
          d={path.d}
          fill-rule={if(path.evenodd, do: "evenodd")}
          clip-rule={if(path.evenodd, do: "evenodd")}
        />
      </g>
      <g :if={@mark} data-pin-mark>
        <circle cx="26.5" cy="6.5" r="5.5" fill="#ffffff" />
        <g transform={@mark_transform} fill={@mark_color}>
          <path
            :for={path <- @mark}
            d={path.d}
            fill-rule={if(path.evenodd, do: "evenodd")}
            clip-rule={if(path.evenodd, do: "evenodd")}
          />
        </g>
      </g>
    </svg>
    """
  end
end
