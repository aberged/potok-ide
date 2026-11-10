defmodule Mix.Tasks.Potok.ImportAreas do
  @moduledoc """
  Brings the areas of a GeoJSON file in as groups (`PotokIde.Social.AreaImport`):
  a group under the root for each parent, with the union of its areas, and
  under it a group for each area.

      mix potok.import_areas mesne_zajednice_web.geojson \\
        --account aber.ged@gmail.com --username mesne_zajednice \\
        --name-key mz_imel --parent-key opstina_imel

  `--remove` takes away what the profile `--username` of that account made
  in such an import, instead of importing.

  On a release, where Mix is not there, call `AreaImport.start/4` over
  `bin/potok_ide rpc`.
  """
  use Mix.Task

  alias PotokIde.Social.AreaImport

  @shortdoc "Imports the areas of a GeoJSON file as groups"

  @switches [
    account: :string,
    username: :string,
    name_key: :string,
    parent_key: :string,
    remove: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: @switches)
    account = opts[:account] || Mix.raise("--account is required")
    username = opts[:username] || Mix.raise("--username is required")

    Mix.Task.run("app.start")

    if opts[:remove] do
      remove(account, username)
    else
      path =
        case paths do
          [path] -> path
          _other -> Mix.raise("Give the path of one GeoJSON file")
        end

      keys = [
        name: opts[:name_key] || Mix.raise("--name-key is required"),
        parent: opts[:parent_key] || Mix.raise("--parent-key is required")
      ]

      case AreaImport.import_file(path, account, username, keys) do
        {:ok, report} -> print(report)
        {:error, reason} -> Mix.raise("Import failed: #{inspect(reason)}")
      end
    end
  end

  defp remove(account, username) do
    case AreaImport.profile(account, username, false) do
      {:ok, profile} ->
        {:ok, deleted, kept} = AreaImport.remove(profile)
        Mix.shell().info("Deleted #{deleted} groups, kept #{kept}.")

      {:error, reason} ->
        Mix.raise("No such profile: #{inspect(reason)}")
    end
  end

  defp print(report) do
    Mix.shell().info("""
    Parents: #{report.parents}
    Areas below them: #{report.children}
    Groups made: #{report.created}, taken again: #{report.reused}
    Borders written: #{report.areas}, of which mended: #{report.repaired}
    Failed: #{length(report.failed)}
    """)

    Enum.each(report.failed, fn {parent, name, reason} ->
      Mix.shell().error("  #{parent} / #{name || "-"}: #{inspect(reason)}")
    end)
  end
end
