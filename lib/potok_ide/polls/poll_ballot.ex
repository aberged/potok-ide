defmodule PotokIde.Polls.PollBallot do
  @moduledoc """
  That a profile voted in a poll, and for what. In a secret poll `option_ids`
  stays empty, so that nothing ties a voter to an answer: the only trace of the
  choice is the count in `PotokIde.Polls.PollOption`.

  `account_id` keeps one account to one vote, whichever of its profiles votes.
  A profile several accounts share votes on its own and leaves it nil. Lists of
  voters go by profile only, as the account is what ties two profiles together.
  """

  use Ecto.Schema

  schema "poll_ballots" do
    field :option_ids, {:array, :integer}, default: []
    # When the voter last changed the vote.
    field :changed_at, :utc_datetime

    belongs_to :poll, PotokIde.Polls.Poll
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :account, PotokIde.Accounts.Account

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
