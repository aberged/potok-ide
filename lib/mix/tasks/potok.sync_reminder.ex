defmodule Mix.Tasks.Potok.SyncReminder do
  @moduledoc """
  Reminds that the landing page and the domain map may have to follow a change.

  When the app's code changed, it names each page the change left untouched.
  Whether that page needs new text takes judgment, so this never fails. See
  "Landing page and domain map" in `AGENTS.md`.

  It reads the changed files from git, or takes them as arguments:

      mix potok.sync_reminder lib/potok_ide/social.ex
  """
  use Mix.Task

  @shortdoc "Reminds of the landing page and domain map after a change"

  @heading ~s(Did this change leave a page behind? See "Landing page and domain map" in AGENTS.md.)

  @app_code ~w(
    priv/repo/migrations/
    lib/potok_ide/
    lib/potok_ide_web/live/
    lib/potok_ide_web/components/
    lib/potok_ide_web/router.ex
    assets/js/potok_app_sdk.js
  )

  @pages [
    %{
      name: "Landing page (/)",
      where: "features/0 and perks/0 in page_html.ex, home.html.heex",
      files: ~w(
        lib/potok_ide_web/controllers/page_html.ex
        lib/potok_ide_web/controllers/page_html/home.html.heex
      )
    },
    %{
      name: "Domain map (/domain)",
      where: "mechanisms/0 and apps/0 in domain_copy.ex, domain_map.ex",
      files: ~w(
        lib/potok_ide/domain_map.ex
        lib/potok_ide_web/domain_copy.ex
        lib/potok_ide_web/controllers/page_html/domain.html.heex
        assets/js/domain_map.js
      )
    }
  ]

  @impl Mix.Task
  def run(args) do
    paths = if args == [], do: changed_files(), else: args

    paths |> reminders() |> Enum.each(&Mix.shell().info/1)
  end

  @doc "The lines to print for these changed files, none when nothing is left behind."
  def reminders(paths) do
    case pages_left_behind(paths) do
      [] -> []
      pages -> [@heading | Enum.map(pages, &"  #{&1.name}: #{&1.where}")]
    end
  end

  defp pages_left_behind(paths) do
    if Enum.any?(paths -- page_files(), &String.starts_with?(&1, @app_code)) do
      Enum.reject(@pages, fn page -> Enum.any?(page.files, &(&1 in paths)) end)
    else
      []
    end
  end

  defp page_files, do: Enum.flat_map(@pages, & &1.files)

  defp changed_files do
    args = ~w(status --porcelain -z --no-renames --untracked-files=all)

    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <- System.cmd(git, args) do
      for <<_status::binary-size(3), path::binary>> <- String.split(output, <<0>>, trim: true) do
        path
      end
    else
      _no_git -> []
    end
  end
end
