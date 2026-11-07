defmodule PotokIdeWeb.GroupLive.GroupCreateMenuTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group}

  setup do
    {owner_account, owner} = account_with_profile!("create-owner")
    {member_account, member} = account_with_profile!("create-member")

    root = Social.get_root_group!()
    parent = group!(owner, root, "create-parent", %{"is_public" => true})
    child = group!(owner, parent, "create-child", %{"is_public" => true})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      root: root,
      parent: parent,
      child: child
    }
  end

  defp open(ctx, account, path) do
    {:ok, lv, _html} = ctx.conn |> log_in_account(account) |> live(path)

    lv
  end

  defp sub_groups(ctx, account \\ nil, group \\ nil) do
    open(
      ctx,
      account || ctx.owner_account,
      ~p"/groups/#{(group || ctx.parent).id}/sub_groups"
    )
  end

  defp open_menu(lv) do
    lv |> element("#group-sub-groups-create-fab") |> render_click()
    lv
  end

  defp pick(lv, preset) do
    lv |> element("#group-create-preset-#{preset}") |> render_click()
    lv
  end

  # The path a preset leads to, with the group it made.
  defp create(lv, name) do
    lv
    |> form("#group-create-preset-form", group_preset: %{name: name})
    |> render_submit()

    {path, flash} = assert_redirect(lv)
    {path, flash, Repo.get_by!(Group, name: name)}
  end

  describe "opening" do
    test "the + button opens the presets, and no form yet", ctx do
      lv = ctx |> sub_groups() |> open_menu()

      assert has_element?(lv, "dialog#group-create-menu")

      for preset <- ~w(chat folder announcements feed polls page) do
        assert has_element?(lv, "#group-create-preset-#{preset}")
      end

      refute has_element?(lv, "#group-create-preset-form")
      refute has_element?(lv, "#group-panel-create-group")
    end

    test "so does the menu of the open group", ctx do
      lv = sub_groups(ctx)

      lv |> element("#group-tab-create-sub-group") |> render_click()

      assert has_element?(lv, "dialog#group-create-menu", ctx.parent.name)
    end

    test "and the menu of a row, for that row's group", ctx do
      lv = sub_groups(ctx)

      lv |> element("#group-row-menu-button-#{ctx.child.id}") |> render_click()
      lv |> element("#group-row-tab-create-sub-group") |> render_click()

      refute has_element?(lv, "#group-row-menu")
      assert has_element?(lv, "dialog#group-create-menu", ctx.child.name)

      {_path, _flash, group} = lv |> pick("chat") |> create("U redu")

      assert group.parent_id == ctx.child.id
    end

    test "the full form stays a link away", ctx do
      lv = ctx |> sub_groups() |> open_menu()

      assert has_element?(
               lv,
               ~s|#group-create-custom[href="/groups/#{ctx.parent.id}/create_group"]|
             )
    end

    test "it closes", ctx do
      lv = ctx |> sub_groups() |> open_menu()

      lv |> element("#group-create-menu-backdrop") |> render_click()
      refute has_element?(lv, "#group-create-menu")

      open_menu(lv)
      lv |> element("#group-create-menu-close") |> render_click()
      refute has_element?(lv, "#group-create-menu")
    end
  end

  describe "who it opens for" do
    test "not for a public group the viewer is outside of", ctx do
      lv = sub_groups(ctx, ctx.member_account)

      refute has_element?(lv, "#group-sub-groups-create-fab")

      render_click(lv, "group_create_menu_open", %{"id" => ctx.parent.id})
      refute has_element?(lv, "#group-create-menu")
    end

    test "not for a group the viewer cannot see, nor a bad id", ctx do
      hidden = group!(ctx.owner, ctx.parent, "create-hidden", %{"is_public" => false})
      lv = open(ctx, ctx.member_account, ~p"/groups/#{ctx.parent.id}/group_home")

      for id <- [hidden.id, "not-an-id", -1] do
        render_click(lv, "group_create_menu_open", %{"id" => id})
        refute has_element?(lv, "#group-create-menu")
      end
    end

    test "a right lost after opening still counts when it is saved", ctx do
      add_member!(ctx.owner, ctx.parent, ctx.member)

      lv = sub_groups(ctx, ctx.member_account) |> open_menu() |> pick("chat")

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.parent)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.parent,
          "everyone",
          :create_subgroups,
          :neutral
        )

      lv
      |> form("#group-create-preset-form", group_preset: %{name: "Prekasno"})
      |> render_submit()

      assert has_element?(lv, "#group-create-menu-error")
      refute Repo.get_by(Group, name: "Prekasno")
    end
  end

  describe "the second step" do
    test "says what the preset makes, and goes back", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("feed")

      assert has_element?(lv, "#group-create-summary", "FeedCreator")
      assert has_element?(lv, "#group-create-preset-form")

      lv |> element("#group-create-menu-back") |> render_click()

      assert has_element?(lv, "#group-create-presets")
      refute has_element?(lv, "#group-create-preset-form")
    end

    test "a name is needed, and the error shows in the dialog", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("chat")

      lv
      |> form("#group-create-preset-form", group_preset: %{name: ""})
      |> render_submit()

      assert has_element?(lv, "#group-create-preset-form .text-error")
      assert has_element?(lv, "#group-create-menu")
    end

    test "only a feed starts public", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("feed")
      assert has_element?(lv, "#group_preset_is_public[checked]")

      lv |> element("#group-create-menu-back") |> render_click()
      pick(lv, "chat")
      refute has_element?(lv, "#group_preset_is_public[checked]")
    end

    test "there is no inheriting at the top", ctx do
      lv = ctx |> sub_groups(nil, ctx.root) |> open_menu() |> pick("chat")

      refute has_element?(lv, "#group-create-preset-inherits")

      {path, _flash, group} = create(lv, "Na vrhu")

      assert path == ~p"/groups/#{group.id}"
      refute group.inherits_members
    end

    test "a switch is the viewer's to change", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("chat")

      lv
      |> form("#group-create-preset-form",
        group_preset: %{name: "Otvoren", is_public: true, inherits_members: false}
      )
      |> render_submit()

      assert_redirect(lv)

      group = Repo.get_by!(Group, name: "Otvoren")

      assert group.is_public
      refute group.inherits_members
    end
  end

  describe "where it leads" do
    test "chat, folder and announcements lead to the new group", ctx do
      for preset <- ~w(chat folder announcements) do
        lv = ctx |> sub_groups() |> open_menu() |> pick(preset)

        {path, flash, group} = create(lv, "Grupa #{preset}")

        assert path == ~p"/groups/#{group.id}"
        assert flash["info"]
      end
    end

    test "in announcements a member is not asked to start the conversation", ctx do
      add_member!(ctx.owner, ctx.parent, ctx.member)

      lv = ctx |> sub_groups() |> open_menu() |> pick("announcements")
      {_path, _flash, group} = create(lv, "Oglasna tabla")

      board = open(ctx, ctx.member_account, ~p"/groups/#{group.id}/values")

      assert has_element?(board, "#group-value-composer-disabled")
      assert has_element?(board, "#group-values-empty")
      refute has_element?(board, "#group-values-empty", "below")
    end

    test "a page leads to writing its text", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("page")

      {path, _flash, group} = create(lv, "Stranica")

      assert path == ~p"/groups/#{group.id}/edit_group?section=description"

      page = open(ctx, ctx.owner_account, path)

      assert has_element?(page, "#group-edit-description")
      refute has_element?(page, "#group-edit-description.hidden")
      assert has_element?(page, "#group-edit-basics.hidden")
    end

    test "a feed leads to where its posts are written", ctx do
      lv = ctx |> sub_groups() |> open_menu() |> pick("feed")

      {path, _flash, group} = create(lv, "Vesti")
      feed = Repo.get_by!(Group, name: ".feed", parent_id: group.id)

      assert path == ~p"/groups/#{feed.id}"
      refute Access.can?(ctx.member, feed, :create_subgroups)
    end
  end

  test "another section of the edit tab opens by its link only", ctx do
    lv = open(ctx, ctx.owner_account, ~p"/groups/#{ctx.child.id}/edit_group?section=nothing")

    refute has_element?(lv, "#group-edit-basics.hidden")
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
