defmodule PotokIde.Polls.Outcome do
  @moduledoc """
  The decision of a poll as it closes: whether enough voted, and whether an
  answer got the majority asked for. Whole numbers only, so that a vote exactly
  at a limit lands on the side the rule says.

  `voters` are the ballots given, `eligible` those with a right to vote. An
  abstention is an answer like any other, so it counts among the votes given.
  """

  alias PotokIde.Polls.Poll

  @doc "`{outcome, winner_option_id}`, both nil for a poll that decides nothing."
  def decide(%Poll{majority: :none}, _options, _voters, _eligible), do: {nil, nil}

  def decide(%Poll{} = poll, options, voters, eligible) do
    if quorum_met?(poll.quorum_percent, voters, eligible) do
      by_majority(poll.majority, options, voters, eligible)
    else
      {:no_quorum, nil}
    end
  end

  @doc "Whether enough of those with a right to vote did: nil asks for no quorum."
  def quorum_met?(nil, _voters, _eligible), do: true
  def quorum_met?(percent, voters, eligible), do: voters * 100 >= percent * eligible

  defp by_majority(_majority, _options, 0, _eligible), do: {:failed, nil}

  defp by_majority(:plurality, options, _voters, _eligible) do
    case Enum.sort_by(options, & &1.votes_count, :desc) do
      [first, second | _rest] when first.votes_count == second.votes_count -> {:tie, nil}
      [first | _rest] -> {:passed, first.id}
    end
  end

  defp by_majority(majority, options, voters, eligible) do
    top = Enum.max_by(options, & &1.votes_count)

    if enough?(majority, top.votes_count, voters, eligible),
      do: {:passed, top.id},
      else: {:failed, nil}
  end

  defp enough?(:simple, votes, voters, _eligible), do: votes * 2 > voters
  defp enough?(:two_thirds, votes, voters, _eligible), do: votes * 3 >= voters * 2
  defp enough?(:absolute, votes, _voters, eligible), do: votes * 2 > eligible
end
