defmodule PotokIde.Repo.Migrations.AddPollEffectsAndElectedAdmins do
  use Ecto.Migration

  def change do
    alter table(:polls) do
      # What the decision changes, shown to voters before they vote and done
      # as the poll closes (`PotokIde.Polls.Effects`); nil for a plain poll.
      add :effect, :string
      add :effect_role_key, :string, size: 64
      # Whom `grant` and `revoke` name.
      add :effect_profile_id, references(:profiles, on_delete: :nilify_all)
      # An election takes the role from its other holders.
      add :effect_replace, :boolean, null: false, default: false
      # What came of it, written as it closes.
      add :effect_status, :string
      # The run of a drawn process that raised the poll and waits for it.
      add :process_instance_id, references(:value_processes, on_delete: :nilify_all)
    end

    create index(:polls, [:effect_profile_id], where: "effect_profile_id IS NOT NULL")
    create index(:polls, [:process_instance_id], where: "process_instance_id IS NOT NULL")

    create constraint(:polls, :polls_effect_kind_check,
             check: "effect IN ('grant', 'revoke', 'elect', 'end_elections')"
           )

    create constraint(:polls, :polls_effect_status_check,
             check:
               "effect_status IS NULL OR (effect_status IN ('applied', 'rejected', 'not_a_member', 'role_gone', 'inherited_role', 'last_admin') AND effect IS NOT NULL)"
           )

    # What a decision that changes roles promises holds whatever the code
    # does: one answer, the whole group votes, by a majority, with a quorum
    # and a deadline. Only an election may be won by the most votes.
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

    alter table(:poll_options) do
      # The member an answer of an election stands for.
      add :profile_id, references(:profiles, on_delete: :nilify_all)
      # The answer that carries out a decision to grant, revoke or end.
      add :approves, :boolean, null: false, default: false
    end

    create index(:poll_options, [:profile_id], where: "profile_id IS NOT NULL")

    create constraint(:poll_options, :poll_options_effect_check,
             check: "NOT (approves AND profile_id IS NOT NULL)"
           )

    alter table(:group_member_roles) do
      # The decision a role was given by; nil for one an admin gave.
      add :poll_id, references(:polls, on_delete: :nilify_all)
    end

    create index(:group_member_roles, [:poll_id], where: "poll_id IS NOT NULL")

    alter table(:groups) do
      # Admins come and go only by decisions of polls.
      add :elects_admins, :boolean, null: false, default: false
    end

    create constraint(:groups, :groups_elects_admins_check,
             check:
               "NOT elects_admins OR (NOT is_root AND NOT is_direct AND parent_value_id IS NULL)"
           )
  end
end
