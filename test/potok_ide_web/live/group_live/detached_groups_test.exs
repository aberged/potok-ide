defmodule PotokIdeWeb.GroupLive.DetachedGroupsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  setup %{conn: conn} do
    {_owner_account, owner} = account_with_profile!("detached-owner")
    {account, reader} = account_with_profile!("detached-reader")

    root = Social.get_root_group!()
    parent = group!(owner, root, "detached-parent")
    group = group!(owner, parent, "detached-group")

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, reader)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, reader)

    %{conn: log_in_account(conn, account), owner: owner, root: root, parent: parent, group: group}
  end

  test "the root lists a group whose parent the viewer cannot see, and what is unread in it",
       ctx do
    for _ <- 1..3, do: post!(ctx.owner, ctx.group)

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")

    assert has_element?(lv, "#nav-root-group-unread-badge", "3")
    assert has_element?(lv, "#group-sub-groups-kind-other-unread-badge", "3")

    assert has_element?(
             lv,
             "#child-group-#{ctx.group.id} #group-unread-badge-#{ctx.group.id}",
             "3"
           )

    refute has_element?(lv, "#child-group-#{ctx.parent.id}")
  end

  test "a new value counts on an open root page", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    assert has_element?(lv, "#child-group-#{ctx.group.id}")

    post!(ctx.owner, ctx.group)
    assert_push_event(lv, "root_group_unread_count_updated", %{count: 1})

    assert has_element?(lv, "#group-sub-groups-kind-other-unread-badge", "1")
    assert has_element?(lv, "#group-unread-badge-#{ctx.group.id}", "1")
  end

  test "the folder view lists it too", ctx do
    post!(ctx.owner, ctx.group)

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    lv |> element("#group-children-view-tree") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.group.id}")
    assert has_element?(lv, "#sub-group-folder-unread-#{ctx.group.id}", "1")
    refute has_element?(lv, "#sub-group-folder-#{ctx.parent.id}")
  end

  test "the group opens, and its back link goes to the root rather than the unseen parent", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/values")

    assert has_element?(lv, "#group-back-link[href='/groups']")
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {Accounts.get_account!(account.id), profile}
  end

  defp group!(profile, parent, name) do
    {:ok, group} =
      Social.create_group(profile, parent, %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    group
  end

  defp post!(author, group) do
    {:ok, value} = Social.create_value(author, group, %{"content" => "news"})
    value
  end
end
