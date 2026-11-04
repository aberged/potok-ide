defmodule PotokIdeWeb.GroupUnreadSubscriptionsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  @empty_badge "#nav-root-group-unread-badge[hidden]"

  setup do
    {author_account, author} = profile!("sub-author")
    {reader_account, reader} = profile!("sub-reader")

    %{
      author: author,
      author_account: author_account,
      group: group!(author, "sub-group"),
      reader: reader,
      reader_account: reader_account
    }
  end

  test "a member's page counts a value, its author's and a stranger's do not", %{
    conn: conn,
    author: author,
    author_account: author_account,
    group: group,
    reader: reader,
    reader_account: reader_account
  } do
    join!(author, group, reader)
    {stranger_account, _stranger} = profile!("sub-stranger")

    reader_page = open(conn, reader_account)
    author_page = open(conn, author_account)
    stranger_page = open(conn, stranger_account)

    post!(author, group)

    assert_push_event(reader_page, "root_group_unread_count_updated", %{count: 1})
    render(stranger_page)
    assert has_element?(stranger_page, @empty_badge)

    # The author's page counts again right after, so only this shows a value
    # the page added to its own count.
    refute_push_event(author_page, "root_group_unread_count_updated", %{count: 1})
    assert has_element?(author_page, @empty_badge)
  end

  test "a member who joins after the page opened counts the next value", %{
    conn: conn,
    author: author,
    group: group,
    reader: reader,
    reader_account: reader_account
  } do
    page = open(conn, reader_account)

    join!(author, group, reader)
    render(page)
    post!(author, group)

    assert_push_event(page, "root_group_unread_count_updated", %{count: 1})
  end

  test "a removed member no longer counts the group's values", %{
    conn: conn,
    author: author,
    group: group,
    reader: reader,
    reader_account: reader_account
  } do
    join!(author, group, reader)
    page = open(conn, reader_account)

    {:ok, _removed} = Social.remove_group_member(author, group, reader)
    render(page)
    post!(author, group)
    render(page)

    assert has_element?(page, @empty_badge)
  end

  test "the other side of a new direct chat counts its first value", %{
    conn: conn,
    author: author,
    reader: reader,
    reader_account: reader_account
  } do
    page = open(conn, reader_account)

    {:ok, direct_group} = Social.get_or_create_direct_group(author, reader)
    render(page)
    post!(author, direct_group)

    assert_push_event(page, "root_group_unread_count_updated", %{count: 1})
  end

  test "a page follows the groups of the profile it switches to", %{
    conn: conn,
    author: author,
    group: group,
    reader: reader,
    reader_account: reader_account
  } do
    join!(author, group, reader)
    other_group = group!(author, "sub-other-group")

    {:ok, other_profile} =
      Social.create_profile_for_account(
        Accounts.get_account!(reader_account.id),
        profile_attrs("sub-switched")
      )

    join!(author, other_group, other_profile)
    page = open(conn, reader_account)

    {:ok, _account} =
      reader_account.id
      |> Accounts.get_account!()
      |> Accounts.set_current_profile(other_profile)

    render(page)

    post!(author, group)
    render(page)
    assert has_element?(page, @empty_badge)

    post!(author, other_group)
    assert_push_event(page, "root_group_unread_count_updated", %{count: 1})
  end

  test "a deleted value leaves the count on every kind of page", %{
    conn: conn,
    author: author,
    group: group,
    reader: reader,
    reader_account: reader_account
  } do
    join!(author, group, reader)

    paths = [
      ~p"/profiles",
      ~p"/invitations",
      ~p"/groups/#{Social.get_root_group!().id}"
    ]

    pages = Enum.map(paths, &open(conn, reader_account, &1))

    value = post!(author, group)
    for page <- pages, do: assert_count(page, 1)

    {:ok, _deleted} = Social.delete_value(author, value)
    for page <- pages, do: assert_count(page, 0)
  end

  # `render/1` returns once the page has handled what reached it before, so a
  # page still busy with its first load cannot outlast the push's timeout.
  defp assert_count(page, count) do
    render(page)
    assert_push_event(page, "root_group_unread_count_updated", %{count: ^count})
  end

  defp open(conn, account, path \\ ~p"/profiles") do
    {:ok, page, _html} =
      conn
      |> log_in_account(Accounts.get_account!(account.id))
      |> live(path)

    page
  end

  defp profile!(username) do
    account = account_fixture()
    {:ok, profile} = Social.create_profile_for_account(account, profile_attrs(username))
    {account, profile}
  end

  defp profile_attrs(username) do
    %{
      username: username,
      profile_picture_url: nil,
      description: "",
      description_format: :markdown,
      sharing: :unique
    }
  end

  defp group!(owner, name) do
    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    group
  end

  defp join!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
  end

  defp post!(author, group) do
    {:ok, value} = Social.create_value(author, group, %{"content" => "news"})
    value
  end
end
