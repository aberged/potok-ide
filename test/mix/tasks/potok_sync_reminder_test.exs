defmodule Mix.Tasks.Potok.SyncReminderTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Potok.SyncReminder

  @migration "priv/repo/migrations/20261105000000_add_something.exs"

  describe "reminders/1" do
    test "names both pages when the app changed and they did not" do
      assert [_heading, landing, domain] = SyncReminder.reminders([@migration])

      assert landing =~ "Landing page"
      assert domain =~ "Domain map"
    end

    test "leaves out a page the change touched" do
      assert [_heading, landing] =
               SyncReminder.reminders([@migration, "lib/potok_ide_web/domain_copy.ex"])

      assert landing =~ "Landing page"
    end

    test "says nothing when the change touched both pages" do
      assert SyncReminder.reminders([
               @migration,
               "lib/potok_ide_web/domain_copy.ex",
               "lib/potok_ide_web/controllers/page_html.ex"
             ]) == []
    end

    test "says nothing when only tests or styles changed" do
      assert SyncReminder.reminders(["test/potok_ide/social_test.exs", "assets/css/app.css"]) ==
               []
    end

    test "a change to a page alone is no change to the app" do
      assert SyncReminder.reminders(["lib/potok_ide/domain_map.ex"]) == []
    end

    test "names the help page too when a screen changed" do
      screen = "lib/potok_ide_web/live/group_live/show.ex"

      assert [_heading, landing, domain, help] = SyncReminder.reminders([screen])

      assert landing =~ "Landing page"
      assert domain =~ "Domain map"
      assert help =~ "Help (/pomoc)"
    end

    test "leaves the help page out when its text or pictures changed" do
      screen = "lib/potok_ide_web/components/layouts.ex"

      for touched <- [
            "priv/static/HELP.sr.md",
            "priv/static/help/zgrada.sr.md",
            "priv/static/images/help/poruke.webp"
          ] do
        reminders = SyncReminder.reminders([screen, touched])

        assert length(reminders) == 3
        refute Enum.any?(reminders, &(&1 =~ "Help"))
      end
    end

    test "a change to the help page alone is no change to the app" do
      assert SyncReminder.reminders(["priv/static/HELP.en.md", "priv/static/images/help/a.webp"]) ==
               []
    end

    test "names a page on how Potok works inside when the code it was drawn from changed" do
      for guide <- PotokIdeWeb.HelpGuides.guides(), path <- guide.watch do
        # A folder stands for a file in it.
        changed = if String.ends_with?(path, "/"), do: path <> "engine.ex", else: path

        assert Enum.any?(SyncReminder.reminders([changed]), &(&1 =~ "(/pomoc/#{guide.slug})")),
               "#{changed} does not name #{guide.slug}"
      end
    end

    test "names only the pages drawn from that code" do
      reminders = SyncReminder.reminders(["lib/potok_ide/social/access.ex"])

      assert Enum.any?(reminders, &(&1 =~ "(/pomoc/prava-pristupa)"))
      refute Enum.any?(reminders, &(&1 =~ "(/pomoc/arhitektura-aplikacije)"))
      refute Enum.any?(reminders, &(&1 =~ "(/pomoc/procesi-i-aplikacije)"))
    end

    test "leaves such a page out when its template changed, but not for the shared module" do
      sdk = "assets/js/potok_app_sdk.js"
      template = "lib/potok_ide_web/controllers/page_html/help_app_architecture.html.heex"

      touched = SyncReminder.reminders([sdk, template])
      refute Enum.any?(touched, &(&1 =~ "(/pomoc/arhitektura-aplikacije)"))
      assert Enum.any?(touched, &(&1 =~ "(/pomoc/procesi-i-aplikacije)"))

      shared = SyncReminder.reminders([sdk, "lib/potok_ide_web/help_guides.ex"])
      assert Enum.any?(shared, &(&1 =~ "(/pomoc/arhitektura-aplikacije)"))
    end

    test "a change to such a page alone is no change to the app" do
      assert SyncReminder.reminders([
               "lib/potok_ide_web/controllers/page_html/help_access.html.heex",
               "priv/gettext/sr/LC_MESSAGES/help_guides.po"
             ]) == []
    end
  end
end
