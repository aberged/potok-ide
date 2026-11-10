defmodule PotokIde.Social.GroupPins do
  @moduledoc """
  The pins a group with a place on a map can show (`Group.pin_icon`). Nil shows
  the group's kind, as its avatar's mark does; `"picture"` shows the group's
  own picture; any other key is one of the icons below.

  A key is a plain string checked here, not in the database, so a new pin
  needs no migration. A key this list no longer has shows as the group's kind.

  Icons are Heroicons file names (`deps/heroicons`), drawn white on the tone's
  colour; `PotokIdeWeb.PinIcons` reads their paths and names them.
  """

  alias PotokIde.Social.GroupPresets

  @picture "picture"

  # {key, Heroicons name, tone}, in the order the settings show them.
  @icons [
    # Places and services
    {"shop", "building-storefront", :places},
    {"market", "shopping-cart", :places},
    {"food", "cake", :places},
    {"home", "home", :places},
    {"office", "building-office-2", :places},
    {"institution", "building-library", :places},
    {"school", "academic-cap", :places},
    {"health", "heart", :places},
    {"repair", "wrench-screwdriver", :places},
    {"transport", "truck", :places},
    {"money", "banknotes", :places},
    {"municipality", "identification", :places},
    # Community and events
    {"event", "calendar-days", :community},
    {"show", "ticket", :community},
    {"association", "user-group", :community},
    {"help", "hand-raised", :community},
    {"meetup", "flag", :community},
    {"route", "arrow-turn-up-right", :community},
    {"sport", "trophy", :community},
    {"music", "musical-note", :community},
    {"art", "paint-brush", :community},
    {"local_community", "home-modern", :community},
    # Nature and sights
    {"nature", "sun", :nature},
    {"sight", "camera", :nature},
    {"favorite", "star", :nature},
    {"place", "map-pin", :nature},
    # Reports and safety
    {"problem", "exclamation-triangle", :alert},
    {"emergency", "fire", :alert},
    {"safety", "shield-check", :reports},
    {"waste", "trash", :reports},
    {"power", "bolt", :reports},
    {"idea", "light-bulb", :reports}
  ]

  # What a group shows by its kind: the icons of `CreateMenu.presets/0`.
  @kinds [
    {"chat", "chat-bubble-left-right"},
    {"folder", "folder"},
    {"announcements", "megaphone"},
    {"feed", "newspaper"},
    {"polls", "chart-bar"},
    {"questionnaire", "clipboard-document-list"},
    {"page", "document-text"},
    {"map", "map"},
    {"app", "puzzle-piece"},
    {"none", "map-pin"}
  ]

  # Each tone carries white icons at 4.5:1 or more, in both themes.
  @tones %{
    kind: "#0a5bc4",
    places: "#0f766e",
    community: "#6d28d9",
    nature: "#15803d",
    reports: "#c2410c",
    alert: "#b91c1c"
  }

  @keys Enum.map(@icons, &elem(&1, 0))

  @doc "Every key `Group.pin_icon` takes."
  def keys, do: [@picture | @keys]

  @doc "The icon pins in order, as `{key, heroicon, tone}`."
  def icons, do: @icons

  @doc "The keys of the icon pins, in order: what a map filters by."
  def icon_keys, do: @keys

  @doc "The kinds a pin can show, as `{kind, heroicon}`."
  def kinds, do: @kinds

  @doc "Every Heroicons name a pin draws."
  def heroicons do
    (Enum.map(@icons, &elem(&1, 1)) ++ Enum.map(@kinds, &elem(&1, 1)))
    |> Enum.uniq()
  end

  @doc "The colour of `tone`."
  def tone_color(tone), do: Map.fetch!(@tones, tone)

  def tones, do: @tones

  @doc "The key of the picture pin."
  def picture, do: @picture

  @doc """
  The kind a group shows on a map: its preset while it fits it
  (`GroupPresets.shown/1`), `"app"` for any other app and `"none"` otherwise.
  """
  def kind(group) do
    case GroupPresets.shown(group) do
      nil -> if Map.get(group, :uses_api) == true, do: "app", else: "none"
      preset -> Atom.to_string(preset)
    end
  end

  @doc """
  The pin `group` shows: its own choice while this list still has it, the
  kind's otherwise.
  """
  def pin(group) do
    case Map.get(group, :pin_icon) do
      key when key in @keys or key == @picture -> key
      _kind -> nil
    end
  end
end
