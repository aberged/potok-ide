defmodule PotokIde.Repo.Migrations.AddInheritRoleKeysToGroups do
  use Ecto.Migration

  # A group that inherits members can take in only the parent's members who
  # hold one of these roles there (`Social.MemberInheritance`); empty means
  # every member. `text[]` rather than `varchar[]`, so the inheritance queries
  # compare it with `text[]` parameters without casts. Threads inherit lazily
  # and never pick roles.
  def change do
    alter table(:groups) do
      add :inherit_role_keys, {:array, :text}, null: false, default: []
    end

    create constraint(:groups, :groups_inherit_role_keys_check,
             check:
               "cardinality(inherit_role_keys) = 0 OR (inherits_members AND parent_value_id IS NULL)"
           )
  end
end
