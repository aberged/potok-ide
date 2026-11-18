defmodule PotokIdeWeb.GroupLive.UnreadCapTest do
  @moduledoc """
  A group with more unread messages than any count goes to
  (`Social.unread_cap/0`) shows "99+", on its row, on every row above it and
  on the header's badge, and its chat opens on "99+ new messages".
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, group_with_members!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Value

  setup %{conn: conn} do
    {_account, owner} = account_with_profile!("cap-lv-owner")
    {account, reader} = account_with_profile!("cap-lv-reader")
    parent = group_with_members!(owner, [reader], %{})
    group = group_with_members!(owner, [reader], %{parent: parent})
    :ok = Social.mark_group_values_read(reader, group)

    now = DateTime.utc_now(:second)

    rows =
      for n <- 1..(Social.unread_cap() + 5) do
        %{
          group_id: group.id,
          creator_id: owner.id,
          content: "news #{n}",
          content_format: :markdown,
          is_data: false,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Value, rows)

    %{conn: log_in_account(conn, account), parent: parent, group: group}
  end

  test "rows and the header's badge show 99+", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#group-unread-badge-#{ctx.group.id}", "99+")
    assert has_element?(lv, "#group-sub-groups-unread-badge", "99+")
    assert has_element?(lv, "#nav-root-group-unread-badge", "99+")

    {:ok, root, _html} = live(ctx.conn, ~p"/groups/#{Social.get_root_group!().id}")
    assert has_element?(root, "#group-unread-badge-#{ctx.parent.id}", "99+")
  end

  test "the chat opens on 99+ new messages", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/values")

    assert render(lv) =~ "99+ new messages"
  end
end
