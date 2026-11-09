defmodule PotokIde.Social.ValueAggregateTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.Repo
  alias PotokIde.Social.ValueAggregate

  describe "spec/4" do
    test "takes keys as sent and the default path when none is given" do
      assert {:ok, %{group_by: nil, fields: [], under: ["a"]}} =
               ValueAggregate.spec(nil, nil, nil, ["a"])

      assert {:ok, %{group_by: "status", fields: ["amount", "n"], under: []}} =
               ValueAggregate.spec("status", ["amount", "n", "amount"], [], ["a"])
    end

    test "refuses bad keys instead of cutting them" do
      assert {:error, :invalid_aggregate} = ValueAggregate.spec("", nil, nil, [])
      assert {:error, :invalid_aggregate} = ValueAggregate.spec(<<255>>, nil, nil, [])
      assert {:error, :invalid_aggregate} = ValueAggregate.spec(nil, [1], nil, [])
      assert {:error, :invalid_aggregate} = ValueAggregate.spec(nil, nil, ["a", ""], [])
    end
  end

  describe "Repo.with_statement_timeout/3" do
    test "gives the result, or :timeout when a statement runs too long" do
      assert {:ok, 1} =
               Repo.with_statement_timeout(1_000, fn ->
                 %{rows: [[n]]} = Repo.query!("SELECT 1")
                 n
               end)

      assert {:error, :timeout} =
               Repo.with_statement_timeout(10, fn -> Repo.query!("SELECT pg_sleep(1)") end)

      # The connection is usable after, without the short timeout.
      assert %{rows: [[2]]} = Repo.query!("SELECT 2")
    end

    test "turns jit off only when asked" do
      assert {:ok, "off"} =
               Repo.with_statement_timeout(
                 1_000,
                 fn -> Repo.query!("SHOW jit").rows |> hd() |> hd() end,
                 jit: false
               )
    end
  end
end
