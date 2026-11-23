defmodule PotokIde.Repo.Migrations.AddMemberLeftToGroupAccessChanges do
  use Ecto.Migration

  # A member who leaves a group of their own accord is kept in its access
  # history too (`member_left`), with the roles they held there.
  @kinds_before ~w(role_given role_taken permission_set role_added role_renamed role_removed
                   request_rule_set manifest_copied manifest_dropped settings_changed
                   alt_visibility_set join_rule_set elections_on elections_off member_admitted
                   member_removed member_blocked member_unblocked)

  def up do
    drop constraint(:group_access_changes, :group_access_changes_kind_check)

    create constraint(:group_access_changes, :group_access_changes_kind_check,
             check: kind_check(@kinds_before ++ ["member_left"])
           )
  end

  def down do
    execute "DELETE FROM group_access_changes WHERE kind = 'member_left'"
    drop constraint(:group_access_changes, :group_access_changes_kind_check)

    create constraint(:group_access_changes, :group_access_changes_kind_check,
             check: kind_check(@kinds_before)
           )
  end

  defp kind_check(kinds), do: "kind IN (" <> Enum.map_join(kinds, ", ", &"'#{&1}'") <> ")"
end
