defmodule PotokIdeWeb.GroupLive.GroupShortcutsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  setup %{conn: conn} do
    {_owner_account, owner} = account_with_profile!("sc-lv-owner")
    {account, ana} = account_with_profile!("sc-lv-ana")

    root = Social.get_root_group!()
    town = group!(owner, root, "Opstina", true)
    community = group!(owner, town, "Mesna zajednica", true)
    council = group!(owner, community, "Savet saveta", false)
    add_member!(owner, council, ana)

    %{
      conn: log_in_account(conn, account),
      owner: owner,
      ana: ana,
      root: root,
      town: town,
      community: community,
      council: council
    }
  end

  test "a shortcut placed from the create menu shows at the root and opens the group", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    refute has_element?(lv, "#child-group-#{ctx.council.id}")

    lv |> element("#group-sub-groups-create-fab") |> render_click()
    lv |> element("#group-create-shortcut") |> render_click()

    # Without a name, the step offers the viewer's own groups.
    assert has_element?(lv, "#group-create-shortcut-result-#{ctx.council.id}", "Savet saveta")
    assert has_element?(lv, "#group-create-shortcut-result-#{ctx.council.id}", "Mesna zajednica")

    lv
    |> form("#group-create-shortcut-form", shortcut: %{search: "nema takve"})
    |> render_change()

    assert has_element?(lv, "#group-create-shortcut-empty")

    lv
    |> form("#group-create-shortcut-form", shortcut: %{search: "savet"})
    |> render_change()

    lv |> element("#group-create-shortcut-result-#{ctx.council.id}") |> render_click()

    refute has_element?(lv, "#group-create-menu")

    assert has_element?(
             lv,
             "#child-group-#{ctx.council.id} #group-shortcut-mark-#{ctx.council.id}"
           )

    assert has_element?(
             lv,
             "#child-group-#{ctx.council.id} a[href='/groups/#{ctx.council.id}']",
             "Savet saveta"
           )
  end

  test "the menu says when the group already has that shortcut", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    lv |> element("#group-sub-groups-create-fab") |> render_click()
    lv |> element("#group-create-shortcut") |> render_click()

    {:ok, _shortcut} = Social.create_group_shortcut(ctx.owner, ctx.root, ctx.council.id)
    lv |> element("#group-create-shortcut-result-#{ctx.council.id}") |> render_click()

    assert has_element?(lv, "#group-create-menu-error")
  end

  test "a shortcut's row counts the unread values of its group as they come", ctx do
    {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    refute has_element?(lv, "#group-unread-badge-#{ctx.council.id}")

    post!(ctx.owner, ctx.council)
    render(lv)
    assert_push_event(lv, "root_group_unread_count_updated", %{count: 1})

    assert has_element?(
             lv,
             "#child-group-#{ctx.council.id} #group-unread-badge-#{ctx.council.id}",
             "1"
           )

    # The value counts once: the root's own count and the kinds' badge hold it
    # through the council's own place, not again through the shortcut.
    assert has_element?(lv, "#nav-root-group-unread-badge", "1")
    assert has_element?(lv, "#group-sub-groups-kind-other-unread-badge", "1")
  end

  test "a value brings a shortcut's row up from past the loaded part of the list", ctx do
    {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
    for n <- 1..21, do: group!(ctx.owner, ctx.root, "Javna #{n}", true)

    # Older than all of them, so the first page leaves it out. The town on the
    # way to it is the newest, so the page has it: only the shortcut is missing.
    PotokIde.Repo.update_all(
      from(g in PotokIde.Social.Group, where: g.id == ^ctx.council.id),
      set: [last_value_at: nil, inserted_at: ~U[2020-01-01 00:00:00Z]]
    )

    PotokIde.Repo.update_all(
      from(g in PotokIde.Social.Group, where: g.id == ^ctx.town.id),
      set: [last_value_at: DateTime.utc_now(:second)]
    )

    # The root shows the public groups the viewer is not in only when asked.
    {:ok, lv, _html} =
      ctx.conn
      |> put_connect_params(%{"show_public_groups" => true})
      |> live(~p"/groups/#{ctx.root.id}")

    refute has_element?(lv, "#child-group-#{ctx.council.id}")
    assert has_element?(lv, "#group-children-load-more")

    post!(ctx.owner, ctx.council)
    render(lv)
    assert_push_event(lv, "root_group_unread_count_updated", %{count: 1})

    assert has_element?(
             lv,
             "#child-group-#{ctx.council.id} #group-unread-badge-#{ctx.council.id}",
             "1"
           )
  end

  test "a member of the group sees a shortcut someone else placed, without a reload", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    refute has_element?(lv, "#child-group-#{ctx.council.id}")

    {:ok, _shortcut} = Social.create_group_shortcut(ctx.owner, ctx.root, ctx.council.id)

    assert has_element?(
             lv,
             "#child-group-#{ctx.council.id} #group-shortcut-mark-#{ctx.council.id}"
           )
  end

  test "its author takes it away from the row's menu, and the group stays", ctx do
    {:ok, shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")

    lv |> element("#group-row-menu-button-shortcut-#{shortcut.id}") |> render_click()
    lv |> element("#group-row-menu-remove-shortcut") |> render_click()

    refute has_element?(lv, "#child-group-#{ctx.council.id}")
    assert Social.get_visible_group(ctx.ana, ctx.council.id)
  end

  test "someone else's shortcut has no way to take it away", ctx do
    place = group!(ctx.owner, ctx.root, "Mesto", true)
    {:ok, shortcut} = Social.create_group_shortcut(ctx.owner, place, ctx.community.id)

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{place.id}/sub_groups")

    lv |> element("#group-row-menu-button-shortcut-#{shortcut.id}") |> render_click()
    assert has_element?(lv, "#group-row-menu")
    refute has_element?(lv, "#group-row-menu-remove-shortcut")
  end

  test "the folder view shows a shortcut as a leaf that opens its group", ctx do
    {:ok, shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
    post!(ctx.owner, ctx.council)

    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.root.id}")
    lv |> element("#group-children-view-tree") |> render_click()

    leaf = "#sub-group-folder-shortcut-#{shortcut.id}"
    assert has_element?(lv, "#{leaf} a[href='/groups/#{ctx.council.id}']", "Savet saveta")
    assert has_element?(lv, "#{leaf} #sub-group-shortcut-mark-#{shortcut.id}")
    assert has_element?(lv, "#sub-group-folder-unread-shortcut-#{shortcut.id}", "1")
    refute has_element?(lv, "#{leaf} button[phx-click='toggle_sub_group_folder']")
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

  defp group!(profile, parent, name, public?) do
    {:ok, group} =
      Social.create_group(profile, parent, %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => public?
      })

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end

  defp post!(author, group) do
    {:ok, value} = Social.create_value(author, group, %{"content" => "news"})
    value
  end
end
