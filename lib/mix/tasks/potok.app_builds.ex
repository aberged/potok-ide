defmodule Mix.Tasks.Potok.AppBuilds do
  @moduledoc """
  Writes `priv/apps/builds.json`: the fingerprint of every build of the
  presets' apps ever committed in `priv/apps`, and of the files there now,
  so that `PotokIde.Social.AppBuilds` knows a group's copy for one of them
  even when it carries no `potok-app` tag.

      mix potok.app_builds

  `mix potok.sync_apps` runs it after a copy. Commit the file with the builds.
  """
  use Mix.Task

  alias PotokIde.Social.AppBuilds

  @shortdoc "Writes the fingerprints of the presets' app builds into priv/apps/builds.json"
  @target "priv/apps/builds.json"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    builds =
      Map.new(AppBuilds.apps(), fn app ->
        path = Path.join("priv/apps", AppBuilds.file(app))

        fingerprints =
          (history(path) ++ [File.read!(path)])
          |> Enum.map(&AppBuilds.fingerprint/1)
          |> Enum.uniq()
          |> Enum.sort()

        {app, fingerprints}
      end)

    File.write!(@target, Jason.encode_to_iodata!(sorted(builds), pretty: true) ++ ["\n"])

    for {app, fingerprints} <- Enum.sort(builds),
        do: Mix.shell().info("#{app}: #{length(fingerprints)} builds")
  end

  # Every version of the file git has, oldest first.
  defp history(path) do
    {log, 0} = System.cmd("git", ["log", "--format=%H", "--", path])

    log
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.flat_map(fn sha ->
      case System.cmd("git", ["show", "#{sha}:#{path}"], stderr_to_stdout: true) do
        {html, 0} -> [html]
        _gone -> []
      end
    end)
  end

  defp sorted(builds) do
    builds |> Enum.sort() |> Jason.OrderedObject.new()
  end
end
