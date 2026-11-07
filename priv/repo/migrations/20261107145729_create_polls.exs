defmodule PotokIde.Repo.Migrations.CreatePolls do
  use Ecto.Migration

  def change do
    create table(:polls) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      # The chat value that carries the poll: a poll and its message go together.
      add :value_id, references(:values, on_delete: :delete_all)
      add :question, :string, size: 300, null: false
      add :description, :text, null: false, default: ""
      add :kind, :string, null: false, default: "single"
      add :max_choices, :integer
      add :allow_change, :boolean, null: false, default: true
      add :secret, :boolean, null: false, default: false
      add :is_public, :boolean, null: false, default: false
      add :allow_member_options, :boolean, null: false, default: false
      add :closes_at, :utc_datetime
      add :closed_at, :utc_datetime
      add :reminder_minutes, :integer
      add :remind_at, :utc_datetime
      add :last_nudged_at, :utc_datetime
      add :voter_role_keys, {:array, :string}, null: false, default: ["everyone"]
      add :results_role_keys, {:array, :string}, null: false, default: ["everyone"]
      add :details_role_keys, {:array, :string}, null: false, default: []
      add :results_when, :string, null: false, default: "voted"
      add :details_when, :string, null: false, default: "always"
      add :quorum_percent, :integer
      add :majority, :string, null: false, default: "none"
      add :eligible_count, :integer
      add :outcome, :string
      add :voters_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:polls, [:group_id, :id])
    create index(:polls, [:creator_id])
    create unique_index(:polls, [:value_id], where: "value_id IS NOT NULL")
    # What `PotokIde.Polls.Deadlines` looks for: polls past their deadline and
    # reminders that are due.
    create index(:polls, [:closes_at], where: "closed_at IS NULL AND closes_at IS NOT NULL")
    create index(:polls, [:remind_at], where: "remind_at IS NOT NULL")
    # The public polls of the root overview.
    create index(:polls, [:id], where: "is_public", name: :polls_public_index)

    create constraint(:polls, :polls_kind_check, check: "kind IN ('single', 'multiple')")

    create constraint(:polls, :polls_results_when_check,
             check: "results_when IN ('always', 'voted', 'closed')"
           )

    create constraint(:polls, :polls_details_when_check,
             check: "details_when IN ('always', 'closed')"
           )

    create constraint(:polls, :polls_majority_check,
             check: "majority IN ('none', 'plurality', 'simple', 'two_thirds', 'absolute')"
           )

    create constraint(:polls, :polls_outcome_check,
             check: "outcome IN ('passed', 'failed', 'no_quorum', 'tie')"
           )

    create constraint(:polls, :polls_max_choices_check, check: "max_choices >= 1")

    create constraint(:polls, :polls_quorum_percent_check,
             check: "quorum_percent BETWEEN 1 AND 100"
           )

    create constraint(:polls, :polls_voters_count_check, check: "voters_count >= 0")

    # What a secret poll promises holds whatever the code does: no ballot can
    # change, as nothing says what it held, and no count shows before the end.
    create constraint(:polls, :polls_secret_check,
             check:
               "NOT secret OR (NOT allow_change AND results_when = 'closed' AND NOT allow_member_options)"
           )

    # No timestamps: a change here is a vote, and the time of the last change
    # of each answer would give away what the last voter chose.
    create table(:poll_options) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      # Who added it, when members may add answers; nil for the organizer's.
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      add :text, :string, size: 200, null: false
      add :position, :integer, null: false, default: 0
      add :votes_count, :integer, null: false, default: 0
    end

    create index(:poll_options, [:poll_id, :position])
    create index(:poll_options, [:creator_id])

    create constraint(:poll_options, :poll_options_votes_count_check, check: "votes_count >= 0")

    alter table(:polls) do
      # Set when the poll closes, with its outcome.
      add :winner_option_id, references(:poll_options, on_delete: :nilify_all)
    end

    create index(:polls, [:winner_option_id])

    # One voter's ballot. `option_ids` stays empty in a secret poll, which
    # leaves only the counts in `poll_options`, so nothing ties a voter to an
    # answer. Both keys are cleared with their rows, so that a vote that was
    # given stays counted, and nulls do not collide in the unique indexes.
    create table(:poll_ballots) do
      add :poll_id, references(:polls, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :nilify_all)
      # One account, one vote; nil for a profile that several accounts share.
      add :account_id, references(:accounts, on_delete: :nilify_all)
      add :option_ids, {:array, :integer}, null: false, default: []
      add :changed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:poll_ballots, [:poll_id, :profile_id])
    create unique_index(:poll_ballots, [:poll_id, :account_id])
    create index(:poll_ballots, [:profile_id])
    create index(:poll_ballots, [:account_id])
  end
end
