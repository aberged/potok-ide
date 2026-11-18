defmodule PotokIde.Repo.Migrations.RemoveThreadNonParticipants do
  use Ecto.Migration

  # A thread used to copy every member of its group in when it was opened,
  # and every later member of the group too. It now takes members in only as
  # they take part (`MemberInheritance.join/3`), so the copies of those who
  # never did go: their memberships in threads, with the roles that go with
  # a membership (foreign key) and their read markers. The thread's
  # `member_count` follows (trigger of add_member_count_to_groups).
  #
  # Kept are the direct members (whoever opened the thread, and anyone given
  # a membership in it directly), and of the inherited ones whoever:
  #
  # * wrote a value in the thread,
  # * wrote the value the thread was opened on,
  # * has a read marker that was not written with the copy: a copy got its
  #   marker in the same statement as its membership, with the same
  #   `inserted_at`, and a marker that moved since has a later `updated_at`;
  #   opening the thread writes one of those.
  #
  # Nothing comes back on the way down: the copies were derived, and opening
  # a thread takes its group's members in again.

  def up do
    execute """
    WITH removed AS (
      DELETE FROM group_memberships gm
      USING groups t
      WHERE t.id = gm.group_id
        AND t.parent_value_id IS NOT NULL
        AND gm.inherited
        AND t.creator_id IS DISTINCT FROM gm.profile_id
        AND NOT EXISTS (
          SELECT 1 FROM "values" v
          WHERE v.group_id = t.id AND v.creator_id = gm.profile_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM "values" r
          WHERE r.id = t.parent_value_id AND r.creator_id = gm.profile_id
        )
        AND NOT EXISTS (
          SELECT 1 FROM group_value_reads gvr
          WHERE gvr.group_id = gm.group_id
            AND gvr.profile_id = gm.profile_id
            AND (gvr.inserted_at <> gm.inserted_at OR gvr.updated_at > gvr.inserted_at)
        )
      RETURNING gm.group_id, gm.profile_id
    )
    DELETE FROM group_value_reads gvr
    USING removed
    WHERE gvr.group_id = removed.group_id AND gvr.profile_id = removed.profile_id
    """
  end

  def down, do: :ok
end
