defmodule Mix.Tasks.Potok.SyncApps do
  @moduledoc """
  Copies the builds of the apps that presets come with into `priv/apps`: those
  of a Feed group, of a group for polls, of a form, of a map and of ordering.

  `PotokIde.Social.GroupPresets` reads them from there. The apps are projects
  of their own, next to this one, and the deploy does not reach them, so their
  builds are committed here. First run `npm run build` in each:

      mix potok.sync_apps

  A copy reaches the groups made after it. Each group keeps the app it was made
  with until an editor refreshes it (`Social.refresh_app/3`), which works for
  the builds `priv/apps/builds.json` knows: this task writes it anew
  (`mix potok.app_builds`), so commit it with the builds.
  """
  use Mix.Task

  @shortdoc "Copies the builds of the presets' apps into priv/apps"

  @apps [
    {"../potok-feed/dist/potok-build.html", "priv/apps/feed.html"},
    {"../potok-feed-creator/dist/potok-build.html", "priv/apps/feed_creator.html"},
    {"../potok-glasanje/dist/potok-build.html", "priv/apps/glasanje.html"},
    {"../potok-forme/dist/potok-build.html", "priv/apps/forme.html"},
    {"../potok-mapa/dist/potok-build.html", "priv/apps/mapa.html"},
    {"../potok-mleko/dist/potok-build.html", "priv/apps/narucivanje.html"}
  ]

  @impl Mix.Task
  def run(_args) do
    Enum.each(@apps, fn {source, target} ->
      if !File.exists?(source) do
        Mix.raise("#{source} does not exist. Run `npm run build` in that project first.")
      end

      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
      Mix.shell().info("#{target}: #{File.stat!(target).size} bytes")
    end)

    Mix.Task.run("potok.app_builds")
  end
end
