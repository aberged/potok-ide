defmodule PotokIde.Repo.Migrations.AddThreadMembershipFunction do
  use Ecto.Migration

  # Whether a profile is a member of a group or, as long as that is a thread,
  # of one above it, up to the first group that is none: who may open a thread
  # that hangs from it (`Social.join_thread/2`, `Visibility.inside/1`).
  #
  # A function, as Postgres prices the recursion written into a query at some
  # 900 a row and then reads and sorts all a profile wrote rather than stop at
  # a page of it (100 ms against 0.5 ms for 100,000 messages). Only threads
  # the profile is not in ask it.
  def up do
    execute """
    CREATE FUNCTION potok_member_up(p_group bigint, p_profile bigint) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE COST 100 AS $$
      SELECT EXISTS (
        WITH RECURSIVE up AS (
          SELECT g.id, g.parent_id, g.parent_value_id
          FROM groups g
          WHERE g.id = p_group
          UNION ALL
          SELECT g.id, g.parent_id, g.parent_value_id
          FROM up
          JOIN groups g ON g.id = up.parent_id
          WHERE up.parent_value_id IS NOT NULL
        )
        SELECT 1
        FROM up
        JOIN group_memberships m ON m.group_id = up.id AND m.profile_id = p_profile
      )
    $$
    """
  end

  def down do
    execute "DROP FUNCTION potok_member_up(bigint, bigint)"
  end
end
