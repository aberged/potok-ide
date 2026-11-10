defmodule PotokIde.Social.AreaShapesTest do
  @moduledoc """
  Simplified borders kept once made (`AreaShapes`): asked again, they come
  from the table; a new version, size or level makes them again; the table
  stays under its size.
  """
  use ExUnit.Case, async: true

  alias PotokIde.Social.AreaShapes

  defp area(id, updated_at \\ ~U[2026-11-10 10:00:00Z], size \\ 1.0),
    do: %{id: id, updated_at: updated_at, size: size}

  # Makes "<id>@<level>" for each id and tells the test which ids it made.
  defp maker(level) do
    test = self()

    fn ids ->
      send(test, {:made, ids})
      Map.new(ids, &{&1, "#{&1}@#{level}"})
    end
  end

  # Ids far from any other test's, as the table is the app's own.
  setup do
    %{base: System.unique_integer([:positive]) * 1_000}
  end

  test "a border is made once, then kept", %{base: base} do
    areas = [area(base + 1), area(base + 2)]

    assert areas |> AreaShapes.fetch(12, maker(12)) |> Enum.map(&elem(&1, 1)) ==
             ["#{base + 1}@12", "#{base + 2}@12"]

    assert_received {:made, made}
    assert Enum.sort(made) == [base + 1, base + 2]

    assert [{_, _}, {_, _}] = AreaShapes.fetch(areas, 12, maker(12))
    refute_received {:made, _}
  end

  test "a new version, size or level makes it again", %{base: base} do
    AreaShapes.fetch([area(base)], 10, maker(10))
    assert_received {:made, [_]}

    AreaShapes.fetch([area(base, ~U[2026-11-10 10:00:01Z])], 10, maker(10))
    assert_received {:made, [_]}

    AreaShapes.fetch([area(base, ~U[2026-11-10 10:00:00Z], 2.0)], 10, maker(10))
    assert_received {:made, [_]}

    AreaShapes.fetch([area(base)], 14, maker(14))
    assert_received {:made, [_]}
  end

  test "an area the maker gives nothing for is left out", %{base: base} do
    assert AreaShapes.fetch([area(base)], 12, fn _ids -> %{} end) == []
  end

  test "a table over its size drops what was used longest ago" do
    entries = [{:new, 40, 3}, {:old, 40, 1}, {:middle, 40, 2}]

    assert AreaShapes.to_drop(entries, 80) == {[:old], 80}
    assert AreaShapes.to_drop(entries, 50) == {[:old, :middle], 40}
    assert AreaShapes.to_drop(entries, 200) == {[], 120}
  end
end
