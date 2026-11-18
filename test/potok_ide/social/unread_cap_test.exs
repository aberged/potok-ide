defmodule PotokIde.Social.UnreadCapTest do
  @moduledoc """
  No group counts more than `Social.unread_cap/0` unread values: every count
  stops there (the overview, the badge, the divider), and a count kept in
  memory stops there too, so it stays what a count would find.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Value

  setup do
    {_account, owner} = account_with_profile!("cap-owner")
    {_account, reader} = account_with_profile!("cap-reader")
    group = group_with_members!(owner, [reader])
    :ok = Social.mark_group_values_read(reader, group)
    %{owner: owner, reader: reader, group: group}
  end

  # Written past `Social`, so no message goes out for each.
  defp many!(%{owner: owner, group: group}, count) do
    now = DateTime.utc_now(:second)

    rows =
      for n <- 1..count do
        %{
          group_id: group.id,
          creator_id: owner.id,
          content: "value #{n}",
          content_format: :markdown,
          is_data: false,
          inserted_at: now,
          updated_at: now
        }
      end

    {^count, _} = Repo.insert_all(Value, rows)
  end

  test "every count of a busy group stops at the cap", ctx do
    cap = Social.unread_cap()
    many!(ctx, cap + 20)

    assert Social.unread_overview(ctx.reader).groups[ctx.group.id].own == cap
    assert Social.unread_overview(ctx.reader).total == cap
    assert Social.root_group_unread_snapshot(ctx.reader).count == cap
    assert Social.nav_counts(ctx.reader).root_unread == cap

    # Opening the chat: the divider stands at the first unread value, with
    # the count up to the cap.
    assert %{count: ^cap, value_id: first} = Social.read_group_chat(ctx.reader, ctx.group)
    assert is_integer(first)
  end

  test "below the cap the counts are exact", ctx do
    many!(ctx, 7)
    assert Social.unread_overview(ctx.reader).groups[ctx.group.id].own == 7
    assert %{count: 7} = Social.read_group_chat(ctx.reader, ctx.group)
  end

  test "a value past the cap leaves a count in memory as it was", ctx do
    many!(ctx, Social.unread_cap())
    overview = Social.unread_overview(ctx.reader)
    {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "one more"})

    unread = %{
      value_id: value.id,
      group_id: ctx.group.id,
      creator_id: ctx.owner.id,
      chain: [%{id: ctx.group.id, parent_id: ctx.group.parent_id, public?: false}]
    }

    member_ids = MapSet.new([ctx.group.id])
    assert {:ok, ^overview} = Social.add_unread_value(overview, unread, member_ids)

    # A deleted value cannot be taken out either: the group may hold more.
    assert Social.remove_unread_value(overview, ctx.group.id, value.id) == :unchanged
  end
end
