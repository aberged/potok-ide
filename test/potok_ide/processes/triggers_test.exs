defmodule PotokIde.Processes.TriggersTest do
  @moduledoc """
  What sets a drawn process going: settings kept as Potok keeps them, a
  schedule's next start in its own time zone, and the messages that count.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Processes.Triggers
  alias PotokIde.Social.Value

  describe "normalize/2" do
    test "a message needs a word or a role, words one by one" do
      assert {:ok, %{"words" => ["kvar", "curi"], "role" => nil}} =
               Triggers.normalize("message", %{"words" => " Kvar, #curi,, kvar "})

      assert {:ok, %{"words" => [], "role" => "savet"}} =
               Triggers.normalize("message", %{"words" => "", "role" => "savet"})

      assert {:error, {"words", :empty}} = Triggers.normalize("message", %{"words" => " "})
      assert {:error, {"words", :invalid}} = Triggers.normalize("message", %{"words" => "a"})

      assert {:error, {"words", :invalid}} =
               Triggers.normalize("message", %{"words" => "dve reči"})

      too_many = Enum.map_join(1..11, ",", &"rec#{&1}")

      assert {:error, {"words", :too_many}} =
               Triggers.normalize("message", %{"words" => too_many})
    end

    test "a schedule needs its days, a time and a zone" do
      assert {:ok, %{"every" => "week", "weekdays" => [1, 4], "time" => "20:00", "day" => nil}} =
               Triggers.normalize("schedule", %{
                 "every" => "week",
                 "weekdays" => ["4", "1", "", "4"],
                 "time" => "20:00",
                 "time_zone" => "Europe/Belgrade"
               })

      assert {:ok, %{"day" => "last", "weekdays" => []}} =
               Triggers.normalize("schedule", %{
                 "every" => "month",
                 "day" => "last",
                 "time" => "09:30",
                 "time_zone" => "Europe/Belgrade"
               })

      base = %{
        "every" => "week",
        "weekdays" => [1],
        "time" => "09:00",
        "time_zone" => "Europe/Belgrade"
      }

      assert {:error, {"weekdays", :empty}} =
               Triggers.normalize("schedule", %{base | "weekdays" => []})

      assert {:error, {"time", :invalid}} =
               Triggers.normalize("schedule", %{base | "time" => "25:00"})

      assert {:error, {"time_zone", :invalid}} =
               Triggers.normalize("schedule", %{base | "time_zone" => "Mars/Olympus"})

      assert {:error, {"day", :invalid}} =
               Triggers.normalize(
                 "schedule",
                 %{base | "every" => "month"} |> Map.put("day", "31")
               )
    end

    test "by hand, everyone starts it unless roles are picked" do
      assert {:ok, %{"roles" => ["everyone"]}} = Triggers.normalize("manual", %{"roles" => []})

      assert {:ok, %{"roles" => ["savet"]}} =
               Triggers.normalize("manual", %{"roles" => ["savet", ""]})

      assert {:ok, %{"placed" => true}} = Triggers.normalize("subgroup", %{"placed" => "true"})
      assert {:ok, %{}} = Triggers.normalize("value", %{"anything" => 1})
      assert {:error, {"", :invalid}} = Triggers.normalize("comet", %{})
    end

    test "a process another calls names the fields it takes" do
      assert {:ok, %{"fields" => ["kvar", "sprat"]}} =
               Triggers.normalize("process", %{"fields" => " kvar, sprat,,kvar "})

      assert {:ok, %{"fields" => []}} = Triggers.normalize("process", %{})

      assert {:error, {"fields", :reserved}} =
               Triggers.normalize("process", %{"fields" => "from"})

      assert {:error, {"fields", :invalid}} =
               Triggers.normalize("process", %{"fields" => "dve reči"})

      assert {:error, {"fields", :too_many}} =
               Triggers.normalize("process", %{"fields" => Enum.map(1..11, &"f#{&1}")})

      assert Triggers.fields("process", %{"fields" => ["kvar"]}) == ["kvar", "from"]
      assert Triggers.fields("manual") == ~w(title text author)
    end

    test "names the roles its settings hold" do
      assert Triggers.role_refs("message", %{"words" => [], "role" => "savet"}) == [
               {"role", "savet"}
             ]

      assert Triggers.role_refs("manual", %{"roles" => ["a", "b"]}) == [
               {"roles.0", "a"},
               {"roles.1", "b"}
             ]

      assert Triggers.role_refs("subgroup", %{"placed" => true}) == []
    end
  end

  describe "next_run/2" do
    defp schedule(attrs),
      do:
        Map.merge(
          %{"time" => "20:00", "time_zone" => "Europe/Belgrade", "weekdays" => [], "day" => nil},
          attrs
        )

    test "finds the next weekday at the local time" do
      # Monday 16 November 2026, 10:00 UTC; Thursday 20:00 in Belgrade is 19:00 UTC.
      now = ~U[2026-11-16 10:00:00Z]

      assert Triggers.next_run(schedule(%{"every" => "week", "weekdays" => [4]}), now) ==
               ~U[2026-11-19 19:00:00Z]

      assert Triggers.next_run(schedule(%{"every" => "day"}), now) == ~U[2026-11-16 19:00:00Z]

      # Past today's time it is tomorrow.
      assert Triggers.next_run(schedule(%{"every" => "day"}), ~U[2026-11-16 19:30:00Z]) ==
               ~U[2026-11-17 19:00:00Z]
    end

    test "takes the last day of each month, and a fixed day" do
      assert Triggers.next_run(
               schedule(%{"every" => "month", "day" => "last"}),
               ~U[2027-02-10 10:00:00Z]
             ) ==
               ~U[2027-02-28 19:00:00Z]

      assert Triggers.next_run(
               schedule(%{"every" => "month", "day" => 1}),
               ~U[2026-11-16 10:00:00Z]
             ) ==
               ~U[2026-12-01 19:00:00Z]
    end

    test "keeps the local time across the change to summer time" do
      # 29 March 2027 is after the change: 20:00 in Belgrade is then 18:00 UTC.
      assert Triggers.next_run(schedule(%{"every" => "day"}), ~U[2027-03-28 20:00:00Z]) ==
               ~U[2027-03-29 18:00:00Z]
    end

    test "gives its date and time as fields" do
      assert Triggers.schedule_data(%{"time_zone" => "Europe/Belgrade"}, ~U[2026-11-19 19:00:00Z]) ==
               %{"date" => "19. 11. 2026.", "time" => "20:00"}
    end
  end

  describe "matches_message?/3" do
    defp message(content, roles \\ []),
      do: %Value{content: content, mentions: %{"roles" => roles}}

    test "takes a whole word in any case, or the role mentioned" do
      config = %{"words" => ["kvar"], "role" => "key-savet"}
      keys = %{"savet" => "key-savet"}

      assert Triggers.matches_message?(
               config,
               message("Lift je u KVARU? Ne, KVAR je na 3."),
               keys
             )

      refute Triggers.matches_message?(config, message("Kvarno nešto"), keys)

      assert Triggers.matches_message?(
               config,
               message("Molim @savet da pogleda", ["savet"]),
               keys
             )

      refute Triggers.matches_message?(config, message("Molim @drugi", ["drugi"]), keys)
    end
  end
end
