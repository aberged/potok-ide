defmodule PotokIdeWeb.GroupLive.SubGroupsKindFilterTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  # Fixed names keep the folders in one order (see root_public_groups_test.exs).
  setup %{conn: conn} do
    {account, profile} = account_with_profile!("kind-owner")
    group = group!(profile, Social.get_root_group!(), "kind-group")
    chat = preset!(profile, group, "chat", "kind-a-chat")
    folder = preset!(profile, group, "folder", "kind-b-folder")
    nested_chat = preset!(profile, folder, "chat", "kind-nested-chat")
    plain = group!(profile, group, "kind-c-plain")

    %{
      conn: log_in_account(conn, account),
      group: group,
      chat: chat,
      folder: folder,
      nested_chat: nested_chat,
      plain: plain
    }
  end

  test "a kind narrows the list, and all kinds bring it back", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    assert has_element?(lv, "#group-children-preset-toggle")
    assert has_element?(lv, "#group-children-preset-menu")
    assert has_element?(lv, "#group-children-preset-option-all[aria-checked=true]")
    refute has_element?(lv, "#group-children-filters-active")

    lv |> element("#group-children-preset-option-chat") |> render_click()

    assert has_element?(lv, "#group-children-list #child-group-#{ctx.chat.id}")
    refute has_element?(lv, "#child-group-#{ctx.folder.id}")
    refute has_element?(lv, "#child-group-#{ctx.plain.id}")
    # The list shows the folder's level only.
    refute has_element?(lv, "#child-group-#{ctx.nested_chat.id}")
    assert has_element?(lv, "#group-children-preset-option-chat[aria-checked=true]")
    assert has_element?(lv, "#group-children-preset-option-all[aria-checked=false]")
    # The folded bar tells that the list is filtered.
    assert has_element?(lv, "#group-children-filters-active")

    lv |> element("#group-children-preset-option-none") |> render_click()

    assert has_element?(lv, "#child-group-#{ctx.plain.id}")
    refute has_element?(lv, "#child-group-#{ctx.chat.id}")
    refute has_element?(lv, "#child-group-#{ctx.folder.id}")

    lv |> element("#group-children-preset-option-all") |> render_click()

    for group <- [ctx.chat, ctx.folder, ctx.plain] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end

    refute has_element?(lv, "#group-children-filters-active")
  end

  test "a kind with no groups says so and offers every kind again", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    refute has_element?(lv, "#group-children-clear-filters")

    lv |> element("#group-children-preset-option-polls") |> render_click()

    assert has_element?(lv, "#group-children-empty")
    refute has_element?(lv, "#child-group-#{ctx.chat.id}")

    lv |> element("#group-children-clear-filters") |> render_click()

    refute has_element?(lv, "#group-children-empty")
    refute has_element?(lv, "#group-children-clear-filters")
    assert has_element?(lv, "#child-group-#{ctx.chat.id}")
    assert has_element?(lv, "#group-children-preset-option-all[aria-checked=true]")
  end

  test "an unknown kind leaves the list as it is", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    render_hook(lv, "filter_children_preset", %{"preset" => "bogus"})

    for group <- [ctx.chat, ctx.folder, ctx.plain] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end
  end

  test "folders show the way to the groups of a kind", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

    assert has_element?(lv, "#sub-group-folder-#{ctx.plain.id}")

    lv |> element("#group-children-preset-option-chat") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.chat.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.folder.id}[aria-expanded=true]")

    assert has_element?(
             lv,
             "#sub-group-folder-#{ctx.folder.id} #sub-group-folder-#{ctx.nested_chat.id}"
           )

    refute has_element?(lv, "#sub-group-folder-#{ctx.plain.id}")

    lv |> element("#group-children-preset-option-all") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.plain.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.folder.id}[aria-expanded=false]")
  end

  test "the root's direct conversations have no kind filter", %{conn: conn} do
    root_group = Social.get_root_group!()

    {:ok, lv, _html} =
      live(conn, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=direct")

    refute has_element?(lv, "#group-children-preset-toggle")
    refute has_element?(lv, "#group-children-preset-menu")

    lv |> element("#group-sub-groups-kind-other") |> render_click()
    assert_patch(lv, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=other")

    assert has_element?(lv, "#group-children-preset-toggle")
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

  defp preset!(profile, parent, preset, name) do
    {:ok, %{group: group}} =
      Social.create_group_from_preset(profile, parent, preset, %{
        "name" => name,
        "is_public" => "false",
        "inherits_members" => "true"
      })

    group
  end
end
