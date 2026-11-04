defmodule PotokIdeWeb.GroupLive.QueryCountTest do
  # Not async: the query handler is global, so no other test may run meanwhile.
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  # Every page view runs these on the database (they were 9 for the first
  # HTML, 13 for the root page and ~27 for a chat page). Raise a bound only
  # for a query added on purpose. The chat page's 18th loads the events that
  # values announced, for their cards; its 19th and 20th the tags the viewer
  # sees on the values and on the group, and the root page's 9th those on the
  # sub-groups. Its 10th finds the groups only the root lists, whose parent the
  # viewer cannot see.
  @max_dead_render_queries 5
  @max_root_page_queries 10
  @max_chat_page_queries 20

  setup %{conn: conn} do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "query-count",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "query-count-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false,
        "home_page" => :chat
      })

    {:ok, _value} =
      Social.create_value(profile, group, %{"content" => "hello", "content_format" => :markdown})

    %{
      conn: log_in_account(conn, Accounts.get_account!(account.id)),
      group: group,
      profile: profile
    }
  end

  test "the first HTML of a group page queries only for its header", %{conn: conn, group: group} do
    {_html, count} = count_queries(fn -> get(conn, ~p"/groups/#{group.id}/values") end)

    assert count <= @max_dead_render_queries
  end

  test "the root page loads with a bounded number of queries", %{conn: conn} do
    {dead, live} = page_queries(conn, ~p"/groups/#{Social.get_root_group!().id}")

    assert dead <= @max_dead_render_queries
    assert live <= @max_root_page_queries
  end

  test "a chat page loads with a bounded number of queries", %{conn: conn, group: group} do
    {dead, live} = page_queries(conn, ~p"/groups/#{group.id}/values")

    assert dead <= @max_dead_render_queries
    assert live <= @max_chat_page_queries
  end

  test "a value another member posts updates the root page without a query", %{
    conn: conn,
    group: group,
    profile: profile
  } do
    {:ok, other} =
      Social.create_profile_for_account(account_fixture(), %{
        username: "qc-other",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, invitation} = Social.invite_profile_to_group(profile, group, other)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, other)
    {:ok, lv, _html} = live(conn, ~p"/groups/#{Social.get_root_group!().id}")

    # Only the page's own queries count, not the post's.
    {_html, count} =
      count_queries(
        fn ->
          {:ok, _value} = Social.create_value(other, group, %{"content" => "news"})
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
    assert has_element?(lv, "#group-unread-badge-#{group.id}", "1")
  end

  test "a value reads no more rows in a bigger group", %{group: group, profile: profile} do
    {:ok, _value} = Social.create_value(profile, group, %{"content" => "warm up"})

    {_value, few} =
      read_rows(fn -> Social.create_value(profile, group, %{"content" => "few members"}) end)

    for number <- 1..5 do
      {:ok, member} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "qc-member-#{number}",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitation} = Social.invite_profile_to_group(profile, group, member)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    end

    {_value, many} =
      read_rows(fn -> Social.create_value(profile, group, %{"content" => "more members"}) end)

    assert many == few
  end

  # `live/2` renders the first HTML again before it connects; the connected
  # mount's share is the difference.
  defp page_queries(conn, path) do
    {_conn, dead} = count_queries(fn -> get(conn, path) end)
    {{:ok, _lv, _html}, both} = count_queries(fn -> live(conn, path) end)
    {dead, both - dead}
  end

  # Queries run in the process that makes them, which the handler runs in
  # too, so `only` (a pid) can pick one process's queries.
  defp count_queries(fun, only \\ :any) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:potok_ide, :repo, :query],
        &__MODULE__.handle_query/4,
        {self(), ref, only}
      )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp read_rows(fun) do
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:potok_ide, :repo, :query],
        &__MODULE__.handle_rows/4,
        {self(), ref}
      )

    try do
      result = fun.()
      {result, drain_rows(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  # `BEGIN` and `COMMIT` have no row count.
  def handle_rows(_event, _measurements, %{result: {:ok, %{num_rows: rows}}}, {test_pid, ref})
      when is_integer(rows) do
    send(test_pid, {:rows, ref, rows})
  end

  def handle_rows(_event, _measurements, _metadata, _config), do: :ok

  defp drain_rows(ref, total) do
    receive do
      {:rows, ^ref, rows} -> drain_rows(ref, total + rows)
    after
      0 -> total
    end
  end

  def handle_query(_event, _measurements, _metadata, {test_pid, ref, only}) do
    if only in [:any, self()], do: send(test_pid, {:query, ref})
  end

  defp drain(ref, count) do
    receive do
      {:query, ^ref} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end
