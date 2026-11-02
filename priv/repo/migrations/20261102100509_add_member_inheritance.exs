defmodule PotokIde.Repo.Migrations.AddMemberInheritance do
  use Ecto.Migration

  # A group that inherits members holds every member of its parent, with
  # their roles there; `inherited` marks the rows that exist only for that,
  # which leave with the parent membership. Threads always inherit; the root,
  # direct groups and the root's children never do (the last one is checked
  # in `Social`, since it depends on the parent row).
  def up do
    alter table(:groups) do
      add :inherits_members, :boolean, null: false, default: false
    end

    alter table(:group_memberships) do
      add :inherited, :boolean, null: false, default: false
    end

    alter table(:group_member_roles) do
      add :inherited, :boolean, null: false, default: false
    end

    execute "UPDATE groups SET inherits_members = TRUE WHERE parent_value_id IS NOT NULL"

    create constraint(:groups, :groups_inherits_members_check,
             check: "NOT (inherits_members AND (is_root OR is_direct))"
           )

    create constraint(:groups, :groups_thread_inherits_members_check,
             check: "parent_value_id IS NULL OR inherits_members"
           )

    flush()

    backfill_threads()
  end

  def down do
    drop constraint(:groups, :groups_thread_inherits_members_check)
    drop constraint(:groups, :groups_inherits_members_check)

    alter table(:group_member_roles) do
      remove :inherited
    end

    alter table(:group_memberships) do
      remove :inherited
    end

    alter table(:groups) do
      remove :inherits_members
    end
  end

  # Threads copied their parent's members and roles once, when opened. Rows
  # still matching the parent become inherited, except the opener's, who
  # keeps the thread and its admin role; the parent's members who joined
  # later are added, with the thread read. Members who left the parent since
  # stay as direct members. Parents go first, as a thread can have threads of
  # its own.
  defp backfill_threads do
    %{rows: threads} =
      repo().query!("""
      WITH RECURSIVE tree AS (
        SELECT g.id, g.parent_id, g.creator_id, g.parent_value_id, 0 AS depth
        FROM groups g
        WHERE g.parent_id IS NULL
        UNION ALL
        SELECT c.id, c.parent_id, c.creator_id, c.parent_value_id, tree.depth + 1
        FROM groups c
        JOIN tree ON c.parent_id = tree.id
      )
      SELECT id, parent_id, creator_id
      FROM tree
      WHERE parent_value_id IS NOT NULL
      ORDER BY depth, id
      """)

    Enum.each(threads, fn [thread_id, parent_id, creator_id] ->
      params = [thread_id, parent_id, creator_id]

      repo().query!(
        """
        UPDATE group_memberships gm
        SET inherited = TRUE
        WHERE gm.group_id = $1
          AND gm.profile_id IS DISTINCT FROM $3
          AND EXISTS (
            SELECT 1 FROM group_memberships pm
            WHERE pm.group_id = $2 AND pm.profile_id = gm.profile_id
          )
        """,
        params
      )

      # Added members start with the thread's history read.
      repo().query!(
        """
        WITH added AS (
          INSERT INTO group_memberships (group_id, profile_id, inherited, inserted_at, updated_at)
          SELECT $1, pm.profile_id, TRUE, now(), now()
          FROM group_memberships pm
          WHERE pm.group_id = $2
          ON CONFLICT (group_id, profile_id) DO NOTHING
          RETURNING profile_id
        )
        INSERT INTO group_value_reads (profile_id, group_id, last_read_value_id, inserted_at, updated_at)
        SELECT added.profile_id, $1, latest.id, now(), now()
        FROM added
        CROSS JOIN (
          SELECT MAX(v.id) AS id FROM values v WHERE v.group_id = $1 AND v.is_data = FALSE
        ) latest
        WHERE latest.id IS NOT NULL
        ON CONFLICT (profile_id, group_id) DO UPDATE SET
          last_read_value_id =
            GREATEST(group_value_reads.last_read_value_id, EXCLUDED.last_read_value_id),
          updated_at = EXCLUDED.updated_at
        """,
        [thread_id, parent_id]
      )

      repo().query!(
        """
        UPDATE group_member_roles r
        SET inherited = TRUE
        WHERE r.group_id = $1
          AND r.profile_id IS DISTINCT FROM $3
          AND EXISTS (
            SELECT 1 FROM group_member_roles pr
            WHERE pr.group_id = $2 AND pr.profile_id = r.profile_id AND pr.role_key = r.role_key
          )
        """,
        params
      )

      repo().query!(
        """
        INSERT INTO group_member_roles (group_id, profile_id, role_key, inherited, inserted_at, updated_at)
        SELECT $1, pr.profile_id, pr.role_key, TRUE, now(), now()
        FROM group_member_roles pr
        JOIN group_memberships gm ON gm.group_id = $1 AND gm.profile_id = pr.profile_id
        WHERE pr.group_id = $2
        ON CONFLICT (group_id, profile_id, role_key) DO NOTHING
        """,
        [thread_id, parent_id]
      )
    end)
  end
end
