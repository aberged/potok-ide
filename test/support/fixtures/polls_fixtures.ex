defmodule PotokIde.PollsFixtures do
  @moduledoc """
  Polls for tests.
  """

  alias PotokIde.Polls
  alias PotokIde.Repo
  alias PotokIde.Social.AccountProfile

  @zone "Europe/Belgrade"

  @doc "Form params for a poll with two answers, with `attrs` over them."
  def poll_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        "question" => "Where do we go?",
        "options" => %{"0" => %{"text" => "Sea"}, "1" => %{"text" => "Mountains"}}
      },
      attrs
    )
  end

  def create_poll!(profile, group, attrs \\ %{}, opts \\ [announce: false]) do
    {:ok, poll} = Polls.create_poll(profile, group, poll_attrs(attrs), @zone, opts)
    Polls.get_poll(poll.id)
  end

  @doc "The poll's answers, in order."
  def option_ids(poll),
    do: poll.id |> Polls.get_poll() |> Map.fetch!(:options) |> Enum.map(& &1.id)

  @doc "Votes for the answer at `index` in the poll."
  def vote!(profile, account, poll, index \\ 0) do
    {:ok, poll} = Polls.vote(profile, account, poll, [Enum.at(option_ids(poll), index)])
    poll
  end

  @doc "`account` also holds `profile`, as it does a shared profile it accepted."
  def share_profile!(profile, account) do
    Repo.insert!(%AccountProfile{account_id: account.id, profile_id: profile.id})
  end

  @doc "Local time in the test zone, as a deadline field of a form holds it, `hours` from now."
  def local_in(hours) do
    DateTime.utc_now()
    |> DateTime.add(hours, :hour)
    |> DateTime.shift_zone!(@zone)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end
end
