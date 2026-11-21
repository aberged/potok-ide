defmodule PotokIde.Social.AppBuilds do
  @moduledoc """
  The builds of the apps presets come with (`priv/apps`, `GroupPresets`), and
  what a group's copy of one is. Every group keeps the copy it was made with,
  so a newer build reaches it only when an editor refreshes it
  (`Social.refresh_app/3`), and only once Potok knows the copy for one of its
  own: a pasted app of someone's own is never replaced.

  A build names itself with `<meta name="potok-app" content="potok-feed">` in
  its body (since 2026-11-21). The builds shipped before carry no such tag,
  so `priv/apps/builds.json` holds the fingerprint of every build ever
  committed here, written by `mix potok.app_builds` from git history (and by
  `mix potok.sync_apps` after a copy). A fingerprint leaves out the tag, line
  endings and the white space around (`Fingerprint`), so a copy that went
  through a form, or one that differs from the newest build by the tag alone,
  is that build.
  """

  alias PotokIde.Social.AppBuilds.Fingerprint

  @files %{
    "potok-feed" => "feed.html",
    "potok-feed-creator" => "feed_creator.html",
    "potok-glasanje" => "glasanje.html",
    "potok-forme" => "forme.html",
    "potok-mapa" => "mapa.html",
    "potok-mleko" => "narucivanje.html"
  }

  # The preset each app comes with; FeedCreator comes with a feed's `.feed`.
  @presets %{
    "potok-feed" => "feed",
    "potok-glasanje" => "polls",
    "potok-forme" => "questionnaire",
    "potok-mapa" => "map",
    "potok-mleko" => "orders"
  }

  @apps Map.keys(@files)

  @named ~r/<meta\s+name="potok-app"\s+content="([a-z0-9-]+)"/i

  @apps_dir Path.expand("../../../priv/apps", __DIR__)
  @builds_file Path.join(@apps_dir, "builds.json")

  @external_resource @builds_file
  for file <- Map.values(@files), do: @external_resource(Path.join(@apps_dir, file))

  @known (if File.exists?(@builds_file) do
            @builds_file |> File.read!() |> Jason.decode!()
          else
            %{}
          end)

  @by_fingerprint for {app, fingerprints} <- @known,
                      fingerprint <- fingerprints,
                      into: %{},
                      do: {fingerprint, app}

  @current for {app, file} <- @files,
               path = Path.join(@apps_dir, file),
               File.exists?(path),
               into: %{},
               do: {app, path |> File.read!() |> Fingerprint.of()}

  @doc "What an app's HTML is, whatever form it came through (`Fingerprint`)."
  def fingerprint(html), do: Fingerprint.of(html)

  @doc "The apps Potok ships, by their ids (the names of their repositories)."
  def apps, do: @apps

  @doc "The file in `priv/apps` of `app`."
  def file(app) when app in @apps, do: Map.fetch!(@files, app)

  @doc "The preset `app` comes with, nil for FeedCreator."
  def preset(app) when app in @apps, do: Map.get(@presets, app)

  @doc "The fingerprints `builds.json` holds for `app`."
  def known(app) when app in @apps, do: Map.get(@known, app, [])

  @doc "The fingerprint of the build of `app` in `priv/apps` now."
  def current(app) when app in @apps, do: Map.fetch!(@current, app)

  @doc "The HTML of the newest build of `app`."
  def current_html(app) when app in @apps do
    :potok_ide
    |> Application.app_dir(Path.join("priv/apps", file(app)))
    |> File.read!()
  end

  @doc """
  Which of Potok's apps `html` is: by its tag, else by a fingerprint of a
  build shipped before. Nil for anything else.
  """
  def identify(html) when is_binary(html) do
    case Regex.run(@named, html) do
      [_tag, app] when app in @apps -> app
      _untagged -> Map.get(@by_fingerprint, Fingerprint.of(html))
    end
  end

  def identify(_html), do: nil

  @doc """
  `{:current, app}` for the newest build, `{:outdated, app}` for another build
  of one of Potok's apps, nil for an app of someone's own.
  """
  def status(html) do
    case identify(html) do
      nil -> nil
      app -> if Fingerprint.of(html) == current(app), do: {:current, app}, else: {:outdated, app}
    end
  end
end
