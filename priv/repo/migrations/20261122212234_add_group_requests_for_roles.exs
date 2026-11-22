defmodule PotokIde.Repo.Migrations.AddGroupRequestsForRoles do
  use Ecto.Migration

  # Requests for roles, on joining and from members, and admission by a vote
  # (`PotokIde.Social.GroupRequests`). What each request asked, who decided it
  # and why stays as a record of its own.
  def up do
    alter table(:group_join_requests) do
      # Why they ask, in their own words, for whoever decides.
      add :note, :string, size: 500
      # The roles they ask for along with joining.
      add :role_keys, {:array, :string}, null: false, default: []
      # The vote on admitting them, while it runs.
      add :poll_id, references(:polls, on_delete: :nilify_all)
    end

    create index(:group_join_requests, [:poll_id], where: "poll_id IS NOT NULL")

    # A member's request for roles: the roles still waiting for whoever
    # decides. One per member and group; it goes with the membership.
    create table(:group_role_requests) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      add :profile_id,
          references(:group_memberships,
            column: :profile_id,
            with: [group_id: :group_id],
            on_delete: :delete_all
          ),
          null: false

      add :role_keys, {:array, :string}, null: false
      add :note, :string, size: 500

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_role_requests, [:group_id, :profile_id])
    create index(:group_role_requests, [:group_id, :inserted_at, :id])
    create index(:group_role_requests, [:profile_id])

    create constraint(:group_role_requests, :group_role_requests_role_keys_check,
             check: "cardinality(role_keys) > 0"
           )

    # What became of a request: admission (no role) or one role, given,
    # refused or put to a vote, by whom (nobody when the rule put it to a
    # vote), with the reason given.
    create table(:group_request_decisions) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :role_key, :string
      add :decision, :string, null: false
      add :decider_id, references(:profiles, on_delete: :nilify_all)
      add :poll_id, references(:polls, on_delete: :nilify_all)
      add :reason, :string, size: 300

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:group_request_decisions, [:profile_id, :inserted_at])
    create index(:group_request_decisions, [:decider_id, :inserted_at])
    create index(:group_request_decisions, [:group_id, :profile_id, :role_key])
    create index(:group_request_decisions, [:poll_id], where: "poll_id IS NOT NULL")

    create constraint(:group_request_decisions, :group_request_decisions_decision_check,
             check: "decision IN ('granted', 'declined', 'voted')"
           )

    # Admitted by a vote, an approval names the poll instead of a member.
    alter table(:group_join_request_approvals) do
      add :poll_id, references(:polls, on_delete: :nilify_all)
    end

    execute "ALTER TABLE group_join_request_approvals ALTER COLUMN approver_id DROP NOT NULL"

    create constraint(:group_join_request_approvals, :group_join_request_approvals_by_check,
             check: "approver_id IS NOT NULL OR poll_id IS NOT NULL"
           )

    alter table(:polls) do
      # Raised by a request: it never goes away, as the request waits on it.
      add :from_request, :boolean, null: false, default: false
    end

    drop constraint(:polls, :polls_effect_kind_check)

    create constraint(:polls, :polls_effect_kind_check,
             check: "effect IN ('grant', 'revoke', 'elect', 'end_elections', 'admit')"
           )

    drop constraint(:polls, :polls_effect_status_check)

    create constraint(:polls, :polls_effect_status_check,
             check:
               "effect_status IS NULL OR (effect_status IN ('applied', 'rejected', 'not_a_member', 'role_gone', 'inherited_role', 'last_admin', 'request_gone', 'already_member') AND effect IS NOT NULL)"
           )

    drop constraint(:polls, :polls_effect_check)

    create constraint(:polls, :polls_effect_check,
             check: """
             effect IS NULL OR (
               kind = 'single' AND NOT is_public AND majority <> 'none'
               AND quorum_percent IS NOT NULL AND closes_at IS NOT NULL
               AND voter_role_keys = '{everyone}'
               AND (effect = 'end_elections' OR effect = 'admit' OR effect_role_key IS NOT NULL)
               AND (effect = 'elect' OR majority <> 'plurality')
             )
             """
           )
  end

  def down do
    drop constraint(:polls, :polls_effect_check)

    create constraint(:polls, :polls_effect_check,
             check: """
             effect IS NULL OR (
               kind = 'single' AND NOT is_public AND majority <> 'none'
               AND quorum_percent IS NOT NULL AND closes_at IS NOT NULL
               AND voter_role_keys = '{everyone}'
               AND (effect = 'end_elections' OR effect_role_key IS NOT NULL)
               AND (effect = 'elect' OR majority <> 'plurality')
             )
             """
           )

    execute "UPDATE polls SET effect_status = NULL WHERE effect_status IN ('request_gone', 'already_member')"
    execute "DELETE FROM polls WHERE effect = 'admit'"

    drop constraint(:polls, :polls_effect_status_check)

    create constraint(:polls, :polls_effect_status_check,
             check:
               "effect_status IS NULL OR (effect_status IN ('applied', 'rejected', 'not_a_member', 'role_gone', 'inherited_role', 'last_admin') AND effect IS NOT NULL)"
           )

    drop constraint(:polls, :polls_effect_kind_check)

    create constraint(:polls, :polls_effect_kind_check,
             check: "effect IN ('grant', 'revoke', 'elect', 'end_elections')"
           )

    alter table(:polls) do
      remove :from_request
    end

    drop constraint(:group_join_request_approvals, :group_join_request_approvals_by_check)
    execute "DELETE FROM group_join_request_approvals WHERE approver_id IS NULL"

    execute "ALTER TABLE group_join_request_approvals ALTER COLUMN approver_id SET NOT NULL"

    alter table(:group_join_request_approvals) do
      remove :poll_id
    end

    drop table(:group_request_decisions)
    drop table(:group_role_requests)

    drop index(:group_join_requests, [:poll_id], where: "poll_id IS NOT NULL")

    alter table(:group_join_requests) do
      remove :poll_id
      remove :role_keys
      remove :note
    end
  end
end
