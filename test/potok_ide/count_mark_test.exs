defmodule PotokIde.CountMarkTest do
  use ExUnit.Case, async: true

  alias PotokIde.CountMark

  test "an empty table holds nothing, and no count stays no count" do
    assert CountMark.from_ids([]) == {0, []}
    assert CountMark.from_ids(nil) == nil
    refute CountMark.counted?({0, []}, 1)
  end

  test "an id the count did not see below the newest is new to it" do
    mark = CountMark.from_ids([1, 2, 4, 5])

    assert mark == {5, [3]}
    assert CountMark.counted?(mark, 4)
    refute CountMark.counted?(mark, 3)
    refute CountMark.counted?(mark, 6)
  end

  test "only the newest hundred ids are looked at" do
    mark = CountMark.from_ids([150, 200])

    assert {200, unseen} = mark
    assert length(unseen) == 98
    assert CountMark.counted?(mark, 100)
    assert CountMark.counted?(mark, 150)
    refute CountMark.counted?(mark, 101)
    refute CountMark.counted?(mark, 199)
  end
end
