defmodule PotokIde.Repo.Migrations.AddMemberCountToGroups do
  use Ecto.Migration

  # How many people belong to a group, kept with the row, so a page shows it
  # without counting the memberships on every view (a group of 10,000 counted
  # 10,000 rows for its header). Postgres keeps it: a statement trigger on
  # `group_memberships` adds what one statement inserted and takes away what
  # one deleted, a group at a time, so a thread or an inheriting group that
  # takes in thousands of members updates its row once.
  #
  # People only (`profiles.kind = 'person'`), as the members list shows them;
  # an app's process is not counted. A deleted membership counts when its
  # profile is still there and a person: the only profiles ever deleted are
  # processes (`AppProcesses.sweep/0`), whose memberships go with them. The
  # root, which everyone belongs to, keeps 0, so signing up never waits on
  # its row; `updated_at` stays, as group pictures' addresses depend on it.

  def up do
    alter table(:groups) do
      add :member_count, :integer, null: false, default: 0
    end

    # No membership may come or go until the count below and the triggers
    # stand, as one.
    execute "LOCK TABLE group_memberships IN SHARE ROW EXCLUSIVE MODE"

    execute """
    CREATE FUNCTION groups_count_members() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        UPDATE groups g
        SET member_count = g.member_count + c.n
        FROM (
          SELECT n.group_id, COUNT(*) AS n
          FROM new_memberships n
          JOIN profiles p ON p.id = n.profile_id AND p.kind = 'person'
          GROUP BY n.group_id
        ) c
        WHERE g.id = c.group_id AND NOT g.is_root;
      ELSE
        UPDATE groups g
        SET member_count = GREATEST(g.member_count - c.n, 0)
        FROM (
          SELECT o.group_id, COUNT(*) AS n
          FROM old_memberships o
          JOIN profiles p ON p.id = o.profile_id AND p.kind = 'person'
          GROUP BY o.group_id
        ) c
        WHERE g.id = c.group_id AND NOT g.is_root;
      END IF;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER group_memberships_count_inserted
    AFTER INSERT ON group_memberships
    REFERENCING NEW TABLE AS new_memberships
    FOR EACH STATEMENT EXECUTE FUNCTION groups_count_members()
    """

    execute """
    CREATE TRIGGER group_memberships_count_deleted
    AFTER DELETE ON group_memberships
    REFERENCING OLD TABLE AS old_memberships
    FOR EACH STATEMENT EXECUTE FUNCTION groups_count_members()
    """

    execute """
    UPDATE groups g
    SET member_count = c.n
    FROM (
      SELECT gm.group_id, COUNT(*) AS n
      FROM group_memberships gm
      JOIN profiles p ON p.id = gm.profile_id AND p.kind = 'person'
      GROUP BY gm.group_id
    ) c
    WHERE g.id = c.group_id AND NOT g.is_root
    """
  end

  def down do
    execute "DROP TRIGGER group_memberships_count_deleted ON group_memberships"
    execute "DROP TRIGGER group_memberships_count_inserted ON group_memberships"
    execute "DROP FUNCTION groups_count_members()"

    alter table(:groups) do
      remove :member_count
    end
  end
end
