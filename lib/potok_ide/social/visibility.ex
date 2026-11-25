defmodule PotokIde.Social.Visibility do
  @moduledoc """
  Who sees a group, written once. There are two rules:

  * **may see**: a public group, or one the profile is a member of. A group
    page's sheet, the areas a group lies in, the area menu, borders.
  * **listed**: what the root's lists and map show, of the groups the profile
    may see: its memberships, and public groups, all of them while the root's
    "Public groups" switch is on, otherwise only those it follows and those
    on the way to one of its memberships or followed groups. The SQL needs
    the `mine` and `member_paths` tables of `Social`'s membership walk,
    where `member_paths` holds the followed groups too.
  * **reads the chat** (`in_read_chats/2`): a member, anyone signed in where the
    chat is open, and in a thread whoever may open it.

  Threads and direct conversations are never among plain groups.

  A guest, nil in place of a profile, may see the public plain groups, the ones
  it gets a preview of (`Group.guest_preview?/1`): what an app shows a visitor
  without an account at a group that opened its description to guests.
  """

  import Ecto.Query

  alias PotokIde.Events.Event
  alias PotokIde.Social.{Group, GroupMembership, Profile}

  @doc """
  The plain groups the profile may see: public ones and its memberships. A
  guest (nil) sees the public ones; the root is never public.
  """
  def plain_groups(nil) do
    from(g in Group,
      as: :group,
      where: is_nil(g.parent_value_id) and g.is_direct == false,
      where: g.is_public and not g.is_root
    )
  end

  def plain_groups(%Profile{id: profile_id}) do
    from(g in Group,
      as: :group,
      where: is_nil(g.parent_value_id) and g.is_direct == false,
      where:
        g.is_public or
          exists(
            from(m in GroupMembership,
              where: m.group_id == parent_as(:group).id and m.profile_id == ^profile_id
            )
          )
    )
  end

  @doc """
  The chat values of `query` (its binding `:value`) in the chats `profile` reads
  now, as `Access.can_read_chat?/2` has it for one group: those of the groups it
  is in, and the open ones (`Group.open_chat?/1`), where someone outside does not
  see the announcement of an event that is not public.

  A thread is read by whoever may open it (`Social.join_thread/2`): a member of
  it, of a thread above it or of the group they all hang from. Being in the
  thread itself is not asked, as that comes with opening it and goes with
  leaving the group.
  """
  def in_read_chats(query, %Profile{id: profile_id}) do
    hidden =
      from(e in Event,
        where: e.value_id == parent_as(:value).id and not e.is_public,
        select: 1
      )

    query
    |> join(:inner, [value: v], g in Group, on: g.id == v.group_id, as: :group)
    |> join(:left, [value: v], m in GroupMembership,
      on: m.group_id == v.group_id and m.profile_id == ^profile_id,
      as: :membership
    )
    |> where(
      [group: g, membership: m],
      not is_nil(m.profile_id) or
        (g.has_public_chat and g.is_public and not g.is_root and not g.is_direct and
           is_nil(g.parent_value_id) and not exists(hidden)) or
        (not is_nil(g.parent_value_id) and
           fragment(
             """
             EXISTS (
               WITH RECURSIVE up AS (
                 SELECT p.id, p.parent_id, p.parent_value_id FROM groups p WHERE p.id = ?
                 UNION ALL
                 SELECT p.id, p.parent_id, p.parent_value_id
                 FROM up JOIN groups p ON p.id = up.parent_id
                 WHERE up.parent_value_id IS NOT NULL
               )
               SELECT 1 FROM up
               JOIN group_memberships um ON um.group_id = up.id AND um.profile_id = ?
             )
             """,
             g.parent_id,
             ^profile_id
           ))
    )
  end

  @doc "SQL: the profile in `profile` (a parameter) may see group `table`."
  def may_see_sql(table, profile) do
    "(#{table}.is_public OR EXISTS (SELECT 1 FROM group_memberships vm " <>
      "WHERE vm.group_id = #{table}.id AND vm.profile_id = #{profile}))"
  end

  @doc """
  SQL: group `table` is listed for the profile, every public group with the
  switch on (`public?`), otherwise only the followed ones and those on the
  way to a membership or a follow.
  """
  def listed_sql(table, true = _public?),
    do: "(#{table}.is_public OR #{table}.id IN (SELECT group_id FROM mine))"

  def listed_sql(table, false = _public?) do
    "(#{table}.id IN (SELECT group_id FROM mine) OR " <>
      "(#{table}.is_public AND #{table}.id IN (SELECT id FROM member_paths)))"
  end
end
