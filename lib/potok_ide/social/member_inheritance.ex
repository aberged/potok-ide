defmodule PotokIde.Social.MemberInheritance do
  @moduledoc """
  Keeps the groups that inherit members in step with their parents.

  - Such a group holds every member of its parent, with the roles they hold
    there. Those rows are marked `inherited` and leave with the parent
    membership or role.
  - With `Group.inherit_role_keys` it holds only the parent's members who
    hold one of those roles there, still with all the roles they hold
    there. They leave on losing the last of them; a direct member who holds
    none keeps their membership but not the parent's roles.
  - Members and roles added in the group itself are direct and stay.
  - The process of an app (`Profile.kind` `:process`) is never inherited: it
    is a member only where `AppProcesses` put it.
  - A chain of inheriting groups is followed down from the parent, so a
    group below inherits what the one above holds, direct or inherited.
  - A thread inherits lazily: nobody is added to it up front, and a member of
    its group comes in only when they take part (`join/3`: opening it,
    writing in it, the value it was opened on, a mention). Once in, they hold
    the roles they hold in the group and leave with that membership, like
    any inherited member.

  Writes only: callers run `sync/3` in the transaction that changed a
  membership or a role, then broadcast what it reports (see `PotokIde.Social`).
  """

  @doc """
  Brings `group_id`, when it inherits, and every inheriting group below it
  in line with their parents, for `profile_ids` or, with nil, for every
  member. Parents go first, so a change reaches the whole chain.

  Returns the groups that changed as
  `%{group_id: id, added: [profile_id], removed: [profile_id], roles_changed?: boolean}`.
  """
  def sync(repo, group_id, profile_ids \\ nil)
      when is_integer(group_id) and (is_list(profile_ids) or is_nil(profile_ids)) do
    now = NaiveDateTime.utc_now(:second)

    repo
    |> inheriting_chain(group_id)
    |> Enum.map(fn [id, parent_id, thread?, keys] ->
      sync_group(repo, id, parent_id, profile_ids, now, not thread?, keys)
    end)
    |> Enum.reject(&(&1.added == [] and &1.removed == [] and not &1.roles_changed?))
  end

  @doc """
  Brings the group in line with the roles it now inherits by, when they
  changed. `keep_profile_id`, who changed them, stays: when they no longer
  hold one of those roles in the parent, their membership and roles turn
  direct first. Inheriting groups below follow.

  Returns the groups that changed, like `sync/3`.
  """
  def refilter(repo, group_id, keep_profile_id)
      when is_integer(group_id) and is_integer(keep_profile_id) do
    %{rows: [[parent_id, keys]]} =
      repo.query!("SELECT parent_id, inherit_role_keys FROM groups WHERE id = $1", [group_id])

    kept =
      if keys != [] and not holds_any_role?(repo, parent_id, keep_profile_id, keys) do
        make_direct(repo, group_id, keep_profile_id)
        [%{group_id: group_id, added: [], removed: [], roles_changed?: true}]
      else
        []
      end

    kept ++ sync(repo, group_id)
  end

  @doc """
  Takes `profile_ids` into thread `thread_id` as inherited members, with the
  roles they hold in its group and a read marker at its newest value, and
  into the threads above it first when it was opened inside another thread.
  Only members of the group come in. Returns the groups that changed, like
  `sync/3`.
  """
  def join(repo, thread_id, profile_ids) when is_integer(thread_id) and is_list(profile_ids) do
    now = NaiveDateTime.utc_now(:second)

    repo
    |> thread_chain(thread_id)
    |> Enum.map(fn [id, parent_id] ->
      sync_group(repo, id, parent_id, profile_ids, now, true, [])
    end)
    |> Enum.reject(&(&1.added == [] and &1.removed == [] and not &1.roles_changed?))
  end

  @doc """
  Turns the group's inherited members and roles into direct ones, when it
  stops inheriting: nobody leaves it.
  """
  def release(repo, group_id) when is_integer(group_id) do
    repo.query!(
      "UPDATE group_memberships SET inherited = FALSE WHERE group_id = $1 AND inherited",
      [group_id]
    )

    repo.query!(
      "UPDATE group_member_roles SET inherited = FALSE WHERE group_id = $1 AND inherited",
      [group_id]
    )

    :ok
  end

  @doc """
  Sends the group's inherited members away, when it stops inheriting and they
  are meant to leave, unlike in `release/2`. Direct members stay, and
  `keep_profile_id` turns into one. Inheriting groups below follow.

  Returns the groups that changed, like `sync/3`.
  """
  def drop_inherited(repo, group_id, keep_profile_id)
      when is_integer(group_id) and is_integer(keep_profile_id) do
    make_direct(repo, group_id, keep_profile_id)

    removed = profile_ids(repo, drop_members_sql(), [group_id])
    repo.query!("DELETE FROM group_member_roles WHERE group_id = $1 AND inherited", [group_id])

    [
      %{group_id: group_id, added: [], removed: removed, roles_changed?: true}
      | sync(repo, group_id)
    ]
  end

  # `profile_id`'s membership and roles in the group turn direct, so nothing
  # the parent does takes them away.
  defp make_direct(repo, group_id, profile_id) do
    repo.query!(
      "UPDATE group_memberships SET inherited = FALSE WHERE group_id = $1 AND profile_id = $2 AND inherited",
      [group_id, profile_id]
    )

    repo.query!(
      "UPDATE group_member_roles SET inherited = FALSE WHERE group_id = $1 AND profile_id = $2 AND inherited",
      [group_id, profile_id]
    )

    :ok
  end

  defp holds_any_role?(repo, group_id, profile_id, keys) do
    %{rows: [[held?]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM group_member_roles
          WHERE group_id = $1 AND profile_id = $2 AND role_key = ANY($3::text[])
        )
        """,
        [group_id, profile_id, keys]
      )

    held?
  end

  # The group itself when it inherits, then its inheriting descendants
  # reached through inheriting groups only, as
  # `[id, parent_id, thread?, inherit_role_keys]` by depth.
  defp inheriting_chain(repo, group_id) do
    sql = """
    WITH RECURSIVE chain AS (
      SELECT g.id, g.parent_id, g.inherits_members, g.parent_value_id IS NOT NULL AS thread,
             g.inherit_role_keys, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT child.id, child.parent_id, child.inherits_members,
             child.parent_value_id IS NOT NULL, child.inherit_role_keys, chain.depth + 1
      FROM groups child
      JOIN chain ON child.parent_id = chain.id
      WHERE child.inherits_members
    )
    SELECT id, parent_id, thread, inherit_role_keys
    FROM chain
    WHERE inherits_members
    ORDER BY depth, id
    """

    %{rows: rows} = repo.query!(sql, [group_id], cache_statement: "inheritance_chain_v3")
    rows
  end

  # Thread `thread_id` and the threads above it up to the first group that
  # is not one, as `[id, parent_id]` from the top down.
  defp thread_chain(repo, thread_id) do
    sql = """
    WITH RECURSIVE up AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1 AND g.parent_value_id IS NOT NULL
      UNION ALL
      SELECT parent.id, parent.parent_id, up.depth + 1
      FROM groups parent
      JOIN up ON parent.id = up.parent_id
      WHERE parent.parent_value_id IS NOT NULL
    )
    SELECT id, parent_id
    FROM up
    ORDER BY depth DESC
    """

    %{rows: rows} = repo.query!(sql, [thread_id], cache_statement: "inheritance_thread_chain")
    rows
  end

  # `add?` false for a thread outside `join/3`: those who leave the group go
  # and roles follow it, but nobody comes in. With no `keys` the statements
  # are those every thread runs on each open and write, left as they were;
  # with keys they take a last parameter.
  defp sync_group(repo, group_id, parent_id, profile_ids, now, add?, keys) do
    by_roles = if keys == [], do: [], else: [keys]

    removed =
      profile_ids(repo, remove_members_sql(keys), [group_id, parent_id, profile_ids | by_roles])

    added =
      if add?,
        do:
          profile_ids(
            repo,
            add_members_sql(keys),
            [group_id, parent_id, profile_ids, now | by_roles]
          ),
        else: []

    roles_removed =
      profile_ids(repo, remove_roles_sql(keys), [group_id, parent_id, profile_ids | by_roles])

    roles_added =
      profile_ids(repo, add_roles_sql(keys), [group_id, parent_id, profile_ids, now | by_roles])

    %{
      group_id: group_id,
      added: added,
      removed: removed,
      roles_changed?: removed != [] or roles_removed != [] or roles_added != []
    }
  end

  defp profile_ids(repo, sql, params) do
    %{rows: rows} = repo.query!(sql, params)
    rows |> Enum.map(fn [profile_id] -> profile_id end) |> Enum.uniq()
  end

  # Inherited members who left the parent go, with their read markers (as in
  # `Social.remove_group_member/3`); their roles go with the membership. By
  # roles, those who hold none of them there go: a role there means a
  # membership there (the roles' foreign key).
  defp remove_members_sql([]) do
    """
    WITH removed AS (
      DELETE FROM group_memberships gm
      WHERE gm.group_id = $1
        AND gm.inherited
        AND ($3::bigint[] IS NULL OR gm.profile_id = ANY($3::bigint[]))
        AND NOT EXISTS (
          SELECT 1 FROM group_memberships pm
          WHERE pm.group_id = $2 AND pm.profile_id = gm.profile_id
        )
      RETURNING gm.profile_id
    ),
    reads AS (
      DELETE FROM group_value_reads gvr
      USING removed
      WHERE gvr.group_id = $1 AND gvr.profile_id = removed.profile_id
    )
    SELECT profile_id FROM removed
    """
  end

  defp remove_members_sql(_keys) do
    """
    WITH removed AS (
      DELETE FROM group_memberships gm
      WHERE gm.group_id = $1
        AND gm.inherited
        AND ($3::bigint[] IS NULL OR gm.profile_id = ANY($3::bigint[]))
        AND NOT EXISTS (
          SELECT 1 FROM group_member_roles pr
          WHERE pr.group_id = $2 AND pr.profile_id = gm.profile_id
            AND pr.role_key = ANY($4::text[])
        )
      RETURNING gm.profile_id
    ),
    reads AS (
      DELETE FROM group_value_reads gvr
      USING removed
      WHERE gvr.group_id = $1 AND gvr.profile_id = removed.profile_id
    )
    SELECT profile_id FROM removed
    """
  end

  # Like `remove_members_sql/0`, for every inherited member, whatever the parent holds.
  defp drop_members_sql do
    """
    WITH removed AS (
      DELETE FROM group_memberships gm
      WHERE gm.group_id = $1 AND gm.inherited
      RETURNING gm.profile_id
    ),
    reads AS (
      DELETE FROM group_value_reads gvr
      USING removed
      WHERE gvr.group_id = $1 AND gvr.profile_id = removed.profile_id
    )
    SELECT profile_id FROM removed
    """
  end

  # A direct member stays direct: the conflict leaves the row alone. New
  # members start with the group's history read, so joining a parent does
  # not flood them with every inheriting group's past values. The process of
  # an app stays where it was put (`AppProcesses`). By roles, the members
  # come from the parent's holders of those roles.
  defp add_members_sql([]) do
    """
    WITH added AS (
      INSERT INTO group_memberships (group_id, profile_id, inherited, inserted_at, updated_at)
      SELECT $1::bigint, pm.profile_id, TRUE, $4, $4
      FROM group_memberships pm
      JOIN profiles p ON p.id = pm.profile_id AND p.kind = 'person'
      WHERE pm.group_id = $2
        AND ($3::bigint[] IS NULL OR pm.profile_id = ANY($3::bigint[]))
      ON CONFLICT (group_id, profile_id) DO NOTHING
      RETURNING profile_id
    ),
    #{reads_of_added_sql()}
    SELECT profile_id FROM added
    """
  end

  defp add_members_sql(_keys) do
    """
    WITH added AS (
      INSERT INTO group_memberships (group_id, profile_id, inherited, inserted_at, updated_at)
      SELECT $1::bigint, holders.profile_id, TRUE, $4, $4
      FROM (
        SELECT DISTINCT pr.profile_id
        FROM group_member_roles pr
        WHERE pr.group_id = $2
          AND pr.role_key = ANY($5::text[])
          AND ($3::bigint[] IS NULL OR pr.profile_id = ANY($3::bigint[]))
      ) holders
      JOIN profiles p ON p.id = holders.profile_id AND p.kind = 'person'
      ON CONFLICT (group_id, profile_id) DO NOTHING
      RETURNING profile_id
    ),
    #{reads_of_added_sql()}
    SELECT profile_id FROM added
    """
  end

  defp reads_of_added_sql do
    """
    reads AS (
      INSERT INTO group_value_reads (profile_id, group_id, last_read_value_id, inserted_at, updated_at)
      SELECT added.profile_id, $1::bigint, latest.id, $4, $4
      FROM added
      CROSS JOIN (
        SELECT MAX(v.id) AS id FROM values v WHERE v.group_id = $1::bigint AND v.is_data = FALSE
      ) latest
      WHERE latest.id IS NOT NULL
      ON CONFLICT (profile_id, group_id) DO UPDATE SET
        last_read_value_id =
          GREATEST(group_value_reads.last_read_value_id, EXCLUDED.last_read_value_id),
        updated_at = EXCLUDED.updated_at
    )
    """
  end

  # Inherited roles go when the parent took them back. By roles, all of a
  # member's inherited roles also go when they hold none of those roles
  # there any more: a direct member stays, without the parent's roles.
  defp remove_roles_sql([]) do
    """
    DELETE FROM group_member_roles r
    WHERE r.group_id = $1
      AND r.inherited
      AND ($3::bigint[] IS NULL OR r.profile_id = ANY($3::bigint[]))
      AND NOT EXISTS (
        SELECT 1 FROM group_member_roles pr
        WHERE pr.group_id = $2 AND pr.profile_id = r.profile_id AND pr.role_key = r.role_key
      )
    RETURNING r.profile_id
    """
  end

  defp remove_roles_sql(_keys) do
    """
    DELETE FROM group_member_roles r
    WHERE r.group_id = $1
      AND r.inherited
      AND ($3::bigint[] IS NULL OR r.profile_id = ANY($3::bigint[]))
      AND (
        NOT EXISTS (
          SELECT 1 FROM group_member_roles pr
          WHERE pr.group_id = $2 AND pr.profile_id = r.profile_id AND pr.role_key = r.role_key
        )
        OR NOT EXISTS (
          SELECT 1 FROM group_member_roles held
          WHERE held.group_id = $2 AND held.profile_id = r.profile_id
            AND held.role_key = ANY($4::text[])
        )
      )
    RETURNING r.profile_id
    """
  end

  # Members of the group get the roles they hold in the parent; a role they
  # were given in the group itself stays direct. By roles, only the members
  # who hold one of those roles there get them.
  defp add_roles_sql([]) do
    """
    INSERT INTO group_member_roles (group_id, profile_id, role_key, inherited, inserted_at, updated_at)
    SELECT $1::bigint, pr.profile_id, pr.role_key, TRUE, $4, $4
    FROM group_member_roles pr
    JOIN group_memberships gm ON gm.group_id = $1::bigint AND gm.profile_id = pr.profile_id
    WHERE pr.group_id = $2
      AND ($3::bigint[] IS NULL OR pr.profile_id = ANY($3::bigint[]))
    ON CONFLICT (group_id, profile_id, role_key) DO NOTHING
    RETURNING profile_id
    """
  end

  defp add_roles_sql(_keys) do
    """
    INSERT INTO group_member_roles (group_id, profile_id, role_key, inherited, inserted_at, updated_at)
    SELECT $1::bigint, pr.profile_id, pr.role_key, TRUE, $4, $4
    FROM group_member_roles pr
    JOIN group_memberships gm ON gm.group_id = $1::bigint AND gm.profile_id = pr.profile_id
    WHERE pr.group_id = $2
      AND ($3::bigint[] IS NULL OR pr.profile_id = ANY($3::bigint[]))
      AND EXISTS (
        SELECT 1 FROM group_member_roles held
        WHERE held.group_id = $2 AND held.profile_id = pr.profile_id
          AND held.role_key = ANY($5::text[])
      )
    ON CONFLICT (group_id, profile_id, role_key) DO NOTHING
    RETURNING profile_id
    """
  end
end
