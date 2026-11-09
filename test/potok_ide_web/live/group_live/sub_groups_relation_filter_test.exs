defmodule PotokIdeWeb.GroupLive.SubGroupsRelationFilterTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  # Fixed names keep the folders in one order (see root_public_groups_test.exs).
  setup %{conn: conn} do
    {account, me} = account_with_profile!("rel-me")
    {_account, other} = account_with_profile!("rel-other")
    group = group!(me, Social.get_root_group!(), "rel-group")
    add_member!(me, group, other)

    mine = group!(me, group, "rel-a-mine")

    # Theirs, and I am in it.
    theirs = group!(other, group, "rel-b-theirs")
    add_member!(other, theirs, me)
    deep_mine = group!(me, theirs, "rel-deep-mine")

    # Theirs and public; I am not in it.
    public = group!(other, group, "rel-c-public", %{"is_public" => true})

    %{
      conn: log_in_account(conn, account),
      group: group,
      mine: mine,
      theirs: theirs,
      deep_mine: deep_mine,
      public: public
    }
  end

  test "member and creator narrow the list, all groups bring it back", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    assert has_element?(lv, "#group-children-relation-toggle")
    assert has_element?(lv, "#group-children-relation-option-all[aria-checked=true]")

    for group <- [ctx.mine, ctx.theirs, ctx.public] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end

    lv |> element("#group-children-relation-option-member") |> render_click()

    assert has_element?(lv, "#child-group-#{ctx.mine.id}")
    assert has_element?(lv, "#child-group-#{ctx.theirs.id}")
    refute has_element?(lv, "#child-group-#{ctx.public.id}")
    assert has_element?(lv, "#group-children-relation-option-member[aria-checked=true]")
    assert has_element?(lv, "#group-children-filters-active")

    lv |> element("#group-children-relation-option-creator") |> render_click()

    assert has_element?(lv, "#child-group-#{ctx.mine.id}")
    refute has_element?(lv, "#child-group-#{ctx.theirs.id}")
    refute has_element?(lv, "#child-group-#{ctx.public.id}")

    lv |> element("#group-children-relation-option-all") |> render_click()

    for group <- [ctx.mine, ctx.theirs, ctx.public] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end

    refute has_element?(lv, "#group-children-filters-active")
  end

  test "clearing the filters takes off the kind and the membership together", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    lv |> element("#group-children-relation-option-creator") |> render_click()
    lv |> element("#group-children-preset-option-polls") |> render_click()

    assert has_element?(lv, "#group-children-empty")
    refute has_element?(lv, "#child-group-#{ctx.mine.id}")

    lv |> element("#group-children-clear-filters") |> render_click()

    refute has_element?(lv, "#group-children-clear-filters")
    assert has_element?(lv, "#group-children-relation-option-all[aria-checked=true]")
    assert has_element?(lv, "#group-children-preset-option-all[aria-checked=true]")

    for group <- [ctx.mine, ctx.theirs, ctx.public] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end
  end

  test "an unknown relation leaves the list as it is", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups")

    render_hook(lv, "filter_children_relation", %{"relation" => "admin"})

    for group <- [ctx.mine, ctx.theirs, ctx.public] do
      assert has_element?(lv, "#child-group-#{group.id}")
    end
  end

  test "folders show the way to my own groups", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

    lv |> element("#group-children-relation-option-creator") |> render_click()

    assert has_element?(lv, "#sub-group-folder-#{ctx.mine.id}")
    assert has_element?(lv, "#sub-group-folder-#{ctx.theirs.id}[aria-expanded=true]")

    assert has_element?(
             lv,
             "#sub-group-folder-#{ctx.theirs.id} #sub-group-folder-#{ctx.deep_mine.id}"
           )

    refute has_element?(lv, "#sub-group-folder-#{ctx.public.id}")
  end

  test "the root's direct conversations have no membership filter", %{conn: conn} do
    root_group = Social.get_root_group!()

    {:ok, lv, _html} =
      live(conn, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=direct")

    refute has_element?(lv, "#group-children-relation-toggle")
    refute has_element?(lv, "#group-children-relation-menu")
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

  defp group!(profile, parent, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        profile,
        parent,
        Map.merge(
          %{
            "name" => name,
            "description" => "",
            "description_format" => :markdown,
            "is_public" => false
          },
          attrs
        )
      )

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
