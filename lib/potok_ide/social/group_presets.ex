defmodule PotokIde.Social.GroupPresets do
  @moduledoc """
  Ready setups for a new group. A preset fills in what any group can have, so
  all of it can be changed later on the group's settings and roles. The group
  keeps only the preset's name (`Group.preset`), for the mark on its avatar,
  which shows while the group still fits it (`shown/1`).
  `Social.create_group/3` stays the way to set everything by hand.

  The apps of a feed, of a group for polls and of a form are files in
  `priv/apps`, copied by `mix potok.sync_apps`. Each group keeps its own copy in
  its description, as with a pasted app, so a new build reaches only the groups
  made after it.

  `Social.create_group_from_preset/4` puts a preset to work.
  """

  alias PotokIde.Social.Group

  # The form's key is not "form", whose element id the menu's own form has.
  @keys ~w(chat folder announcements feed polls questionnaire page)

  # The presets whose group opens on an app.
  @apps ~w(feed polls questionnaire)a

  # Feed finds its stories by this exact name: see `docs/feed-i-feedcreator.md`.
  @feed_group ".feed"

  # What a member keeps here is reading, reacting and voting. Threads go too: a
  # member could open one and not write in it, as it would inherit these rights.
  @read_only ~w(post_values attach_files open_threads create_subgroups create_polls)a

  @chosen_by_viewer ~w(name is_public inherits_members)

  def keys, do: @keys

  @doc "The presets whose group opens on an app, as strings."
  def app_keys, do: Enum.map(@apps, &Atom.to_string/1)

  @doc """
  What the sub-groups list can be narrowed to: the kind `shown/1` gives, or
  `"none"` for the groups it gives none.
  """
  def filter_keys, do: @keys ++ ["none"]

  @doc "The value of `Group.preset` for a group made from `preset`."
  def preset(preset) when preset in @keys, do: String.to_existing_atom(preset)

  @doc """
  The preset `group` was made from while it still fits: one with an app while
  the group has an app, any other while it has none. Nil for a group made by
  hand, or before presets were kept.
  """
  def shown(group) do
    preset = Map.get(group, :preset)
    app? = Map.get(group, :uses_api) == true

    if preset && preset in @apps == app?, do: preset
  end

  @doc """
  What the viewer starts from for what is theirs to pick. Only a feed is
  public, and not under a closed group, which it would show to everyone.
  """
  def defaults(preset, %Group{} = parent) when preset in @keys do
    %{
      "is_public" => preset == "feed" and (parent.is_root or parent.is_public),
      "inherits_members" => not parent.is_root
    }
  end

  @doc "The attributes of a group from `preset`, with what the viewer picked in `choices`."
  def attrs(preset, choices) when preset in @keys do
    preset
    |> preset_attrs()
    |> Map.merge(Map.take(choices, @chosen_by_viewer))
  end

  @doc "The attributes of the `.feed` under the Feed group `group`."
  def feed_attrs(%Group{} = group) do
    %{
      "name" => @feed_group,
      "description" => app("feed_creator.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description,
      "is_public" => group.is_public,
      "inherits_members" => true
    }
  end

  @doc "The permissions `everyone` loses in a group from `preset`."
  def taken_from_everyone("announcements"), do: @read_only
  def taken_from_everyone(preset) when preset in @keys, do: []

  @doc "What `everyone` loses in `.feed`: a group made there by hand would go straight into the feed."
  def taken_from_everyone_in_feed, do: [:create_subgroups]

  defp preset_attrs("chat"), do: plain(:chat)
  defp preset_attrs("announcements"), do: plain(:chat)
  defp preset_attrs("folder"), do: plain(:subgroups)
  defp preset_attrs("page"), do: plain(:description)

  defp preset_attrs("feed") do
    %{
      "description" => app("feed.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  defp preset_attrs("polls") do
    %{
      "description" => app("glasanje.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  # The Form app keeps its questions and answers in the group's app data, under
  # rules its editors set there (`PotokIde.Social.AppData`). Its file groups come
  # when it first needs them, not with every form.
  defp preset_attrs("questionnaire") do
    %{
      "description" => app("forme.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  defp plain(home_page) do
    %{"description" => "", "description_format" => :markdown, "home_page" => home_page}
  end

  defp app(file) do
    :potok_ide
    |> Application.app_dir(Path.join("priv/apps", file))
    |> File.read!()
  end
end
