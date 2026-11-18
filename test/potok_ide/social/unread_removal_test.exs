defmodule PotokIde.Social.UnreadRemovalTest do
  @moduledoc """
  What a group's members hear about unread values when a value or a member
  goes: a deleted value names itself and its author, so each page takes it
  out of its counts without a query (`Social.remove_unread_value/3`); a
  removed member tells only that member. Who joins starts with the history
  read.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {_account, owner} = account_with_profile!("ur-owner")
    {_account, reader} = account_with_profile!("ur-reader")
    group = group_with_members!(owner, [reader])
    %{owner: owner, reader: reader, group: group}
  end

  defp post!(profile, group, text) do
    {:ok, value} = Social.create_value(profile, group, %{"content" => text})
    value
  end

  test "a deleted value names itself and its author to the group's members", ctx do
    value = post!(ctx.owner, ctx.group, "soon gone")
    Social.subscribe_group_unread(ctx.group.id)
    {group_id, value_id, owner_id} = {ctx.group.id, value.id, ctx.owner.id}

    {:ok, _deleted} = Social.delete_value(ctx.owner, value)

    assert_received {:group_value_removed, ^group_id, ^value_id, ^owner_id}
    refute_received {:group_members_unread_changed, ^group_id}
  end

  test "removing a member tells the other members nothing about unread", ctx do
    Social.subscribe_group_unread(ctx.group.id)
    group_id = ctx.group.id

    {:ok, _member} = Social.remove_group_member(ctx.owner, ctx.group, ctx.reader)

    refute_received {:group_members_unread_changed, ^group_id}
    refute_received {:group_value_removed, ^group_id, _value_id, _creator_id}
  end

  test "an unread value taken out of the overview counts one less, up the tree", ctx do
    kept = post!(ctx.owner, ctx.group, "stays")
    gone = post!(ctx.owner, ctx.group, "goes")
    overview = Social.unread_overview(ctx.reader)
    assert overview.groups[ctx.group.id].own == 2

    assert {:ok, overview} = Social.remove_unread_value(overview, ctx.group.id, gone.id)
    assert overview.groups[ctx.group.id].own == 1
    assert overview.total == 1

    # The same numbers a count after the delete finds.
    {:ok, _deleted} = Social.delete_value(ctx.owner, gone)
    recount = Social.unread_overview(ctx.reader)
    assert Map.take(overview, [:total, :groups]) == Map.take(recount, [:total, :groups])
    assert recount.read_marks[ctx.group.id] < kept.id
  end

  test "who joins by invitation or by request starts with the history read", ctx do
    _before = post!(ctx.owner, ctx.group, "before anyone new")
    {_account, invited} = account_with_profile!("ur-invited")
    {_account, asking} = account_with_profile!("ur-asking")

    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, invited)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, invited)

    {:ok, public} = Social.update_group(ctx.owner, ctx.group, %{"is_public" => true})
    {:ok, request} = Social.request_group_access(asking, public)
    {:ok, _asking} = Social.accept_group_join_request(ctx.owner, public, request.id)

    for profile <- [invited, asking] do
      assert Social.unread_overview(profile).total == 0
    end

    _after = post!(ctx.owner, ctx.group, "after they came")

    for profile <- [invited, asking] do
      assert Social.unread_overview(profile).groups[ctx.group.id].own == 1
    end
  end

  test "the other member of a new direct chat sees its first value unread", ctx do
    {:ok, chat} = Social.get_or_create_direct_group(ctx.owner, ctx.reader)
    _first = post!(ctx.owner, chat, "hi")

    assert Social.unread_overview(ctx.reader).groups[chat.id].own == 1
  end

  test "a value read already, or in a group with nothing counted, changes nothing", ctx do
    read = post!(ctx.owner, ctx.group, "read")
    :ok = Social.mark_group_values_read(ctx.reader, ctx.group)
    overview = Social.unread_overview(ctx.reader)

    assert Social.remove_unread_value(overview, ctx.group.id, read.id) == :unchanged

    _later = post!(ctx.owner, ctx.group, "unread")
    overview = Social.unread_overview(ctx.reader)
    assert Social.remove_unread_value(overview, ctx.group.id, read.id) == :unchanged
    assert Social.remove_unread_value(overview, ctx.group.id + 1_000_000, read.id) == :unchanged
  end
end
