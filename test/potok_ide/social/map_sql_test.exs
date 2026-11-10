defmodule PotokIde.Social.MapSqlTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.MapSql

  doctest MapSql

  test "numbers names in order of first use and sends only the ones used" do
    assert MapSql.bind("x = $b AND y = $a AND z = $b::float8", %{a: 1, b: 2, c: 3}) ==
             {"x = $1 AND y = $2 AND z = $1::float8", [2, 1]}
  end

  test "a name without a value is a mistake" do
    assert_raise ArgumentError, ~r/\$missing/, fn -> MapSql.bind("x = $missing", %{}) end
  end
end
