defmodule PotokIde.Events.FormatTest do
  use ExUnit.Case, async: true

  alias PotokIde.Events.Format

  @zone "Europe/Belgrade"
  # A Tuesday, 13:00 in Belgrade.
  @now ~U[2026-11-03 12:00:00Z]

  defp recent(at, locale \\ "en") do
    Gettext.with_locale(PotokIdeWeb.Gettext, locale, fn -> Format.recent(at, @zone, @now) end)
  end

  describe "recent/3" do
    test "shows the time on the same local day, after local midnight too" do
      assert recent(~U[2026-11-03 07:05:00Z]) == "08:05"
      assert recent(~U[2026-11-02 23:30:00Z]) == "00:30"
    end

    test "counts a moment after now as the same day" do
      assert recent(~U[2026-11-03 12:05:00Z]) == "13:05"
    end

    test "says yesterday for the local day before" do
      assert recent(~U[2026-11-02 22:30:00Z]) == "Yesterday"
      assert recent(~U[2026-11-02 22:30:00Z], "sr") == "Juče"
    end

    test "shows the weekday within the week, then the date" do
      assert recent(~U[2026-11-01 10:00:00Z]) == "Sun"
      assert recent(~U[2026-10-28 10:00:00Z]) == "Wed"
      assert recent(~U[2026-10-27 10:00:00Z]) == "Oct 27"
      assert recent(~U[2026-02-14 10:00:00Z]) == "Feb 14"
    end

    test "adds the year before this one" do
      assert recent(~U[2025-11-07 10:00:00Z]) == "Nov 7, 2025"
    end
  end
end
