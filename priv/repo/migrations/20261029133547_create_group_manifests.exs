defmodule PotokIde.Repo.Migrations.CreateGroupManifests do
  use Ecto.Migration

  # Mirrors PotokIde.Social.GroupRole.default_everyone_permissions/0 at the
  # time of writing; migrations must not depend on application modules.
  @default_everyone_permissions ~w(post_values react open_threads create_subgroups invite_members mention_roles)

  def change do
    # A group with a row here has its own manifest; any other group uses the
    # manifest of its nearest ancestor that has one.
    create table(:group_manifests) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_manifests, [:group_id])

    # `key` is "admin", "everyone" or a UUID. Copying a manifest keeps the keys,
    # so role assignments stay valid when a group gets its own manifest.
    create table(:group_roles) do
      add :manifest_id, references(:group_manifests, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :allowed, {:array, :string}, null: false, default: []
      add :denied, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_roles, [:manifest_id, :key])

    create unique_index(:group_roles, [:manifest_id, "lower(name)"],
             name: :group_roles_manifest_id_lower_name_index
           )

    # Every member implicitly has "everyone", so it is never stored. The
    # composite reference drops a member's roles together with the membership.
    create table(:group_member_roles, primary_key: false) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      add :profile_id,
          references(:group_memberships,
            column: :profile_id,
            with: [group_id: :group_id],
            on_delete: :delete_all
          ),
          null: false

      add :role_key, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_member_roles, [:group_id, :profile_id, :role_key])
    create index(:group_member_roles, [:profile_id])

    create constraint(:group_member_roles, :group_member_roles_role_key_check,
             check: "role_key <> 'everyone'"
           )

    alter table(:values) do
      add :mentions, :map, null: false, default: %{}
      add :mentioned_profile_ids, {:array, :bigint}, null: false, default: []
    end

    execute(
      """
      INSERT INTO group_manifests (group_id, inserted_at, updated_at)
      SELECT id, now(), now() FROM groups WHERE is_root
      """,
      ""
    )

    execute(
      """
      INSERT INTO group_roles (manifest_id, key, name, allowed, denied, position, inserted_at, updated_at)
      SELECT m.id, r.key, r.key, r.allowed, '{}', r.position, now(), now()
      FROM group_manifests m
      CROSS JOIN (VALUES
        ('admin', '{}'::varchar[], 0),
        ('everyone', '{#{Enum.join(@default_everyone_permissions, ",")}}'::varchar[], 1)
      ) AS r(key, allowed, position)
      """,
      ""
    )

    # Creators become their groups' admins, which keeps today's creator rights.
    execute(
      """
      INSERT INTO group_member_roles (group_id, profile_id, role_key, inserted_at, updated_at)
      SELECT g.id, g.creator_id, 'admin', now(), now()
      FROM groups g
      JOIN group_memberships gm ON gm.group_id = g.id AND gm.profile_id = g.creator_id
      WHERE NOT g.is_root
      """,
      ""
    )
  end
end
