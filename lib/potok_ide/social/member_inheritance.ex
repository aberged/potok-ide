defmodule PotokIde.Social.MemberInheritance do
  @moduledoc """
  Keeps the groups that inherit members in step with their parents.

  - Such a group holds every member of its parent, with the roles they hold
    there. Those rows are marked `inherited` and leave with the parent
    membership or role.
  - Members and roles added in the group itself are direct and stay.
  - A chain of inheriting groups is followed down from the parent, so a
    group below inherits what the one above holds, direct or inherited.

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
    |> Enum.map(fn [id, parent_id] -> sync_group(repo, id, parent_id, profile_ids, now) end)
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
    repo.query!(
      "UPDATE group_memberships SET inherited = FALSE WHERE group_id = $1 AND profile_id = $2 AND inherited",
      [group_id, keep_profile_id]
    )

    repo.query!(
      "UPDATE group_member_roles SET inherited = FALSE WHERE group_id = $1 AND profile_id = $2 AND inherited",
      [group_id, keep_profile_id]
    )

    removed = profile_ids(repo, drop_members_sql(), [group_id])
    repo.query!("DELETE FROM group_member_roles WHERE group_id = $1 AND inherited", [group_id])

    [
      %{group_id: group_id, added: [], removed: removed, roles_changed?: true}
      | sync(repo, group_id)
    ]
  end

  # The group itself when it inherits, then its inheriting descendants
  # reached through inheriting groups only, as `[id, parent_id]` by depth.
  defp inheriting_chain(repo, group_id) do
    sql = """
    WITH RECURSIVE chain AS (
      SELECT g.id, g.parent_id, g.inherits_members, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT child.id, child.parent_id, child.inherits_members, chain.depth + 1
      FROM groups child
      JOIN chain ON child.parent_id = chain.id
      WHERE child.inherits_members
    )
    SELECT id, parent_id
    FROM chain
    WHERE inherits_members
    ORDER BY depth, id
    """

    %{rows: rows} = repo.query!(sql, [group_id], cache_statement: "inheritance_chain")
    rows
  end

  defp sync_group(repo, group_id, parent_id, profile_ids, now) do
    removed = profile_ids(repo, remove_members_sql(), [group_id, parent_id, profile_ids])
    added = profile_ids(repo, add_members_sql(), [group_id, parent_id, profile_ids, now])
    roles_removed = profile_ids(repo, remove_roles_sql(), [group_id, parent_id, profile_ids])
    roles_added = profile_ids(repo, add_roles_sql(), [group_id, parent_id, profile_ids, now])

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
  # `Social.remove_group_member/3`); their roles go with the membership.
  defp remove_members_sql do
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
  # not flood them with every inheriting group's past values.
  defp add_members_sql do
    """
    WITH added AS (
      INSERT INTO group_memberships (group_id, profile_id, inherited, inserted_at, updated_at)
      SELECT $1::bigint, pm.profile_id, TRUE, $4, $4
      FROM group_memberships pm
      WHERE pm.group_id = $2
        AND ($3::bigint[] IS NULL OR pm.profile_id = ANY($3::bigint[]))
      ON CONFLICT (group_id, profile_id) DO NOTHING
      RETURNING profile_id
    ),
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
    SELECT profile_id FROM added
    """
  end

  defp remove_roles_sql do
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

  # Members of the group get the roles they hold in the parent; a role they
  # were given in the group itself stays direct.
  defp add_roles_sql do
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
end
