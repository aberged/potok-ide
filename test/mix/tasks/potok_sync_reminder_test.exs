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
  end
end
