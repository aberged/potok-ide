defmodule PotokIde.Repo.Migrations.CreateGroupAccessChanges do
  use Ecto.Migration

  # The access history of a group (`PotokIde.Social.AccessHistory`): who gave
  # or took which role, changed the statute or a setting that lets people in,
  # admitted, removed or blocked whom, and when. It starts empty: what happened
  # before is not known, but for the roles a decision gave (`poll_id`).
  # Deleting a profile forgets it here too, and the row says only that
  # someone did it.
  def change do
    create table(:group_access_changes) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :actor_id, references(:profiles, on_delete: :nilify_all)
      add :subject_id, references(:profiles, on_delete: :nilify_all)
      add :poll_id, references(:polls, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :role_key, :string
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:group_access_changes, [:group_id, :inserted_at, :id])
    create index(:group_access_changes, [:actor_id], where: "actor_id IS NOT NULL")
    create index(:group_access_changes, [:subject_id], where: "subject_id IS NOT NULL")
    create index(:group_access_changes, [:poll_id], where: "poll_id IS NOT NULL")

    create constraint(:group_access_changes, :group_access_changes_kind_check,
             check:
               "kind IN ('role_given', 'role_taken', 'permission_set', 'role_added', " <>
                 "'role_renamed', 'role_removed', 'request_rule_set', 'manifest_copied', " <>
                 "'manifest_dropped', 'settings_changed', 'alt_visibility_set', " <>
                 "'join_rule_set', 'elections_on', 'elections_off', 'member_admitted', " <>
                 "'member_removed', 'member_blocked', 'member_unblocked')"
           )

    # A change of a role names the role.
    create constraint(:group_access_changes, :group_access_changes_role_check,
             check:
               "role_key IS NOT NULL OR NOT (kind = 'role_given' OR kind = 'role_taken' " <>
                 "OR kind = 'permission_set' OR kind = 'role_added' OR kind = 'role_renamed' " <>
                 "OR kind = 'role_removed' OR kind = 'request_rule_set')"
           )
  end
end
