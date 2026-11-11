defmodule Mix.Tasks.Potok.SyncReminder do
  @moduledoc """
  Reminds that the landing page, the domain map and the help page may have to
  follow a change.

  When the app's code changed, it names each page the change left untouched.
  The help page (`/pomoc`) is named only for a change to what users see, the
  LiveViews and components. Whether a page needs new text takes judgment, so
  this never fails. See "Landing page, domain map and help" in `AGENTS.md`.

  It reads the changed files from git, or takes them as arguments:

      mix potok.sync_reminder lib/potok_ide/social.ex
  """
  use Mix.Task

  @shortdoc "Reminds of the landing page, domain map and help after a change"

  @heading ~s(Did this change leave a page behind? See "Landing page, domain map and help" in AGENTS.md.)

  @app_code ~w(
    priv/repo/migrations/
    lib/potok_ide/
    lib/potok_ide_web/live/
    lib/potok_ide_web/components/
    lib/potok_ide_web/router.ex
    assets/js/potok_app_sdk.js
  )

  @screens ~w(
    lib/potok_ide_web/live/
    lib/potok_ide_web/components/
  )

  @pages [
    %{
      name: "Landing page (/)",
      where: "features/0 and perks/0 in page_html.ex, home.html.heex",
      files: ~w(
        lib/potok_ide_web/controllers/page_html.ex
        lib/potok_ide_web/controllers/page_html/home.html.heex
      ),
      after: @app_code
    },
    %{
      name: "Domain map (/domain)",
      where: "mechanisms/0 and apps/0 in domain_copy.ex, domain_map.ex",
      files: ~w(
        lib/potok_ide/domain_map.ex
        lib/potok_ide_web/domain_copy.ex
        lib/potok_ide_web/controllers/page_html/domain.html.heex
        assets/js/domain_map.js
      ),
      after: @app_code
    },
    %{
      name: "Help (/pomoc)",
      where:
        "priv/static/HELP.sr.md and HELP.en.md, then mix potok.sr_cyrl; " <>
          "pictures again with help_shots/make.exs --only <names>",
      files: ~w(
        priv/static/HELP.sr.md
        priv/static/HELP.en.md
        priv/static/images/help/
      ),
      after: @screens
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

  # A page is left behind when its kind of code changed and none of its files
  # did. A page's files never count as a change to the app (a folder among
  # them, as `priv/static/images/help/`, stands for all it holds).
  defp pages_left_behind(paths) do
    code = Enum.reject(paths, &String.starts_with?(&1, page_files()))

    Enum.filter(@pages, fn page ->
      Enum.any?(code, &String.starts_with?(&1, page.after)) and
        not Enum.any?(paths, &String.starts_with?(&1, page.files))
    end)
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
