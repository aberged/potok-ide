defmodule PotokIde.Repo.Migrations.AddPollVoterKinds do
  use Ecto.Migration

  # Who votes in a poll, by the kind of profile (`PotokIde.Social.Identity`):
  # unique ones, one vote per account, and those several accounts share,
  # either once for all their holders, or each holder for themself.
  def up do
    alter table(:polls) do
      add :unique_votes, :string, null: false, default: "yes"
      add :shared_votes, :string, null: false, default: "as_one"
    end

    create constraint(:polls, :polls_unique_votes_check, check: "unique_votes IN ('yes', 'no')")

    create constraint(:polls, :polls_shared_votes_check,
             check: "shared_votes IN ('as_one', 'each_holder', 'no')"
           )

    # Somebody has to be able to vote.
    create constraint(:polls, :polls_votes_check,
             check: "unique_votes = 'yes' OR shared_votes <> 'no'"
           )

    alter table(:poll_ballots) do
      # The ballot of one holder of a shared profile, counted on that holder's
      # account: several of them name the same profile.
      add :by_holder, :boolean, null: false, default: false
    end

    # A profile still votes once, unless each of its holders does. Not keyed
    # on `account_id IS NULL`: deleting an account clears it.
    drop unique_index(:poll_ballots, [:poll_id, :profile_id])
    create unique_index(:poll_ballots, [:poll_id, :profile_id], where: "NOT by_holder")
  end

  def down do
    drop unique_index(:poll_ballots, [:poll_id, :profile_id])
    execute "DELETE FROM poll_ballots WHERE by_holder"
    create unique_index(:poll_ballots, [:poll_id, :profile_id])

    alter table(:poll_ballots) do
      remove :by_holder
    end

    drop constraint(:polls, :polls_votes_check)
    drop constraint(:polls, :polls_shared_votes_check)
    drop constraint(:polls, :polls_unique_votes_check)

    alter table(:polls) do
      remove :shared_votes
      remove :unique_votes
    end
  end
end
