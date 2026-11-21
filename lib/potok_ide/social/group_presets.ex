defmodule PotokIde.Social.GroupPresets do
  @moduledoc """
  Ready setups for a new group. A preset fills in what any group can have, so
  all of it can be changed later on the group's settings and roles, its
  picture too: the group starts with its kind's icon (`picture/1`). The group
  keeps only the preset's name (`Group.preset`), for the mark on its avatar,
  which shows while the group still fits it (`shown/1`).
  `Social.create_group/3` stays the way to set everything by hand.

  The apps of a feed, of a group for polls, of a form, of a map and of ordering
  are files in `priv/apps`, copied by `mix potok.sync_apps`. Each group keeps its own copy in
  its description, as with a pasted app; a new build reaches an older group
  when an editor refreshes it (`Social.refresh_app/3`, `AppBuilds`).

  `Social.create_group_from_preset/4` puts a preset to work, and
  `Social.change_group_preset/4` gives a group that stands another kind
  (`change_plan/4` says what that does).
  """

  alias PotokIde.Social.Group

  # The form's key is not "form", whose element id the menu's own form has.
  @keys ~w(chat folder feed polls questionnaire map orders page)

  # The presets whose group opens on an app.
  @apps ~w(feed polls questionnaire map orders)a

  @key_atoms Enum.map(@keys, &String.to_atom/1)

  # Feed finds its stories by this exact name: see `docs/feed-i-feedcreator.md`.
  @feed_group ".feed"

  @chosen_by_viewer ~w(name is_public inherits_members inherit_role_keys)

  def keys, do: @keys

  @doc "The exact name of the sub-group that holds a feed's posts."
  def feed_group_name, do: @feed_group

  @doc """
  The presets a new group under `parent` can start from. The root has its own
  map of every group with a place, so a Map app right under it would show only
  part of that.
  """
  def keys_for(%Group{is_root: true}), do: @keys -- ["map"]
  def keys_for(%Group{}), do: @keys

  @doc "Whether a new group under `parent` can start from `preset`."
  def allowed?(preset, %Group{} = parent), do: preset in keys_for(parent)

  @doc "The presets whose group opens on an app, as strings."
  def app_keys, do: Enum.map(@apps, &Atom.to_string/1)

  @doc """
  What the sub-groups list can be narrowed to: the kind `shown/1` gives,
  `"app"` for an app that fits no preset, or `"none"` for the other groups.
  """
  def filter_keys, do: @keys ++ ["app", "none"]

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

    if preset in @key_atoms and preset in @apps == app?, do: preset
  end

  @doc """
  What the viewer starts from for what is theirs to pick. Only a feed is
  public, and not under a closed group, which it would show to everyone.
  """
  def defaults(preset, %Group{} = parent) when preset in @keys do
    %{
      "is_public" => preset == "feed" and (parent.is_root or parent.is_public),
      "inherits_members" => not parent.is_root,
      "inherit_role_keys" => []
    }
  end

  @doc """
  The attributes of a group from `preset`, with what the viewer picked in
  `choices`. The group starts with its kind's picture (`picture/1`) unless
  `picture: false`.
  """
  def attrs(preset, choices, opts \\ []) when preset in @keys do
    attrs = Map.merge(kind_attrs(preset), Map.take(choices, @chosen_by_viewer))

    if Keyword.get(opts, :picture, true),
      do: Map.put(attrs, "group_picture_url", picture(preset)),
      else: attrs
  end

  @doc """
  The picture a group made from `preset` starts with, as a data URL: the
  preset's icon in the menu, white on Potok's blue (`priv/kinds/build.sh`).
  It is the group's own picture from then on, changed like any other, and a
  PNG, as push notifications cannot show SVG.
  """
  def picture(preset) when preset in @keys do
    png =
      :potok_ide
      |> Application.app_dir(Path.join("priv/kinds", preset <> ".png"))
      |> File.read!()

    "data:image/png;base64," <> Base.encode64(png)
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

  @doc """
  What makes a group of kind `preset` what it is: its description (an app's
  file for the presets with an app) and the page it opens on.
  """
  def kind_attrs(preset) when preset in @keys, do: kind_attrs_of(preset)

  @doc """
  What giving `group` the kind `key` (a preset, or nil for none) would do,
  from `facts` the caller read (`Social.group_kind_facts/2`):

  - `:parent`, the group it stands in;
  - `:alt_names`, the lowercase names of its alternative descriptions, and
    `:max_alts`, how many it may have;
  - `:feed_child?`, whether it holds a `.feed`;
  - `:file_group?`, whether an app of its parent keeps files in it;
  - `:feed_part?`, whether it is the `.feed` of a feed;
  - `:can_create_subgroups?`, whether the editor may make a sub-group in it;
  - `:picture`, its picture as stored.

  A new kind brings its description and the page the group opens on, and its
  picture when the group still has the old kind's or none. What stood in the
  description goes to an alternative description seen only by those who edit
  the group (`park`), with everything its app keeps: always an app, as the
  next one would read what it kept, and a text only when an app replaces it.
  "No kind" (nil) only drops the name of the kind. A feed gets its `.feed`,
  the one it holds if any; a feed that becomes something else keeps it.

  `park_name` names that alternative when the description had no name of its
  own. The page and `Social.change_group_preset/4` both read this, so what
  the editor is told is what happens.
  """
  def change_plan(%Group{} = group, key, facts, park_name)
      when (is_nil(key) or key in @keys) and is_binary(park_name) do
    cond do
      not kind_here?(group, facts) ->
        {:error, :kind_not_here}

      key && not allowed?(key, facts.parent) ->
        {:error, :kind_not_allowed}

      same_kind?(group, key && preset(key)) ->
        {:error, :same_kind}

      true ->
        plan = build_plan(group, key, facts, park_name)

        cond do
          plan.park && length(facts.alt_names) >= facts.max_alts ->
            {:error, :too_many_alt_descriptions}

          plan.feed == :create and not facts.can_create_subgroups? ->
            {:error, :feed_not_permitted}

          true ->
            {:ok, plan}
        end
    end
  end

  @doc """
  Whether `group` has a kind of its own to change: not the root, a direct
  conversation or a thread, and not a part of an app (the files an app keeps,
  the `.feed` of a feed).
  """
  def kind_here?(%Group{} = group, facts) do
    not (group.is_root or group.is_direct or not is_nil(group.parent_value_id) or
           is_nil(facts.parent) or facts.file_group? or facts.feed_part?)
  end

  @doc "Whether `group` could have a kind at all, by what it is (`kind_here?/2` asks more)."
  def kind_possible?(%Group{} = group),
    do: not (group.is_root or group.is_direct or not is_nil(group.parent_value_id))

  defp build_plan(group, key, facts, park_name) do
    park = park(group, key)

    %{
      key: key,
      preset: key && preset(key),
      park:
        park &&
          %{kind: park, name: unique_name(group.description_name || park_name, facts.alt_names)},
      description: description_change(key, park),
      home_page: key && kind_attrs(key)["home_page"],
      feed: if(key == "feed", do: if(facts.feed_child?, do: :reuse, else: :create)),
      leaves_feed: key != "feed" and group.preset == :feed and facts.feed_child?,
      picture: if(key && picture_follows?(group, facts.picture), do: :replace, else: :keep)
    }
  end

  # The kind the group shows already. A group that lost its app (or got one)
  # since is not that kind any more, so picking it again sets it up again.
  defp same_kind?(%Group{preset: preset}, nil), do: is_nil(preset)
  defp same_kind?(group, target), do: shown(group) == target

  defp park(_group, nil), do: nil

  defp park(%Group{} = group, key) do
    written? = String.trim(group.description || "") != ""

    cond do
      group.uses_api and written? -> :app
      key in app_keys() and written? -> :text
      true -> nil
    end
  end

  defp description_change(nil, _park), do: :keep

  defp description_change(key, park) do
    cond do
      key in app_keys() -> :app
      park == :app -> :clear
      true -> :keep
    end
  end

  # The picture is the old kind's while it is that very file; a picture of the
  # group's own, or an older build of the kind's, stays.
  defp picture_follows?(_group, picture) when picture in [nil, ""], do: true

  defp picture_follows?(%Group{preset: preset}, picture) when preset in @key_atoms,
    do: picture == picture(Atom.to_string(preset))

  defp picture_follows?(_group, _picture), do: false

  # Names are unique in a group whatever their case, and at most 60 long.
  defp unique_name(base, taken) do
    base = base |> String.trim() |> String.slice(0, 56)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base} #{n}"
    end)
    |> Enum.find(&(String.downcase(&1) not in taken))
  end

  @doc "What `everyone` loses in `.feed`: a group made there by hand would go straight into the feed."
  def taken_from_everyone_in_feed, do: [:create_subgroups]

  defp kind_attrs_of("chat"), do: plain(:chat)
  defp kind_attrs_of("folder"), do: plain(:subgroups)
  defp kind_attrs_of("page"), do: plain(:description)

  defp kind_attrs_of("feed") do
    %{
      "description" => app("feed.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  defp kind_attrs_of("polls") do
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
  defp kind_attrs_of("questionnaire") do
    %{
      "description" => app("forme.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  # The Map app shows the sub-groups that have a place (`Group.latitude`) as
  # pins, and opens each one's description over itself. It keeps its starting
  # view in its config; the places are the groups themselves.
  defp kind_attrs_of("map") do
    %{
      "description" => app("mapa.html"),
      "description_format" => :html,
      "uses_api" => true,
      "home_page" => :description
    }
  end

  # The Ordering app keeps its settings, rounds, orders and drivers in the
  # group's app data, under rules it saves on its editors' first visit.
  defp kind_attrs_of("orders") do
    %{
      "description" => app("narucivanje.html"),
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
