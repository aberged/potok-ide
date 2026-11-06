defmodule Mix.Tasks.Potok.SyncApps do
  @moduledoc """
  Copies the builds of the apps a Feed group comes with into `priv/apps`.

  `PotokIde.Social.GroupPresets` reads them from there. The apps are projects
  of their own, next to this one, and the deploy does not reach them, so their
  builds are committed here. First run `npm run build` in both:

      mix potok.sync_apps

  A copy changes only the feeds made after it: each feed keeps the apps it
  was made with.
  """
  use Mix.Task

  @shortdoc "Copies the builds of Feed and FeedCreator into priv/apps"

  @apps [
    {"../potok-feed/dist/potok-build.html", "priv/apps/feed.html"},
    {"../potok-feed-creator/dist/potok-build.html", "priv/apps/feed_creator.html"}
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
  end
end
