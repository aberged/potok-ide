defmodule PotokIde.Processes.Reach do
  @moduledoc """
  Which process drawn in Potok may call which, across the tree of groups.

  A process that others call (`trigger` `"process"`) is private or public
  (`app_processes.is_public`). A private one is called by the processes of
  its own group. A public one is called from the groups above its group and
  from those below it too: its ancestors and its descendants, never the
  branches beside it.

  Groups are walked upwards only, from a group to its ancestors, or from the
  public processes to theirs: never down a tree, which may be wide.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social.AppProcess

  # Public processes one drawing is offered, the nearest by id first.
  @max_public 200
  @timeout_ms 2_000

  @doc """
  Whether a process drawn in the group `caller_group_id` may call `callee`:
  a process of its own group, or a public one of a group above or below.
  """
  def callable?(%AppProcess{drawn: true, trigger: "process"} = callee, caller_group_id)
      when is_integer(caller_group_id) do
    callee.group_id == caller_group_id or
      (callee.is_public and related?(callee.group_id, caller_group_id))
  end

  def callable?(_callee, _caller_group_id), do: false

  @doc "Whether one of the two groups stands above the other in the tree."
  def related?(a, b) when is_integer(a) and is_integer(b) and a != b do
    sql = """
    WITH RECURSIVE up AS (
      SELECT g.id AS origin, g.parent_id AS id
      FROM groups g
      WHERE g.id = ANY($1::bigint[])
      UNION ALL
      SELECT up.origin, g.parent_id
      FROM up
      JOIN groups g ON g.id = up.id
    )
    SELECT 1 FROM up WHERE (origin = $2 AND id = $3) OR (origin = $3 AND id = $2) LIMIT 1
    """

    match?(%{num_rows: 1}, Repo.query!(sql, [[a, b], a, b]))
  end

  def related?(_a, _b), do: false

  @doc """
  The ids of the public processes of the groups above and below the group,
  at most #{@max_public}: those a process drawn in it may call beside its
  group's own. None when the look takes too long, as the editor that asks
  can do without.
  """
  def public_ids(group_id) when is_integer(group_id) do
    sql = """
    WITH RECURSIVE above AS (
      SELECT g.parent_id AS id FROM groups g WHERE g.id = $1
      UNION ALL
      SELECT g.parent_id FROM above JOIN groups g ON g.id = above.id
    ),
    up AS (
      SELECT p.id AS process_id, g.parent_id AS group_id
      FROM app_processes p
      JOIN groups g ON g.id = p.group_id
      WHERE p.is_public AND p.group_id <> $1
      UNION ALL
      SELECT up.process_id, g.parent_id
      FROM up
      JOIN groups g ON g.id = up.group_id
      WHERE up.group_id <> $1
    )
    SELECT id FROM (
      SELECT p.id
      FROM app_processes p
      WHERE p.is_public AND p.group_id = ANY(ARRAY(SELECT id FROM above WHERE id IS NOT NULL))
      UNION
      SELECT up.process_id FROM up WHERE up.group_id = $1
    ) found
    ORDER BY id
    LIMIT #{@max_public}
    """

    case Repo.with_statement_timeout(@timeout_ms, fn -> Repo.query!(sql, [group_id]) end,
           jit: false
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      {:error, :timeout} -> []
    end
  end
end
