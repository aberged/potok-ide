defmodule PotokIdeWeb.GroupLive.QueryCountTest do
  # Not async: the query handler is global, so no other test may run meanwhile.
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Polls
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.ProfileField

  # Every page view runs these on the database (they were 9 for the first
  # HTML, 13 for the root page and ~27 for a chat page). Raise a bound only
  # for a query added on purpose. The chat page's 18th loads the events that
  # values announced, for their cards; its 19th and 20th the tags the viewer
  # sees on the values and on the group, and the root page's 9th those on the
  # sub-groups. Its 10th finds the groups only the root lists, whose parent the
  # viewer cannot see, and its 11th the newest message of each listed group,
  # for its row. The chat page's 21st loads the polls that values carry,
  # and its 22nd, like the first HTML's 6th, asks whether the group has a poll,
  # for the bar of sections. The chat page's 23rd, like the first HTML's 7th,
  # reads whether the group sent notices, whether the viewer follows it and
  # how many do, for the bell and the bar (`Notices.group_state/2`). Its 24th
  # asks whether a group without an app of its own description has another
  # app or a process, for the menu's Processes tab.
  @max_dead_render_queries 7
  @max_root_page_queries 11
  @max_chat_page_queries 24
  # The access overview: what every tab of a group page loads, then its own
  # reads (`AccessOverview.load/3`, `PageRules.facts/1`), none of them per
  # member: the people are counted by the sets of roles they hold. Its 26th
  # reads the access history, with who did what joined.
  @max_access_page_queries 26

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

  test "a vote updates an open chat without a query", %{
    conn: conn,
    group: group,
    profile: profile
  } do
    voter_account = account_fixture()

    {:ok, voter} =
      Social.create_profile_for_account(voter_account, %{
        username: "qc-voter",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, invitation} = Social.invite_profile_to_group(profile, group, voter)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, voter)

    {:ok, poll} =
      Polls.create_poll(
        profile,
        group,
        %{
          "question" => "Where to?",
          "results_when" => "always",
          "options" => %{"0" => %{"text" => "Sea"}, "1" => %{"text" => "Hills"}}
        },
        "Etc/UTC"
      )

    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")
    [option | _rest] = Polls.get_poll(poll.id).options

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _poll} = Polls.vote(voter, voter_account, poll, [option.id])
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
    assert lv |> element("#group-poll-tally-style") |> render() =~ "poll-count-#{option.id}"
  end

  # A member who manages nothing: a manager's own counts (requests to
  # approve, invitations sent) are read on their pages, as they should be.
  test "a join request costs a member's open chat no query", %{profile: profile} do
    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "qc-public-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true,
        "home_page" => :chat
      })

    {member_conn, _member} = member_conn("qc-member", group, profile)
    requester = other_profile("qc-requester")
    {:ok, lv, _html} = live(member_conn, ~p"/groups/#{group.id}/values")

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _request} = Social.request_group_access(requester, group)
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
  end

  test "a join request reaches a manager's badge", %{conn: conn, profile: profile} do
    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "qc-public-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true,
        "home_page" => :chat
      })

    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")
    {:ok, _request} = Social.request_group_access(other_profile("qc-requester"), group)

    assert has_element?(lv, "#group-pending-join-requests-badge-#{group.id}", "1")
  end

  test "a new member shows in a member's header without a query", %{
    group: group,
    profile: profile
  } do
    {member_conn, _member} = member_conn("qc-member", group, profile)
    joiner = other_profile("qc-joiner")
    {:ok, invitation} = Social.invite_profile_to_group(profile, group, joiner)
    {:ok, lv, _html} = live(member_conn, ~p"/groups/#{group.id}/values")
    refute lv |> element("#group-members-stack") |> render() =~ "qc-joiner"

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _accepted} = Social.accept_group_invitation(invitation, joiner)
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
    assert lv |> element("#group-members-stack") |> render() =~ "qc-joiner"
  end

  test "a deleted value lowers a member's count without a query", %{
    group: group,
    profile: profile
  } do
    {member_conn, member} = member_conn("qc-member", group, profile)
    :ok = Social.mark_group_values_read(member, group)
    {:ok, gone} = Social.create_value(profile, group, %{"content" => "gone soon"})
    {:ok, _kept} = Social.create_value(profile, group, %{"content" => "kept"})
    {:ok, lv, _html} = live(member_conn, ~p"/groups/#{Social.get_root_group!().id}")
    assert has_element?(lv, "#group-unread-badge-#{group.id}", "2")

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _deleted} = Social.delete_value(profile, gone)
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
    assert has_element?(lv, "#group-unread-badge-#{group.id}", "1")
  end

  test "a reaction costs a member's open chat no query, and stays the reactor's own", %{
    conn: conn,
    group: group,
    profile: profile
  } do
    {member_conn, member} = member_conn("qc-member", group, profile)
    [value] = Social.list_group_values(group)
    {:ok, member_lv, _html} = live(member_conn, ~p"/groups/#{group.id}/values")
    {:ok, owner_lv, _html} = live(conn, ~p"/groups/#{group.id}/values")
    pill = "#value-reaction-#{value.id}-#{Base.encode16("👍", case: :lower)}"

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _value} = Social.toggle_value_reaction(profile, group, value, "👍")
          render(member_lv)
        end,
        member_lv.pid
      )

    assert count == 0
    assert has_element?(member_lv, ~s(#{pill}[aria-pressed="false"]), "1")
    assert has_element?(owner_lv, ~s(#{pill}[aria-pressed="true"]), "1")

    # The member's own reaction, and an edit after it, keep whose is whose.
    {:ok, _value} = Social.toggle_value_reaction(member, group, value, "👍")
    assert has_element?(member_lv, ~s(#{pill}[aria-pressed="true"]), "2")
    {:ok, _edited} = Social.update_value(profile, value, %{"content" => "hello again"})
    assert has_element?(member_lv, ~s(#{pill}[aria-pressed="true"]), "2")
    assert has_element?(owner_lv, ~s(#{pill}[aria-pressed="true"]), "2")
  end

  test "a reaction to the group costs a viewer no query", %{profile: profile} do
    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "qc-text-group",
        "description" => "The text",
        "description_format" => :markdown,
        "is_public" => true
      })

    {member_conn, member} = member_conn("qc-member", group, profile)
    {:ok, lv, _html} = live(member_conn, ~p"/groups/#{group.id}/group_home")
    pill = "#group-reaction-#{Base.encode16("👍", case: :lower)}"

    {_html, count} =
      count_queries(
        fn ->
          {:ok, _reactions} = Social.toggle_group_reaction(profile, group, "👍")
          render(lv)
        end,
        lv.pid
      )

    assert count == 0
    assert has_element?(lv, ~s(#{pill}[aria-pressed="false"]), "1")

    {:ok, _reactions} = Social.toggle_group_reaction(member, group, "👍")
    assert has_element?(lv, ~s(#{pill}[aria-pressed="true"]), "2")
  end

  # A value written past `Social` sends no message, so it shows only if the
  # page reads its values again.
  test "renaming the group keeps the values on screen", %{
    conn: conn,
    group: group,
    profile: profile
  } do
    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

    PotokIde.Repo.insert!(%PotokIde.Social.Value{
      group_id: group.id,
      creator_id: profile.id,
      content: "qc-silent-value",
      content_format: :markdown
    })

    {:ok, _group} = Social.update_group(profile, group, %{"name" => "qc-renamed"})

    html = render(lv)
    assert html =~ "qc-renamed"
    assert html =~ "hello"
    refute html =~ "qc-silent-value"
  end

  test "a message the page does not know leaves it as it was", %{conn: conn, group: group} do
    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

    send(lv.pid, {:profile_updated, 0})
    send(lv.pid, {:something_a_newer_server_sends, group.id})

    assert render(lv) =~ "hello"
  end

  test "the access overview loads with a bounded number of queries, however many members", %{
    conn: conn,
    group: small,
    profile: profile
  } do
    # Both groups are made before any page opens: a page left open would hear
    # of the new members and load again while another is counted.
    {:ok, big} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "query-count-big",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    for group <- [small, big] do
      {:ok, _manifest} = Social.create_own_group_manifest(profile, group)
    end

    {:ok, role} = Social.create_group_role(profile, big, %{"name" => "qc-role"})
    {:ok, _role} = Social.create_group_role(profile, small, %{"name" => "qc-role"})

    for number <- 1..6 do
      {_conn, member} = member_conn("qc-access-#{number}", big, profile)

      if rem(number, 2) == 0,
        do: {:ok, _} = Social.assign_group_member_role(profile, big, member.id, role.key)
    end

    # The first view of each warms the caches the page shares with every other.
    [few, many] =
      for group <- [small, big] do
        path = ~p"/groups/#{group.id}/access"
        _ = page_queries(conn, path)
        {_dead, live} = page_queries(conn, path)
        live
      end

    assert few <= @max_access_page_queries
    assert many == few
  end

  test "the members' names cost the members tab the same, however many members", %{
    conn: conn,
    group: small,
    profile: profile
  } do
    {:ok, big} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "query-count-names",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    # A name for all the groups is decided on the page; one for picked groups
    # this one is not among needs the groups both are in.
    for {group, count} <- [{small, 2}, {big, 8}], number <- 1..count do
      {_conn, member} =
        member_conn("qcn#{if(group == small, do: "s", else: "b")}#{number}", group, profile)

      Repo.insert!(%ProfileField{
        profile_id: member.id,
        key: :first_name,
        value: "Ime#{number}",
        audience: :shared_groups
      })

      Repo.insert!(%ProfileField{
        profile_id: member.id,
        key: :last_name,
        value: "Prezime#{number}",
        audience: :groups,
        group_ids: [if(group == small, do: big.id, else: small.id)]
      })
    end

    [few, many] =
      for group <- [small, big] do
        path = ~p"/groups/#{group.id}/members"
        _ = page_queries(conn, path)
        {_dead, live} = page_queries(conn, path)
        live
      end

    assert many == few

    {:ok, lv, _html} = live(conn, ~p"/groups/#{big.id}/members")
    assert render(lv) =~ "Ime1"
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

    # New members change who holds what, which `Access` reads again once.
    {:ok, _value} = Social.create_value(profile, group, %{"content" => "warm up again"})

    {_value, many} =
      read_rows(fn -> Social.create_value(profile, group, %{"content" => "more members"}) end)

    assert many == few
  end

  defp member_conn(username, group, inviter) do
    account = account_fixture()

    {:ok, member} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, invitation} = Social.invite_profile_to_group(inviter, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    {log_in_account(build_conn(), Accounts.get_account!(account.id)), member}
  end

  defp other_profile(username) do
    {:ok, other} =
      Social.create_profile_for_account(account_fixture(), %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    other
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
