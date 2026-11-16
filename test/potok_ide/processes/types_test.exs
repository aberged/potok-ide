defmodule PotokIde.Processes.TypesTest do
  use ExUnit.Case, async: true

  alias PotokIde.Processes.Types

  describe "name?/1" do
    test "takes letters of any script, digits and _" do
      assert Types.name?("sprat")
      assert Types.name?("broj_stana")
      assert Types.name?("_x1")
      assert Types.name?("спрат")
      assert Types.name?("šifra")
    end

    test "refuses what a text or a condition could not name" do
      refute Types.name?("")
      refute Types.name?("1sprat")
      refute Types.name?("broj-stana")
      refute Types.name?("broj stana")
      refute Types.name?("a.b")
      refute Types.name?(String.duplicate("a", 41))
      refute Types.name?(nil)
    end

    test "refuses the words a process keeps for itself" do
      for word <- Types.reserved(), do: refute(Types.name?(word))
    end
  end

  describe "nesting/1" do
    test "is fine for entities that hold nothing, or each other in a row" do
      assert Types.nesting(%{}) == :ok
      assert Types.nesting(%{1 => [], 2 => []}) == :ok
      assert Types.nesting(%{1 => [2], 2 => [3], 3 => [4], 4 => []}) == :ok
    end

    test "counts an entity nobody defined as holding nothing" do
      assert Types.nesting(%{1 => [99]}) == :ok
    end

    test "finds an entity that comes back to itself" do
      assert Types.nesting(%{1 => [1]}) == {:error, :cycle}
      assert Types.nesting(%{1 => [2], 2 => [1]}) == {:error, :cycle}
      assert Types.nesting(%{1 => [2], 2 => [3], 3 => [1], 4 => []}) == {:error, :cycle}
    end

    test "is fine with two ways to the same entity" do
      assert Types.nesting(%{1 => [2, 3], 2 => [4], 3 => [4], 4 => []}) == :ok
    end

    test "stops past four levels" do
      assert Types.nesting(%{1 => [2], 2 => [3], 3 => [4], 4 => [5], 5 => []}) ==
               {:error, :too_deep}

      # A new entity, with no id yet, counts as well.
      assert Types.nesting(%{:new => [1], 1 => [2], 2 => [3], 3 => [4], 4 => []}) ==
               {:error, :too_deep}
    end
  end

  @entities %{
    "7" => %{
      "name" => "Prijava",
      "attributes" => [
        %{"name" => "naslov", "type" => "text", "required" => true},
        %{"name" => "sprat", "type" => "number"},
        %{"name" => "stan", "type" => "entity", "entity" => 8},
        %{"name" => "slike", "type" => "text", "list" => true}
      ]
    },
    "8" => %{"name" => "Stan", "attributes" => [%{"name" => "broj", "type" => "number"}]}
  }

  describe "of/1 and json/1" do
    test "read a stored type as a term, and back" do
      for {stored, term} <- [
            {%{"type" => "text"}, :text},
            {%{"type" => "number", "list" => true}, {:list, :number}},
            {%{"type" => "choice", "options" => ["a", "b"]}, {:choice, ["a", "b"]}},
            {%{"type" => "entity", "entity" => 8}, {:entity, 8}},
            {%{"type" => "entity", "entity" => 8, "list" => true}, {:list, {:entity, 8}}},
            {%{
               "type" => "record",
               "fields" => %{"outcome" => %{"type" => "text"}},
               "open" => true
             }, {:record, %{"outcome" => :text}, true}},
            {%{"type" => "any"}, :any}
          ] do
        assert Types.of(stored) == term
        assert Types.of(Types.json(term)) == term
      end
    end

    test "an attribute reads as its type, whatever else it keeps" do
      assert Types.of(%{"name" => "sprat", "type" => "number", "required" => true}) == :number
      assert Types.of(%{"type" => "nepoznat"}) == :any
    end
  end

  describe "fits?/2" do
    test "like goes where like is asked for" do
      assert Types.fits?(:number, :number)
      assert Types.fits?({:list, :text}, {:list, :text})
      assert Types.fits?({:entity, 7}, {:entity, 7})
      refute Types.fits?(:number, :text)
      refute Types.fits?({:entity, 7}, {:entity, 8})
      refute Types.fits?({:list, :number}, {:list, :text})
      refute Types.fits?(:date, :datetime)
    end

    test "what is unknown or empty goes anywhere, and a choice is a text" do
      assert Types.fits?(:any, :number)
      assert Types.fits?(:number, :any)
      assert Types.fits?(:empty, {:entity, 7})
      assert Types.fits?({:choice, ["a"]}, :text)
      assert Types.fits?(:text, {:choice, ["a"]})
    end
  end

  describe "cast/4" do
    test "reads a number from a text with a dot or a comma" do
      assert Types.cast("12,5", :number) == {:ok, Decimal.new("12.5")}
      assert Types.cast(" -3 ", :number) == {:ok, Decimal.new("-3")}
      assert Types.cast(7, :number) == {:ok, Decimal.new(7)}
      assert Types.cast("1e9", :number) == {:error, {:not_a_number, ""}}
      assert Types.cast("pet", :number) == {:error, {:not_a_number, ""}}
      assert Types.cast(String.duplicate("9", 41), :number) == {:error, {:not_a_number, ""}}
    end

    test "nothing, and a blank where no text is asked for, is no value" do
      assert Types.cast(nil, :number) == {:ok, nil}
      assert Types.cast("", :number) == {:ok, nil}
      assert Types.cast("", :date) == {:ok, nil}
      assert Types.cast("", :text) == {:ok, ""}
    end

    test "reads what is true or false" do
      assert Types.cast("true", :boolean) == {:ok, true}
      assert Types.cast(false, :boolean) == {:ok, false}
      assert Types.cast("da", :boolean) == {:error, {:not_a_boolean, ""}}
    end

    test "reads a day as a form or a person writes it" do
      assert Types.cast("2026-11-16", :date) == {:ok, ~D[2026-11-16]}
      assert Types.cast("16. 11. 2026.", :date) == {:ok, ~D[2026-11-16]}
      assert Types.cast("16.11.2026", :date) == {:ok, ~D[2026-11-16]}
      assert Types.cast("2026-11-16T10:00:00Z", :date) == {:ok, ~D[2026-11-16]}
      assert Types.cast("31. 2. 2026.", :date) == {:error, {:not_a_date, ""}}
      assert Types.cast("sutra", :date) == {:error, {:not_a_date, ""}}
    end

    test "reads a time with its offset, or as local to the zone" do
      assert Types.cast("2026-11-16T14:30:00+01:00", :datetime) ==
               {:ok, ~U[2026-11-16 13:30:00Z]}

      assert Types.cast("2026-11-16T14:30", :datetime, %{}, zone: "Europe/Belgrade") ==
               {:ok, ~U[2026-11-16 13:30:00Z]}

      assert Types.cast("2026-11-16T14:30", :datetime) == {:ok, ~U[2026-11-16 14:30:00Z]}
      assert Types.cast("podne", :datetime) == {:error, {:not_a_datetime, ""}}
    end

    test "takes only the options of a choice" do
      assert Types.cast("voda", {:choice, ["voda", "struja"]}) == {:ok, "voda"}
      assert Types.cast("gas", {:choice, ["voda", "struja"]}) == {:error, {:not_an_option, ""}}
    end

    test "turns a number or a day into a text" do
      assert Types.cast(Decimal.new("3.50"), :text) == {:ok, "3.5"}
      assert Types.cast(~D[2026-11-16], :text) == {:ok, "16. 11. 2026."}
      assert Types.cast(%{"a" => 1}, :text) == {:error, {:not_a_text, ""}}
    end

    test "reads an entity attribute by attribute, and drops what it does not define" do
      assert Types.cast(
               %{
                 "naslov" => "Lift",
                 "sprat" => "3",
                 "stan" => %{"broj" => 12, "visak" => "x"},
                 "slike" => ["a.png"],
                 "visak" => true
               },
               {:entity, 7},
               @entities
             ) ==
               {:ok,
                %{
                  "naslov" => "Lift",
                  "sprat" => Decimal.new("3"),
                  "stan" => %{"broj" => Decimal.new(12)},
                  "slike" => ["a.png"]
                }}
    end

    test "says where in an entity or a list it went wrong" do
      assert Types.cast(%{"sprat" => "treći"}, {:entity, 7}, @entities) ==
               {:error, {:not_a_number, "sprat"}}

      assert Types.cast(%{"stan" => %{"broj" => "x"}}, {:entity, 7}, @entities) ==
               {:error, {:not_a_number, "stan.broj"}}

      assert Types.cast([%{"broj" => 1}, %{"broj" => "x"}], {:list, {:entity, 8}}, @entities) ==
               {:error, {:not_a_number, "1.broj"}}

      assert Types.cast("Lift", {:entity, 7}, @entities) == {:error, {:not_an_entity, ""}}
      assert Types.cast(%{}, {:entity, 99}, @entities) == {:error, {:unknown_entity, ""}}
      assert Types.cast("a", {:list, :text}) == {:error, {:not_a_list, ""}}
    end

    test "asks for what is required only when told to" do
      assert {:ok, %{"naslov" => nil}} = Types.cast(%{"sprat" => 1}, {:entity, 7}, @entities)

      assert Types.cast(%{"sprat" => 1}, {:entity, 7}, @entities, required: true) ==
               {:error, {:required, "naslov"}}

      assert Types.cast(%{"naslov" => " "}, {:entity, 7}, @entities, required: true) ==
               {:ok, %{"naslov" => " ", "sprat" => nil, "stan" => nil, "slike" => nil}}
    end

    test "keeps what an open record holds beside its fields" do
      type = {:record, %{"outcome" => :text}, true}

      assert Types.cast(%{"outcome" => "Da", "kvar" => "Lift"}, type) ==
               {:ok, %{"outcome" => "Da", "kvar" => "Lift"}}

      closed = {:record, %{"outcome" => :text}, false}

      assert Types.cast(%{"outcome" => "Da", "kvar" => "Lift"}, closed) ==
               {:ok, %{"outcome" => "Da"}}
    end

    test "a list holds 200 items at most" do
      assert {:ok, _items} = Types.cast(List.duplicate("a", 200), {:list, :text})

      assert Types.cast(List.duplicate("a", 201), {:list, :text}) ==
               {:error, {:too_many_items, ""}}
    end
  end

  describe "load/3 and dump/1" do
    test "what is kept at rest comes back as a step works on it" do
      value = %{
        "naslov" => "Lift",
        "sprat" => Decimal.new("3.50"),
        "stan" => %{"broj" => Decimal.new(12)},
        "slike" => ["a.png"]
      }

      kept = Types.dump(value)

      assert kept == %{
               "naslov" => "Lift",
               "sprat" => "3.5",
               "stan" => %{"broj" => "12"},
               "slike" => ["a.png"]
             }

      loaded = Types.load(kept, {:entity, 7}, @entities)
      assert Decimal.equal?(loaded["sprat"], value["sprat"])
      assert loaded["stan"] == value["stan"]
    end

    test "days and times are kept as ISO texts" do
      assert Types.dump(~D[2026-11-16]) == "2026-11-16"
      assert Types.dump(~U[2026-11-16 13:30:00Z]) == "2026-11-16T13:30:00Z"
      assert Types.load("2026-11-16", :date) == ~D[2026-11-16]
      assert Types.load("2026-11-16T13:30:00Z", :datetime) == ~U[2026-11-16 13:30:00Z]
    end

    test "what no longer fits its type stays as it was kept" do
      assert Types.load("treći", :number) == "treći"
      assert Types.load("Lift", {:entity, 7}, @entities) == "Lift"
    end

    test "a number is kept without the zeros that say nothing" do
      assert Types.dump(Decimal.new("10.00")) == "10"
      assert Types.dump(Decimal.new("1E+2")) == "100"
      assert Types.dump(Decimal.new("0.0")) == "0"
    end
  end

  describe "text/2" do
    test "reads each value as a text shows it" do
      assert Types.text(nil) == ""
      assert Types.text("Lift") == "Lift"
      assert Types.text(Decimal.new("3.50")) == "3.5"
      assert Types.text(true) == "true"
      assert Types.text(~D[2026-11-06]) == "06. 11. 2026."
      assert Types.text(~U[2026-11-16 13:05:00Z], "Europe/Belgrade") == "16. 11. 2026. 14:05"
      assert Types.text(~U[2026-11-16 13:05:00Z], "Nigde/Nista") == "16. 11. 2026. 13:05"
      assert Types.text(["a", Decimal.new(2)]) == "a, 2"
      assert Types.text(%{"naslov" => "Lift"}) == ""
    end
  end
end
