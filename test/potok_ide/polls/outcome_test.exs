defmodule PotokIde.Polls.OutcomeTest do
  use ExUnit.Case, async: true

  alias PotokIde.Polls.{Outcome, Poll, PollOption}

  defp poll(attrs), do: struct!(%Poll{majority: :plurality}, attrs)

  defp options(counts) do
    counts
    |> Enum.with_index(1)
    |> Enum.map(fn {count, id} -> %PollOption{id: id, votes_count: count} end)
  end

  test "a poll without a decision has no outcome" do
    assert Outcome.decide(poll(majority: :none), options([3, 1]), 4, 10) == {nil, nil}
  end

  describe "the quorum" do
    test "needs that share of those with a right to vote" do
      poll = poll(quorum_percent: 50)

      assert Outcome.decide(poll, options([3, 1]), 4, 9) == {:no_quorum, nil}
      assert Outcome.decide(poll, options([4, 1]), 5, 10) == {:passed, 1}
    end

    test "is met exactly at the limit, which stays exact with thirds" do
      assert Outcome.quorum_met?(50, 5, 10)
      refute Outcome.quorum_met?(50, 4, 9)
      assert Outcome.quorum_met?(34, 17, 50)
      refute Outcome.quorum_met?(67, 2, 3)
    end

    test "comes before the majority" do
      assert Outcome.decide(poll(quorum_percent: 100), options([9, 0]), 9, 10) ==
               {:no_quorum, nil}
    end
  end

  describe "the most votes" do
    test "win" do
      assert Outcome.decide(poll(majority: :plurality), options([1, 4, 2]), 7, 20) == {:passed, 2}
    end

    test "tied at the top decide nothing, ties below do not matter" do
      assert Outcome.decide(poll(majority: :plurality), options([3, 3, 1]), 7, 20) == {:tie, nil}
      assert Outcome.decide(poll(majority: :plurality), options([4, 1, 1]), 6, 20) == {:passed, 1}
    end

    test "without votes decide nothing" do
      assert Outcome.decide(poll(majority: :plurality), options([0, 0]), 0, 20) == {:failed, nil}
    end
  end

  describe "more than half of the votes" do
    test "half is not enough" do
      assert Outcome.decide(poll(majority: :simple), options([3, 3]), 6, 20) == {:failed, nil}
      assert Outcome.decide(poll(majority: :simple), options([4, 3]), 7, 20) == {:passed, 1}
    end

    test "an abstention counts among the votes" do
      # For, against, abstained.
      assert Outcome.decide(poll(majority: :simple), options([4, 3, 2]), 9, 20) == {:failed, nil}
    end
  end

  describe "two thirds of the votes" do
    test "are met exactly at the limit" do
      assert Outcome.decide(poll(majority: :two_thirds), options([4, 2]), 6, 20) == {:passed, 1}
      assert Outcome.decide(poll(majority: :two_thirds), options([3, 2]), 5, 20) == {:failed, nil}
    end
  end

  describe "more than half of those with a right to vote" do
    test "counts everyone who could have voted" do
      assert Outcome.decide(poll(majority: :absolute), options([5, 0]), 5, 10) == {:failed, nil}
      assert Outcome.decide(poll(majority: :absolute), options([6, 0]), 6, 10) == {:passed, 1}
    end
  end
end
