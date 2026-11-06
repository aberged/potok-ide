defmodule PotokIdeWeb.GroupLive.GroupRowMenuTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.EventsFixtures
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("menu-owner")
    {other_account, other} = account_with_profile!("menu-other")

    parent = group!(owner, Social.get_root_group!(), "menu-parent", %{"is_public" => true})
    child = group!(owner, parent, "menu-child", %{"is_public" => true})

    %{
      owner_account: owner_account,
      owner: owner,
      other_account: other_account,
      other: other,
      parent: parent,
      child: child
    }
  end

  defp open(ctx, account, path) do
    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(account.id))
      |> live(path)

    lv
  end

  defp sub_groups(ctx, account \\ nil, group \\ nil) do
    open(
      ctx,
      account || ctx.owner_account,
      ~p"/groups/#{(group || ctx.parent).id}/sub_groups"
    )
  end

  defp open_menu(lv, group) do
    lv |> element("#group-row-menu-button-#{group.id}") |> render_click()
    lv
  end

  # The options on screen, under names both menus share.
  defp menu_ids(lv, selector, prefix) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{selector} a[id], #{selector} button[id]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  defp attributes(lv, selector, name) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute(name) |> hd()))
  end

  # The bar of the open group against the top of a row's menu. What follows
  # the sections in the menu is the group's own page.
  defp assert_sections_match_bar(ctx, account, group, lv) do
    bar =
      ctx
      |> open(account, ~p"/groups/#{group.id}/group_home")
      |> attributes("#group-tabs button", "phx-value-tab")

    links = attributes(lv, "#group-row-menu a[id]", "href")

    assert Enum.map(links, &(&1 |> URI.parse() |> Map.fetch!(:path) |> Path.basename()))
           |> Enum.take(length(bar) + 1) == bar ++ ["group_home"]

    bar
  end

  test "every row has the button, after its tags button", ctx do
    lv = sub_groups(ctx)

    assert has_element?(
             lv,
             "#child-group-tags-#{ctx.child.id} + #group-row-menu-button-#{ctx.child.id}"
           )

    refute has_element?(lv, "#group-row-menu")
  end

  test "so does every row of the folders", ctx do
    grandchild = group!(ctx.owner, ctx.child, "menu-grandchild", %{"is_public" => true})
    lv = open(ctx, ctx.owner_account, ~p"/groups/#{ctx.parent.id}/sub_groups?view=tree")

    assert has_element?(lv, "#group-row-menu-button-#{ctx.child.id}")

    lv |> element("#sub-group-folder-toggle-#{ctx.child.id}") |> render_click()

    assert has_element?(lv, "#group-row-menu-button-#{grandchild.id}")

    open_menu(lv, grandchild)

    assert has_element?(
             lv,
             ~s|#group-row-tab-edit-group[href="/groups/#{grandchild.id}/edit_group"]|
           )

    assert has_element?(lv, ~s|#group-row-tab-files[href="/groups/#{grandchild.id}/files"]|)
  end

  test "the menu leads to the pages of that group", ctx do
    lv = ctx |> sub_groups() |> open_menu(ctx.child)

    assert has_element?(lv, "dialog#group-row-menu")

    assert has_element?(
             lv,
             ~s|#group-row-tab-group-home[href="/groups/#{ctx.child.id}/group_home"]|
           )

    assert has_element?(lv, ~s|#group-row-tab-roles[href="/groups/#{ctx.child.id}/roles"]|)

    assert has_element?(
             lv,
             ~s|#group-row-tab-edit-group[href="/groups/#{ctx.child.id}/edit_group"]|
           )

    assert has_element?(lv, "#group-row-share-button[data-share-link$='/groups/#{ctx.child.id}']")
  end

  test "it offers what the open group's own menu offers", ctx do
    row = menu_ids(sub_groups(ctx) |> open_menu(ctx.child), "#group-row-menu", "group-row-")

    own_page = open(ctx, ctx.owner_account, ~p"/groups/#{ctx.child.id}/group_home")
    own = menu_ids(own_page, "#group-actions-menu-container", "group-")

    sections = ~w(tab-values tab-files tab-calendar tab-subgroups tab-members)

    assert own != ["actions-menu"]
    assert row -- sections == own -- ["actions-menu"]
  end

  test "it leads to the sections of the group's bar", ctx do
    lv = ctx |> sub_groups() |> open_menu(ctx.child)

    assert assert_sections_match_bar(ctx, ctx.owner_account, ctx.child, lv) ==
             ~w(values files calendar sub_groups members)

    assert has_element?(lv, ~s|#group-row-tab-values[href="/groups/#{ctx.child.id}/values"]|)
    assert has_element?(lv, ~s|#group-row-tab-files[href="/groups/#{ctx.child.id}/files"]|)
    assert has_element?(lv, ~s|#group-row-tab-calendar[href="/groups/#{ctx.child.id}/calendar"]|)

    assert has_element?(
             lv,
             ~s|#group-row-tab-subgroups[href="/groups/#{ctx.child.id}/sub_groups"]|
           )

    assert has_element?(lv, ~s|#group-row-tab-members[href="/groups/#{ctx.child.id}/members"]|)
  end

  test "the rights are those of that group, not of the list it stands in", ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.parent, ctx.other)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.other)

    mine = group!(ctx.other, ctx.parent, "menu-mine", %{"is_public" => true})

    lv = sub_groups(ctx, ctx.other_account)

    open_menu(lv, ctx.child)
    refute has_element?(lv, "#group-row-tab-edit-group")
    refute has_element?(lv, "#group-row-tab-roles")
    lv |> element("#group-row-menu-backdrop") |> render_click()

    open_menu(lv, mine)
    assert has_element?(lv, "#group-row-tab-edit-group")
    assert has_element?(lv, "#group-row-tab-roles")
  end

  test "someone outside a public group gets what is open to them", ctx do
    lv = sub_groups(ctx, ctx.other_account) |> open_menu(ctx.child)

    assert has_element?(lv, "#group-row-tab-group-home")
    assert has_element?(lv, "#group-row-tags-button")
    refute has_element?(lv, "#group-row-tab-roles")
    refute has_element?(lv, "#group-row-tab-create-sub-group")
    refute has_element?(lv, "#group-row-tab-invite-profile")
    refute has_element?(lv, "#group-row-tab-edit-group")

    assert assert_sections_match_bar(ctx, ctx.other_account, ctx.child, lv) == ["sub_groups"]
    refute has_element?(lv, "#group-row-tab-calendar")
  end

  test "someone outside it gets the calendar once there are public events", ctx do
    EventsFixtures.create_event!(
      ctx.owner,
      ctx.child,
      EventsFixtures.event_attrs(EventsFixtures.today(), %{"is_public" => "true"})
    )

    lv = sub_groups(ctx, ctx.other_account) |> open_menu(ctx.child)

    assert assert_sections_match_bar(ctx, ctx.other_account, ctx.child, lv) ==
             ~w(calendar sub_groups)
  end

  test "a direct conversation offers no roles and no invitations", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.other)

    lv =
      open(
        ctx,
        ctx.owner_account,
        ~p"/groups/#{Social.get_root_group!().id}/sub_groups?sub_groups_kind=direct"
      )

    assert has_element?(lv, "#group-row-menu-button-#{direct.id}")

    open_menu(lv, direct)

    assert has_element?(lv, "#group-row-tab-group-home")
    assert has_element?(lv, "#group-row-tab-values")
    refute has_element?(lv, "#group-row-tab-subgroups")
    refute has_element?(lv, "#group-row-tab-roles")
    refute has_element?(lv, "#group-row-tab-invite-profile")
    refute has_element?(lv, "#group-row-share-button")
  end

  test "a group the viewer cannot see opens nothing", ctx do
    hidden = group!(ctx.owner, ctx.parent, "menu-hidden", %{"is_public" => false})
    lv = sub_groups(ctx, ctx.other_account)

    render_click(lv, "group_row_menu_open", %{"id" => hidden.id})
    refute has_element?(lv, "#group-row-menu")

    render_click(lv, "group_row_menu_open", %{"id" => "not-an-id"})
    refute has_element?(lv, "#group-row-menu")

    render_click(lv, "group_row_menu_open", %{"id" => -1})
    refute has_element?(lv, "#group-row-menu")
  end

  test "it closes", ctx do
    lv = ctx |> sub_groups() |> open_menu(ctx.child)

    lv |> element("#group-row-menu-backdrop") |> render_click()

    refute has_element?(lv, "#group-row-menu")
  end

  test "its tags close it and open the editor of that group", ctx do
    lv = ctx |> sub_groups() |> open_menu(ctx.child)

    lv |> element("#group-row-tags-button") |> render_click()

    refute has_element?(lv, "#group-row-menu")
    assert has_element?(lv, "#tag-editor-item", ctx.child.name)
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

    {account, profile}
  end

  defp group!(owner, parent, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end
end
