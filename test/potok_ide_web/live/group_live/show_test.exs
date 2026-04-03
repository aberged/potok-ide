defmodule PotokIdeWeb.GroupLive.ShowTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "group page" do
    test "shows parent link only for non-root groups", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "parent-link-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      refute has_element?(root_lv, "a", "Back to Parent Group")

      {:ok, child_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(
               child_lv,
               "a[href='/groups/#{root_group.id}']",
               "❮"
             )
    end

    test "shows values first with composer at the bottom and switches tabs", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "tabs-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "tabs-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "tabbed value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-value-form")
      refute has_element?(lv, "#group-tab-create-value")

      lv
      |> element("#group-tab-members")
      |> render_click()

      assert_patch(lv, ~p"/groups/#{group.id}/members")

      refute has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-panel-members")
    end

    test "loads the tab from the URL path", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "tab-path-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "tab-path-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "tab-path-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(lv, "#group-panel-members")
      refute has_element?(lv, "#group-panel-values")
    end

    test "falls back to the default tab for invalid tab paths", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "invalid-tab-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "invalid-tab-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/not-a-tab")

      assert has_element?(lv, "#group-panel-values")
    end

    test "clicking the member avatar summary switches to the members tab", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "member-summary-owner",
          profile_picture_url: "https://example.com/member-summary-owner.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "member-summary-invitee",
          profile_picture_url: "https://example.com/member-summary-invitee.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "member-summary-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-values")

      lv
      |> element("#group-members-summary")
      |> render_click()

      refute has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-panel-members")
    end

    test "shows online presence for members viewing the group", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "presence-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "presence-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      invitee_account = Accounts.get_account!(invitee_account.id)
      group = create_child_group!(owner_profile, "presence-group")

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, owner_lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(owner_lv, "#group-member-presence-#{owner_profile.id}", "Online")
      refute has_element?(owner_lv, "#group-member-presence-#{invitee_profile.id}")

      {:ok, invitee_lv, _html} =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(invitee_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(invitee_lv, "#group-member-presence-#{invitee_profile.id}", "Online")

      assert eventually(fn ->
               has_element?(owner_lv, "#group-member-presence-#{invitee_profile.id}", "Online")
             end)

      assert eventually(fn ->
               online_profile_ids = Social.list_online_profile_ids_for_group(group)

               MapSet.member?(online_profile_ids, owner_profile.id) and
                 MapSet.member?(online_profile_ids, invitee_profile.id)
             end)
    end

    test "updates value avatars with creator presence in realtime", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "value-presence-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "value-presence-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      invitee_account = Accounts.get_account!(invitee_account.id)
      group = create_child_group!(owner_profile, "value-presence-group")

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, invitee_value} =
        Social.create_value(invitee_profile, group, %{
          "content" => "invitee value",
          "content_format" => :markdown
        })

      {:ok, owner_lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}")

      refute has_element?(owner_lv, "#value-creator-presence-#{invitee_value.id}")

      {:ok, invitee_lv, _html} =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(invitee_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(invitee_lv, "#value-creator-presence-#{invitee_value.id}")

      assert eventually(fn ->
               has_element?(owner_lv, "#value-creator-presence-#{invitee_value.id}")
             end)
    end

    test "shows only sub-groups where current profile is a member", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgroup-member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "subgroup-other-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, _visible_child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "member-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _hidden_child_group} =
        Social.create_group(other_profile, root_group, %{
          "name" => "other-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      lv
      |> element("#group-tab-sub-groups")
      |> render_click()

      assert has_element?(lv, "#group-panel-sub-groups a", "member-child-group")
      refute has_element?(lv, "#group-panel-sub-groups a", "other-child-group")
    end

    test "shows the current group path in the sub-groups tab", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-path-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, parent_group} =
        Social.create_group(profile, root_group, %{
          "name" => "path-parent-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, current_group} =
        Social.create_group(profile, parent_group, %{
          "name" => "path-current-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{current_group.id}/sub_groups")

      assert has_element?(
               lv,
               "#group-path a[href='#{~p"/groups/#{root_group.id}/sub_groups"}']",
               root_group.name
             )

      assert has_element?(
               lv,
               "#group-path a[href='#{~p"/groups/#{parent_group.id}/sub_groups"}']",
               "path-parent-group"
             )

      assert has_element?(lv, "#group-path span", "path-current-group")
    end

    test "paginates sub-groups with streams", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgroup-pagination-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      Enum.each(1..13, fn idx ->
        {:ok, _group} =
          Social.create_group(profile, root_group, %{
            "name" => "paged-child-#{pad_2(idx)}",
            "description" => "",
            "description_format" => :markdown,
            "is_public" => false
          })
      end)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      assert has_element?(lv, "#group-children-load-more")
      refute has_element?(lv, "#group-children-list", "paged-child-13")

      lv
      |> element("#group-children-load-more")
      |> render_click()

      assert has_element?(lv, "#group-children-list", "paged-child-13")
      refute has_element?(lv, "#group-children-load-more")
    end

    test "renders group pictures in header and sub-group list", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-picture-member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "pictured-child-group",
          "group_picture_url" => "https://example.com/group-avatar.png",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      root_lv
      |> element("#group-tab-sub-groups")
      |> render_click()

      assert has_element?(
               root_lv,
               "#group-panel-sub-groups img[src='https://example.com/group-avatar.png']"
             )

      {:ok, child_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(
               child_lv,
               "img[src='https://example.com/group-avatar.png'][alt='pictured-child-group']"
             )
    end

    test "renders values in chronological order with newest at the bottom", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "chronology-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "chronology-group")

      {:ok, _older_value} =
        Social.create_value(profile, group, %{
          "content" => "older value",
          "content_format" => :markdown
        })

      {:ok, _newer_value} =
        Social.create_value(profile, group, %{
          "content" => "newer value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      html = render(lv)

      assert elem(:binary.match(html, "older value"), 0) <
               elem(:binary.match(html, "newer value"), 0)

      assert has_element?(lv, "#group-value-form")
    end

    test "paginates values with streams from the latest page", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "value-pagination-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "value-pagination-group")

      Enum.each(1..21, fn idx ->
        {:ok, _value} =
          Social.create_value(profile, group, %{
            "content" => "paged value #{pad_2(idx)}",
            "content_format" => :markdown
          })
      end)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-values-load-more")
      refute has_element?(lv, "#group-values-list", "paged value 01")
      assert has_element?(lv, "#group-values-list", "paged value 02")
      assert has_element?(lv, "#group-values-list", "paged value 21")

      lv
      |> element("#group-values-load-more")
      |> render_click()

      assert has_element?(lv, "#group-values-list", "paged value 01")
      refute has_element?(lv, "#group-values-load-more")
    end

    test "loads value parent options when create-group tab is opened", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "create-group-options-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "create-group-options")

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "parent option value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/create_group")

      assert has_element?(lv, "#group-panel-create-group")
      assert render(lv) =~ "create-group-options-profile: parent option value"
    end

    test "renders value content as markdown and html", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "content-format-group")

      {:ok, _markdown_value} =
        Social.create_value(profile, group, %{
          "content" => "# Heading\n\n**bold** and [link](https://example.com)",
          "content_format" => :markdown
        })

      {:ok, _html_value} =
        Social.create_value(profile, group, %{
          "content" => "<strong>html value</strong>",
          "content_format" => :html
        })

      {:ok, _lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ ~r/<h1>\s*Heading<\/h1>/
      assert html =~ "<strong>bold</strong>"
      assert html =~ "href=\"https://example.com\""
      assert html =~ ">link</a>"
      assert html =~ "<strong>html value</strong>"
    end

    test "preserves new lines in markdown values", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "newline-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "newline-group")

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "first line\nsecond line",
          "content_format" => :markdown
        })

      {:ok, _lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ ~r/first line\s*<br\/?/
      assert html =~ "second line"
    end

    test "toggles long value content between collapsed and expanded", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "toggle-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "toggle-group")

      long_content = Enum.map_join(1..7, "\n", fn line -> "line #{line}" end)

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => long_content,
          "content_format" => :markdown
        })

      {:ok, lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ "See more"

      expanded_html =
        lv
        |> element("button[phx-click=toggle_value_expansion][phx-value-id='#{value.id}']")
        |> render_click()

      assert expanded_html =~ "See less"

      collapsed_html =
        lv
        |> element("button[phx-click=toggle_value_expansion][phx-value-id='#{value.id}']")
        |> render_click()

      assert collapsed_html =~ "See more"
    end

    test "updates values when a new value is added externally", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "realtime-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "realtime-group")

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      refute render(lv) =~ "realtime value"

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "realtime value",
          "content_format" => :markdown
        })

      assert_push_event(lv, "scroll_values_to_latest", %{})
      assert render(lv) =~ "realtime value"
    end

    test "aggregates subgroup unread badges and updates them in realtime", %{conn: conn} do
      owner_account = account_fixture()
      writer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "badge-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, writer_profile} =
        Social.create_profile_for_account(writer_account, %{
          username: "badge-writer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()
      child_group = create_child_group!(owner_profile, "badge-child-group")

      {:ok, hidden_child_group} =
        Social.create_group(writer_profile, root_group, %{
          "name" => "writer-private-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, grandchild_group} =
        Social.create_group(owner_profile, child_group, %{
          "name" => "badge-grandchild-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, child_group, writer_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, writer_profile)

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, grandchild_group, writer_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, writer_profile)

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{root_group.id}")

      refute has_element?(root_lv, "#group-unread-badge-#{root_group.id}")
      refute has_element?(root_lv, "#group-unread-badge-#{child_group.id}")
      refute has_element?(root_lv, "#nav-root-group-unread-badge")

      assert {:ok, _value} =
               Social.create_value(writer_profile, root_group, %{
                 "content" => "root unread value",
                 "content_format" => :markdown
               })

      refute has_element?(root_lv, "#group-unread-badge-#{root_group.id}")
      refute has_element?(root_lv, "#group-unread-badge-#{child_group.id}")
      refute has_element?(root_lv, "#nav-root-group-unread-badge")

      assert {:ok, _value} =
               Social.create_value(writer_profile, hidden_child_group, %{
                 "content" => "hidden unread value",
                 "content_format" => :markdown
               })

      refute has_element?(root_lv, "#group-unread-badge-#{root_group.id}")
      refute has_element?(root_lv, "#group-unread-badge-#{child_group.id}")
      refute has_element?(root_lv, "#nav-root-group-unread-badge")

      assert {:ok, _value} =
               Social.create_value(writer_profile, child_group, %{
                 "content" => "first unread value",
                 "content_format" => :markdown
               })

            assert eventually(fn ->
               has_element?(root_lv, "#group-unread-badge-#{root_group.id}", "1") and
                has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "1")
              end, 80)

        assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 1})

      assert {:ok, _value} =
               Social.create_value(writer_profile, grandchild_group, %{
                 "content" => "second unread value",
                 "content_format" => :markdown
               })

            assert eventually(fn ->
               has_element?(root_lv, "#group-unread-badge-#{root_group.id}", "2") and
                has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "2")
              end, 80)

        assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 2})

      {:ok, child_lv, _html} =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(child_lv, "#group-unread-badge-#{child_group.id}", "1")
      assert_push_event(child_lv, "root_group_unread_count_updated", %{count: 1})

            assert eventually(fn ->
               has_element?(root_lv, "#group-unread-badge-#{root_group.id}", "1") and
                 has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "1")
              end, 80)

      assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 1})
    end

    test "allows the creator profile to delete a value", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delete-value-live-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "delete-value-group")

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "value to delete from liveview",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#value-#{value.id}")

      assert has_element?(
               lv,
               "#value-delete-#{value.id}[data-confirm='Are you sure you want to delete this value?']"
             )

      lv
      |> element("#value-delete-#{value.id}")
      |> render_click()

      refute has_element?(lv, "#value-#{value.id}")
      assert render(lv) =~ "No values yet. Start the conversation below."
    end

    test "allows the creator profile to edit a value", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "edit-value-live-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "edit-value-group")

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "original liveview value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#value-edit-#{value.id}")

      lv
      |> element("#value-edit-#{value.id}")
      |> render_click()

      assert has_element?(lv, "#edit-value-form-#{value.id}")

      lv
      |> form("#edit-value-form-#{value.id}", value: %{content: "edited liveview value"})
      |> render_submit()

      refute has_element?(lv, "#edit-value-form-#{value.id}")
      assert render(lv) =~ "edited liveview value"
      refute render(lv) =~ "original liveview value"
    end

    test "redirects when current profile changes to one without access", %{conn: conn} do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "outsider-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, account} = Accounts.set_current_profile(account, first_profile)
      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, private_group} =
        Social.create_group(first_profile, root_group, %{
          "name" => "private-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{private_group.id}")

      {:ok, _updated_account} = Accounts.set_current_profile(account, second_profile)

      assert_redirect(lv, ~p"/groups")
    end

    test "paginates members with streams", %{conn: conn} do
      owner_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "member-00",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "member-pagination-group")

      Enum.each(1..20, fn idx ->
        add_group_member!(owner_profile, group, "member-#{pad_2(idx)}")
      end)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(lv, "#group-members-load-more")
      assert has_element?(lv, "#group-members-list", "member-19")
      refute has_element?(lv, "#group-members-list", "member-20")

      lv
      |> element("#group-members-load-more")
      |> render_click()

      assert has_element?(lv, "#group-members-list", "member-20")
      refute has_element?(lv, "#group-members-load-more")
    end
  end

  defp create_child_group!(profile, name) do
    root_group = Social.get_root_group!()

    {:ok, group} =
      Social.create_group(profile, root_group, %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    group
  end

  defp add_group_member!(owner_profile, group, username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, profile)
    {:ok, _accepted_invitation} = Social.accept_group_invitation(invitation, profile)

    profile
  end

  defp pad_2(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> eventually(fun, attempts - 1)
      end
    end
  end
end
