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
end
