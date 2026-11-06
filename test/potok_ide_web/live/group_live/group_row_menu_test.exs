defmodule PotokIdeWeb.GroupLive.GroupRowMenuTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
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

    assert row != []
    assert row == own -- ["actions-menu"]
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
