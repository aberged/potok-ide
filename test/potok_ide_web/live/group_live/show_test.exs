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
          username: "parent-link",
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
               "a[href='/groups/#{root_group.id}/sub_groups']",
               "❮"
             )

      # The hook goes back in history; the href is where it goes without one.
      assert has_element?(
               child_lv,
               "#group-back-link[phx-hook][href='/groups/#{root_group.id}/sub_groups']"
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
        |> live(~p"/groups/#{group.id}/values")

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

    test "falls back to the configured home page for invalid tab paths", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "invalid-tab",
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
          "home_page" => :description,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/not-a-tab")

      assert has_element?(lv, "#group-description-empty")
    end

    test "opens the values tab by default when home_page is chat", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "homechat-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "home-page-chat-group",
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-values")
      refute has_element?(lv, "#group-panel-description")
    end

    test "opens the sub-groups tab by default when home_page is subgroups", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "homesub-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "home-page-subgroups-group",
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :subgroups,
          "is_public" => false
        })

      {:ok, _child_group} =
        Social.create_group(profile, group, %{
          "name" => "nested-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-sub-groups")
      refute has_element?(lv, "#group-panel-description")
    end

    test "opens direct groups on the values tab regardless of home_page", %{conn: conn} do
      current_account = account_fixture()
      other_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "dirhome-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "dirhome-oth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      current_account = Accounts.get_account!(current_account.id)

      {:ok, direct_group} =
        Social.get_or_create_direct_group(current_profile, other_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(current_account)
        |> live(~p"/groups/#{direct_group.id}")

      assert has_element?(lv, "#group-panel-values")
      refute has_element?(lv, "#group-panel-description")
    end

    test "clicking the member avatar summary switches to the members tab", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "memsum-owner",
          profile_picture_url: "https://example.com/member-summary-owner.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "memsum-invitee",
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
        |> live(~p"/groups/#{group.id}/values")

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

      # Badges are always rendered; `#group-presence-style` reveals the online ones.
      assert has_element?(
               owner_lv,
               "#group-member-presence-#{owner_profile.id}.presence-p#{owner_profile.id}",
               "Online"
             )

      assert shown_online?(owner_lv, owner_profile.id)
      refute shown_online?(owner_lv, invitee_profile.id)

      {:ok, invitee_lv, _html} =
        build_conn()
        |> log_in_account(invitee_account)
        |> live(~p"/groups/#{group.id}/members")

      assert shown_online?(invitee_lv, invitee_profile.id)

      assert eventually(fn -> shown_online?(owner_lv, invitee_profile.id) end)

      assert eventually(fn ->
               online_profile_ids = Social.list_online_profile_ids_for_group(group)

               MapSet.member?(online_profile_ids, owner_profile.id) and
                 MapSet.member?(online_profile_ids, invitee_profile.id)
             end)
    end

    test "renders only the header first and loads the panel once connected", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "skeleton-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = create_child_group!(profile, "skeleton-group")
      conn = log_in_account(conn, Accounts.get_account!(account.id))

      dead =
        conn
        |> get(~p"/groups/#{group.id}/values")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert Enum.count(LazyHTML.query(dead, "#group-panel-loading")) == 1
      assert Enum.empty?(LazyHTML.query(dead, "#group-panel-values"))

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      refute has_element?(lv, "#group-panel-loading")
      assert has_element?(lv, "#group-panel-values")
    end

    test "does not track presence on the root page, which shows no online dots", %{conn: conn} do
      account = account_fixture()

      {:ok, _profile} =
        Social.create_profile_for_account(account, %{
          username: "presence-root",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(account.id))
        |> live(~p"/groups/#{root_group.id}")

      assert has_element?(lv, "#group-presence-style")
      assert Social.list_online_profile_ids_for_group(root_group) == MapSet.new()
    end

    test "allows the group creator to remove a member from the members tab", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "remove-ui-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "remove-ui-member",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "remove-ui-group")

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(lv, "#group-remove-member-#{invitee_profile.id}")

      lv
      |> element("#group-remove-member-#{invitee_profile.id}")
      |> render_click()

      assert has_element?(lv, "#group-members-list", owner_profile.username)
      refute has_element?(lv, "#group-members-list", invitee_profile.username)
      refute Social.member_of_group?(invitee_profile, group)
    end

    test "does not show member removal controls to non-creators", %{conn: conn} do
      owner_account = account_fixture()
      member_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "rmui-own-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "rmui-actor",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "rmui-target",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      member_account = Accounts.get_account!(member_account.id)
      group = create_child_group!(owner_profile, "remove-ui-group-2")

      assert {:ok, member_invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_member_invitation} =
               Social.accept_group_invitation(member_invitation, member_profile)

      assert {:ok, target_invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_target_invitation} =
               Social.accept_group_invitation(target_invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(member_account)
        |> live(~p"/groups/#{group.id}/members")

      refute has_element?(lv, "#group-remove-member-#{invitee_profile.id}")
      refute has_element?(lv, "#group-remove-member-#{owner_profile.id}")
    end

    test "creates an account invite from an email and delivers the group invitation after the first profile",
         %{conn: conn} do
      owner_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "email-ui-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "email-ui-group")
      email = unique_account_email()

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      lv
      |> element("#group-tab-invite-profile")
      |> render_click()

      result =
        lv
        |> form("#group-invite-form-0", %{"invite" => %{"identifier" => email}})
        |> render_submit()

      assert result =~ "Account invitation email sent."

      assert invited_account = Accounts.get_account_by_email(email)
      assert is_nil(invited_account.invited_by_id)
      assert is_nil(Social.get_account_default_profile(invited_account))

      {:ok, invited_profile} =
        Social.create_profile_for_account(invited_account, %{
          username: "email-ui-inv",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert [%{group: %{id: group_id}, inviter: %{id: inviter_id}}] =
               Social.list_pending_invitations(invited_profile)

      assert group_id == group.id
      assert inviter_id == owner_profile.id

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(invited_profile, owner_profile)

      assert direct_group.is_direct
      refute direct_group.is_public
    end

    test "shows invite suggestions with avatars and excludes existing members and pending invitees",
         %{conn: conn} do
      owner_account = account_fixture()
      member_account = account_fixture()
      pending_account = account_fixture()
      suggested_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "sug-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "sug-member",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, pending_profile} =
        Social.create_profile_for_account(pending_account, %{
          username: "sug-pending",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, suggested_profile} =
        Social.create_profile_for_account(suggested_account, %{
          username: "sug-pick",
          profile_picture_url: "https://example.com/suggested-profile.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "invite-suggest-group")

      assert {:ok, member_invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_member_invitation} =
               Social.accept_group_invitation(member_invitation, member_profile)

      assert {:ok, _pending_invitation} =
               Social.invite_profile_to_group(owner_profile, group, pending_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      lv
      |> element("#group-tab-invite-profile")
      |> render_click()

      lv
      |> form("#group-invite-form-0", %{"invite" => %{"identifier" => "sug"}})
      |> render_change()

      assert has_element?(lv, "#group-invite-suggestions")

      assert has_element?(
               lv,
               "#group-invite-suggestion-#{suggested_profile.id}",
               suggested_profile.username
             )

      assert has_element?(
               lv,
               "#group-invite-suggestion-#{suggested_profile.id} img[src^='/avatar/profile/#{suggested_profile.id}']"
             )

      refute has_element?(lv, "#group-invite-suggestion-#{owner_profile.id}")
      refute has_element?(lv, "#group-invite-suggestion-#{member_profile.id}")
      refute has_element?(lv, "#group-invite-suggestion-#{pending_profile.id}")
    end

    test "selecting an invite suggestion fills the invite input", %{conn: conn} do
      owner_account = account_fixture()
      suggested_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "sel-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, suggested_profile} =
        Social.create_profile_for_account(suggested_account, %{
          username: "sel-pick",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "invite-select-group")

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      lv
      |> element("#group-tab-invite-profile")
      |> render_click()

      lv
      |> form("#group-invite-form-0", %{"invite" => %{"identifier" => "sel"}})
      |> render_change()

      lv
      |> element("#group-invite-suggestion-#{suggested_profile.id}")
      |> render_click()

      assert has_element?(lv, "#group-invite-identifier-0[value='#{suggested_profile.username}']")
      refute has_element?(lv, "#group-invite-suggestions")
    end

    test "invites an existing account by email and creates a direct group immediately", %{
      conn: conn
    } do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "email-own-now",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "email-now-inv",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      group = create_child_group!(owner_profile, "email-now-group")
      email = invitee_account.email

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      lv
      |> element("#group-tab-invite-profile")
      |> render_click()

      result =
        lv
        |> form("#group-invite-form-0", %{"invite" => %{"identifier" => email}})
        |> render_submit()

      assert result =~ "Invitation sent."

      assert [%{id: invitation_id}] = Social.list_pending_invitations(invitee_profile)
      assert invitation_id

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(invitee_profile, owner_profile)

      assert direct_group.is_direct
      refute direct_group.is_public
    end

    test "updates value avatars with creator presence in realtime", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "valpres-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "valpres-inv",
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
        |> live(~p"/groups/#{group.id}/values")

      assert has_element?(
               owner_lv,
               "#value-creator-presence-#{invitee_value.id}.presence-p#{invitee_profile.id}"
             )

      refute shown_online?(owner_lv, invitee_profile.id)

      {:ok, invitee_lv, _html} =
        build_conn()
        |> log_in_account(invitee_account)
        |> live(~p"/groups/#{group.id}/values")

      assert shown_online?(invitee_lv, invitee_profile.id)

      assert eventually(fn -> shown_online?(owner_lv, invitee_profile.id) end)
    end

    test "shows only sub-groups where current profile is a member", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgrp-mem",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "subgrp-oth",
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

    test "shows direct and other sub-group tabs on root and filters each list", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "root-tabs-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "root-tabs-other",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, other_child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "root-other-sub-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(profile, other_child_group, other_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, other_profile)

      {:ok, direct_group} = Social.get_or_create_direct_group(profile, other_profile)

      assert {:ok, _other_unread_value} =
               Social.create_value(other_profile, other_child_group, %{
                 "content" => "other subgroup unread",
                 "content_format" => :markdown
               })

      assert {:ok, _direct_unread_value} =
               Social.create_value(other_profile, direct_group, %{
                 "content" => "direct subgroup unread",
                 "content_format" => :markdown
               })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      assert has_element?(lv, "#group-sub-groups-kind-direct")
      assert has_element?(lv, "#group-sub-groups-kind-other")
      assert has_element?(lv, "#group-sub-groups-kind-direct-unread-badge", "1")
      assert has_element?(lv, "#group-sub-groups-kind-other-unread-badge", "1")

      assert has_element?(lv, "#group-children-list", "root-other-sub-group")
      refute has_element?(lv, "#group-children-list", direct_group.name)

      lv
      |> element("#group-sub-groups-kind-direct")
      |> render_click()

      assert_patch(lv, ~p"/groups/#{root_group.id}/sub_groups?sub_groups_kind=direct")

      assert has_element?(lv, "#group-children-list", other_profile.username)
      refute has_element?(lv, "#group-children-list", "root-other-sub-group")
    end

    test "does not show sub-groups kind tabs on non-root groups", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "nonroot-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, parent_group} =
        Social.create_group(profile, root_group, %{
          "name" => "nonroot-tabs-parent",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _child_group} =
        Social.create_group(profile, parent_group, %{
          "name" => "nonroot-tabs-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{parent_group.id}/sub_groups")

      refute has_element?(lv, "#group-sub-groups-kind-tabs")
      refute has_element?(lv, "#group-sub-groups-kind-direct")
      refute has_element?(lv, "#group-sub-groups-kind-other")
      assert has_element?(lv, "#group-children-list", "nonroot-tabs-child")
    end

    test "shows the current group path in the sub-groups tab", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-path",
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
               "#group-path a[href='#{~p"/groups/#{root_group.id}/sub_groups"}'] .hero-home"
             )

      assert has_element?(
               lv,
               "#group-path a[href='#{~p"/groups/#{parent_group.id}/sub_groups"}']",
               "path-parent-group"
             )

      assert has_element?(lv, "#group-path span", "path-current-group")

      lv |> element("#group-values-summary") |> render_click()

      assert has_element?(
               lv,
               "#group-panel-values #group-path a[href='#{~p"/groups/#{parent_group.id}/sub_groups"}']",
               "path-parent-group"
             )

      assert has_element?(lv, "#group-panel-values #group-path span", "path-current-group")
    end

    test "shows the other member username for direct groups in the current group path", %{
      conn: conn
    } do
      current_account = account_fixture()
      other_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "dirpath-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "dirpath-oth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, direct_group} = Social.get_or_create_direct_group(current_profile, other_profile)
      current_account = Accounts.get_account!(current_account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(current_account)
        |> live(~p"/groups/#{direct_group.id}/members")

      assert has_element?(lv, "#group-path span", "dirpath-oth")
      refute has_element?(lv, "#group-path span", direct_group.name)
    end

    test "paginates sub-groups with streams", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgrp-page",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      Enum.each(1..21, fn idx ->
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
      refute has_element?(lv, "#group-children-list", "paged-child-01")
      assert has_element?(lv, "#group-children-list", "paged-child-02")
      assert has_element?(lv, "#group-children-list", "paged-child-21")

      lv
      |> element("#group-children-load-more")
      |> render_click()

      assert has_element?(lv, "#group-children-list", "paged-child-01")
      refute has_element?(lv, "#group-children-load-more")
    end

    test "filters sub-groups by search query", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgrp-search",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, _group} =
        Social.create_group(profile, root_group, %{
          "name" => "alpha-children-team",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _group} =
        Social.create_group(profile, root_group, %{
          "name" => "beta-children-team",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      assert has_element?(lv, "#group-children-list", "alpha-children-team")
      assert has_element?(lv, "#group-children-list", "beta-children-team")

      lv
      |> form("#group-children-search-form", %{"children_search" => %{"q" => "beta"}})
      |> render_change()

      assert has_element?(lv, "#group-children-list li")
      refute has_element?(lv, "#group-children-list", "alpha-children-team")
      assert has_element?(lv, ".bg-yellow-300", "beta")

      lv
      |> form("#group-children-search-form", %{"children_search" => %{"q" => "no-match"}})
      |> render_change()

      assert has_element?(lv, "#group-children-empty", "No sub-groups match your search.")
    end

    test "renders pending join request badges for manageable sub-groups", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "subbadge-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "subbadge-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, public_child_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "subgroup-join-badge-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true,
          "has_public_chat" => false
        })

      assert {:ok, _request} = Social.request_group_access(requester_profile, public_child_group)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{root_group.id}")

      assert has_element?(lv, "#group-pending-join-requests-badge-#{public_child_group.id}", "1")
    end

    test "renders group pictures in header and sub-group list", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "grppic-mem",
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
               "#group-panel-sub-groups img[src^='/avatar/group/#{child_group.id}']"
             )

      {:ok, child_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(
               child_lv,
               "img[src^='/avatar/group/#{child_group.id}'][alt='pictured-child-group']"
             )

      # The avatar route redirects to the external picture.
      conn = get(conn, "/avatar/group/#{child_group.id}")
      assert redirected_to(conn) == "https://example.com/group-avatar.png"
    end

    test "renders values in chronological order with newest at the bottom", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "chronology",
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
        |> live(~p"/groups/#{group.id}/values")

      html = render(lv)

      assert elem(:binary.match(html, "older value"), 0) <
               elem(:binary.match(html, "newer value"), 0)

      assert has_element?(lv, "#group-value-form")
    end

    test "paginates values with streams from the latest page", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "valpage-prof",
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
        |> live(~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-values-load-more")
      refute has_element?(lv, "#group-values-list", "paged value 01")
      assert has_element?(lv, "#group-values-list", "paged value 02")
      assert has_element?(lv, "#group-values-list", "paged value 21")

      lv
      |> element("#group-values-load-more")
      |> render_click()

      assert has_element?(lv, "#group-values-list", "paged value 01")
      assert has_element?(lv, "#group-values-list", "paged value 21")
      refute has_element?(lv, "#group-values-load-more")
    end

    test "loads value parent options when create-group tab is opened", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "creopt-prof",
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
      assert has_element?(lv, "#group_group_picture_url-picker")

      assert has_element?(
               lv,
               "#group_group_picture_url-picker input[type='file'][accept='image/*']"
             )

      assert has_element?(lv, "input[name='group[is_public]'][type='hidden']")
      assert has_element?(lv, "input[name='group[is_public]'][type='checkbox']")
      assert has_element?(lv, "input[name='group[is_root_public]'][type='hidden']")
      assert has_element?(lv, "input[name='group[is_root_public]'][type='checkbox']")
    end

    test "shows edit group only to members and persists edits", %{conn: conn} do
      owner_account = account_fixture()
      viewer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "edit-group-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, viewer_profile} =
        Social.create_profile_for_account(viewer_account, %{
          username: "editgrp-view",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      viewer_account = Accounts.get_account!(viewer_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "editable-group",
          "description" => "before",
          "description_format" => :markdown,
          "is_public" => true,
          "has_public_chat" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, viewer_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, viewer_profile)

      {:ok, owner_lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/edit_group")

      group_picture_url = "data:image/png;base64," <> String.duplicate("a", 25_000)

      assert has_element?(owner_lv, "#group-tab-edit-group")
      assert has_element?(owner_lv, "#group-panel-edit-group")
      assert has_element?(owner_lv, "#group_group_picture_url-picker")
      assert has_element?(owner_lv, "#group-delete-data-values-button")

      assert has_element?(
               owner_lv,
               "#group_group_picture_url-picker input[type='file'][accept='image/*']"
             )

      owner_lv
      |> form("#group-edit-form", %{
        "group" => %{
          "name" => "edited-group",
          "description" => "after",
          "group_picture_url" => group_picture_url,
          "home_page" => "chat",
          "is_public" => "true",
          "uses_api" => "true"
        }
      })
      |> render_submit()

      updated_group = Social.load_picture(Social.get_group!(group.id))

      assert updated_group.name == "edited-group"
      assert updated_group.description == "after"
      assert updated_group.group_picture_url == group_picture_url
      assert updated_group.home_page == :chat
      assert updated_group.uses_api
      refute updated_group.has_public_chat

      # The path is loaded once, but a rename of the group itself reloads it.
      assert has_element?(owner_lv, "#group-path span", "edited-group")

      {:ok, viewer_lv, _html} =
        conn
        |> log_in_account(viewer_account)
        |> live(~p"/groups/#{group.id}/edit_group")

      refute has_element?(viewer_lv, "#group-tab-edit-group")
      refute has_element?(viewer_lv, "#group-panel-edit-group")
      refute has_element?(viewer_lv, "#group-edit-form")
      refute has_element?(viewer_lv, "#group-delete-data-values-button")
      assert has_element?(viewer_lv, "#group-panel-values")
    end

    test "shows root public status and allows enabling it in the create-group form", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "pubchat-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, existing_group} =
        Social.create_group(profile, root_group, %{
          "name" => "root-public-existing-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "is_root_public" => true
        })

      {:ok, existing_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{existing_group.id}")

      assert render(existing_lv) =~ "root-public-existing-group"

      {:ok, create_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}/create_group")

      create_lv
      |> form("#group-create-form", %{
        "group" => %{
          "name" => "created-with-public-chat",
          "description" => "",
          "group_picture_url" => "",
          "home_page" => "subgroups",
          "is_root_public" => "true",
          "is_public" => "false",
          "uses_api" => "true"
        }
      })
      |> render_submit()

      created_group =
        root_group
        |> Social.list_child_groups_for_profile(profile, limit: 20)
        |> Enum.find(&(&1.name == "created-with-public-chat"))

      assert created_group
      assert created_group.is_root_public
      assert created_group.is_public
      assert created_group.home_page == :subgroups
      assert created_group.uses_api
    end

    test "shows group description to non-members on the values tab", %{conn: conn} do
      owner_account = account_fixture()
      viewer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "descr-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _viewer_profile} =
        Social.create_profile_for_account(viewer_account, %{
          username: "descr-view",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      viewer_account = Accounts.get_account!(viewer_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "description-group",
          "description" => "# Welcome\n\nThis is a **public** group.",
          "description_format" => :markdown,
          "is_public" => true,
          "has_public_chat" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(viewer_account)
        |> live(~p"/groups/#{group.id}")

      refute has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-panel-description")
      assert render(lv) =~ "Welcome"
      assert render(lv) =~ "<strong>public</strong>"
    end

    test "sanitizes html descriptions when uses_api is false", %{conn: conn} do
      owner_account = account_fixture()
      viewer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "html-desc-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _viewer_profile} =
        Social.create_profile_for_account(viewer_account, %{
          username: "html-desc-viewer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      viewer_account = Accounts.get_account!(viewer_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "sanitized-html-description-group",
          "description" =>
            ~s|<p><a href="javascript:alert('boom')" onclick="alert('boom')">unsafe link</a></p><script>alert('boom')</script>|,
          "description_format" => :html,
          "is_public" => true,
          "uses_api" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(viewer_account)
        |> live(~p"/groups/#{group.id}")

      rendered = render(element(lv, "#group-panel-description .rich-content"))

      assert has_element?(lv, "#group-panel-description")
      assert rendered =~ "unsafe link"
      refute rendered =~ "javascript:alert"
      refute rendered =~ "onclick="
      refute rendered =~ "<script>alert('boom')</script>"
    end

    test "runs uses_api descriptions in a sandboxed app frame", %{conn: conn} do
      owner_account = account_fixture()
      viewer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "api-html-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _viewer_profile} =
        Social.create_profile_for_account(viewer_account, %{
          username: "api-html-viewer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      viewer_account = Accounts.get_account!(viewer_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "raw-html-description-group",
          "description" =>
            ~s|<p><a href="javascript:alert('boom')" onclick="alert('boom')">unsafe link</a></p>|,
          "description_format" => :html,
          "is_public" => true,
          "uses_api" => true
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(viewer_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-description #group-app-frame iframe[sandbox]")
      refute has_element?(lv, "#group-app-frame iframe[sandbox*='allow-same-origin']")
      refute has_element?(lv, "#group-panel-description .rich-content")

      assert has_element?(lv, "#group-app-frame[data-storage-key='potok-app:#{group.id}']")

      frame_html = lv |> element("#group-app-frame-iframe") |> render()

      assert frame_html =~ "srcdoc="
      assert frame_html =~ "potok_app_sdk.js"
      assert frame_html =~ "app.css"
      assert frame_html =~ "unsafe link"
    end

    test "restarts the app frame when its viewer becomes a member", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "apjn-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "apjn-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      requester_account = Accounts.get_account!(requester_account.id)

      {:ok, group} =
        Social.create_group(owner_profile, Social.get_root_group!(), %{
          "name" => "app-join-group",
          "description" => "<div id=\"app-main\"></div>",
          "description_format" => :html,
          "is_public" => true,
          "uses_api" => true
        })

      {:ok, requester_lv, _html} =
        conn
        |> log_in_account(requester_account)
        |> live(~p"/groups/#{group.id}")

      guest_srcdoc = requester_lv |> element("#group-app-frame-iframe") |> render()
      assert guest_srcdoc =~ "#{requester_profile.id}:false"

      requester_lv |> element("#group-request-access") |> render_click()
      [request] = Social.list_pending_group_join_requests(group)
      {:ok, _} = Social.accept_group_join_request(owner_profile, group, request.id)

      # A new srcdoc makes the browser load the app again, now with access.
      assert eventually(fn ->
               requester_lv
               |> element("#group-app-frame-iframe")
               |> render() =~ "#{requester_profile.id}:true"
             end)
    end

    test "allows a non-member to request access and the creator to approve it from the members tab",
         %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "jrlive-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "jrlive-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      requester_account = Accounts.get_account!(requester_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "join-request-live-group",
          "description" => "Public group for join requests",
          "description_format" => :markdown,
          "is_public" => true,
          "has_public_chat" => false
        })

      {:ok, requester_lv, _html} =
        conn
        |> log_in_account(requester_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(requester_lv, "#group-request-access")

      requester_lv
      |> element("#group-request-access")
      |> render_click()

      assert has_element?(requester_lv, "#group-request-access-pending", "Access request pending")
      assert Social.count_pending_group_join_requests(group) == 1

      {:ok, owner_lv, _html} =
        build_conn()
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(owner_lv, "#group-pending-join-requests-badge-#{group.id}", "1")
      assert has_element?(owner_lv, "#group-join-requests-count", "1")
      assert has_element?(owner_lv, "#group-join-requests-list", requester_profile.username)

      [request] = Social.list_pending_group_join_requests(group)

      owner_lv
      |> element("#group-accept-join-request-#{request.id}")
      |> render_click()

      assert Social.member_of_group?(requester_profile, group)
      refute has_element?(owner_lv, "#group-pending-join-requests-badge-#{group.id}")
      refute has_element?(owner_lv, "#group-join-requests-list", requester_profile.username)
      assert has_element?(owner_lv, "#group-join-requests-empty", "No pending access requests.")

      assert eventually(fn ->
               not has_element?(requester_lv, "#group-request-access-pending") and
                 not has_element?(requester_lv, "#group-request-access")
             end)
    end

    test "lets the creator reject a pending access request from the members tab", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "jrrej-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "jrrej-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      requester_account = Accounts.get_account!(requester_account.id)
      group = create_child_group!(owner_profile, "join-request-reject-group", %{is_public: true})

      assert {:ok, _request} = Social.request_group_access(requester_profile, group)

      {:ok, owner_lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      [request] = Social.list_pending_group_join_requests(group)

      owner_lv
      |> element("#group-reject-join-request-#{request.id}")
      |> render_click()

      refute Social.member_of_group?(requester_profile, group)
      assert Social.count_pending_group_join_requests(group) == 0

      {:ok, requester_lv, _html} =
        build_conn()
        |> log_in_account(requester_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(requester_lv, "#group-request-access")
      refute has_element?(requester_lv, "#group-request-access-pending")
    end

    test "allows a member to delete a leaf group from the edit tab", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delglive-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "delete-group-live",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "has_public_chat" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/edit_group")

      assert has_element?(lv, "#group-delete-button")

      lv
      |> element("#group-delete-button")
      |> render_click()

      assert_redirect(lv, ~p"/groups/#{root_group.id}")
      assert_raise Ecto.NoResultsError, fn -> Social.get_group!(group.id) end
    end

    test "allows the creator to delete only data values from the edit tab", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "deldata-live",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "delete-data-live-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "has_public_chat" => false
        })

      assert {:ok, _regular_value} =
               Social.create_value(profile, group, %{
                 "content" => "keep me",
                 "content_format" => :markdown
               })

      assert {:ok, _data_value_1} =
               Social.create_value(profile, group, %{
                 "content" => "data one",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert {:ok, _data_value_2} =
               Social.create_value(profile, group, %{
                 "content" => "data two",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/edit_group")

      assert has_element?(lv, "#group-delete-data-values-button")
      refute has_element?(lv, "#group-panel-values #group-delete-data-values-button")

      result = render_click(lv, "delete_group_data_values")

      assert result =~ "Deleted 2 data values."
      assert Social.count_group_data_values(group) == 0
      assert Social.count_group_values(group) == 1
      assert has_element?(lv, "#group-panel-edit-group")
    end

    test "keeps the group when deletion is blocked by child groups", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delblock-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, parent_group} =
        Social.create_group(profile, root_group, %{
          "name" => "delete-blocked-parent",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "has_public_chat" => false
        })

      {:ok, _child_group} =
        Social.create_group(profile, parent_group, %{
          "name" => "delete-blocked-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "has_public_chat" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{parent_group.id}/edit_group")

      lv
      |> element("#group-delete-button")
      |> render_click()

      assert render(lv) =~ "Delete this group&#39;s sub-groups before deleting the group."
      assert Social.get_group!(parent_group.id).id == parent_group.id
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
        |> live(~p"/groups/#{group.id}/values")

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
        |> live(~p"/groups/#{group.id}/values")

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
        |> live(~p"/groups/#{group.id}/values")

      assert html =~ "See more"

      # Expansion is a client-side attribute toggle on the value element; both
      # labels are rendered and CSS shows the one matching `data-expanded`.
      toggle_html = lv |> element("#value-toggle-#{value.id}") |> render()

      assert toggle_html =~ "See more"
      assert toggle_html =~ "See less"
      assert toggle_html =~ "data-expanded"
      assert toggle_html =~ "#value-#{value.id}"
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
        |> live(~p"/groups/#{group.id}/values")

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
      assert has_element?(root_lv, "#nav-root-group-unread-badge[hidden]")

      assert {:ok, _value} =
               Social.create_value(writer_profile, root_group, %{
                 "content" => "root unread value",
                 "content_format" => :markdown
               })

      refute has_element?(root_lv, "#group-unread-badge-#{root_group.id}")
      refute has_element?(root_lv, "#group-unread-badge-#{child_group.id}")
      assert has_element?(root_lv, "#nav-root-group-unread-badge[hidden]")

      assert {:ok, _value} =
               Social.create_value(writer_profile, hidden_child_group, %{
                 "content" => "hidden unread value",
                 "content_format" => :markdown
               })

      refute has_element?(root_lv, "#group-unread-badge-#{root_group.id}")
      refute has_element?(root_lv, "#group-unread-badge-#{child_group.id}")
      assert has_element?(root_lv, "#nav-root-group-unread-badge[hidden]")

      assert {:ok, _value} =
               Social.create_value(writer_profile, child_group, %{
                 "content" => "first unread value",
                 "content_format" => :markdown
               })

      assert eventually(
               fn ->
                 has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "1")
               end,
               80
             )

      assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 1})

      assert {:ok, _value} =
               Social.create_value(writer_profile, grandchild_group, %{
                 "content" => "second unread value",
                 "content_format" => :markdown
               })

      assert eventually(
               fn ->
                 has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "2")
               end,
               80
             )

      assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 2})

      {:ok, child_lv, _html} =
        build_conn()
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{child_group.id}/values")

      assert has_element?(child_lv, "#group-sub-groups-unread-badge", "1")
      assert_push_event(child_lv, "root_group_unread_count_updated", %{count: 1})

      assert eventually(
               fn ->
                 has_element?(root_lv, "#group-unread-badge-#{child_group.id}", "1")
               end,
               80
             )

      assert_push_event(root_lv, "root_group_unread_count_updated", %{count: 1})
    end

    test "moves a sub-group with a new unread value to the top of the list", %{conn: conn} do
      owner_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "order-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, writer_profile} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "order-writer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      older_group = create_child_group!(owner_profile, "order-older")
      newer_group = create_child_group!(owner_profile, "order-newer")

      {:ok, invitation} =
        Social.invite_profile_to_group(owner_profile, older_group, writer_profile)

      {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(owner_account.id))
        |> live(~p"/groups/#{Social.get_root_group!().id}")

      assert child_group_dom_ids(root_lv) ==
               ["child-group-#{newer_group.id}", "child-group-#{older_group.id}"]

      {:ok, _value} = Social.create_value(writer_profile, older_group, %{"content" => "news"})

      assert has_element?(root_lv, "#group-unread-badge-#{older_group.id}", "1")

      assert child_group_dom_ids(root_lv) ==
               ["child-group-#{older_group.id}", "child-group-#{newer_group.id}"]
    end

    test "allows the creator profile to delete a value", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delv-live",
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
        |> live(~p"/groups/#{group.id}/values")

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
          username: "editv-live",
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
        |> live(~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#value-edit-#{value.id}")

      lv
      |> element("#value-edit-#{value.id}")
      |> render_click()

      assert has_element?(lv, "#edit-value-form-#{value.id}")
      refute has_element?(lv, "#group-value-form")

      lv
      |> form("#edit-value-form-#{value.id}", value: %{content: "edited liveview value"})
      |> render_submit()

      refute has_element?(lv, "#edit-value-form-#{value.id}")
      assert has_element?(lv, "#group-value-form")
      assert render(lv) =~ "edited liveview value"
      refute render(lv) =~ "original liveview value"
    end

    test "shows the new value composer again after cancelling an edit", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "ceditv-live",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "cancel-edit-value-group")

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "value to keep",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-value-form")

      lv
      |> element("#value-edit-#{value.id}")
      |> render_click()

      assert has_element?(lv, "#edit-value-form-#{value.id}")
      refute has_element?(lv, "#group-value-form")

      lv
      |> element("#edit-value-form-#{value.id} button[phx-click='cancel_edit_value']")
      |> render_click()

      refute has_element?(lv, "#edit-value-form-#{value.id}")
      assert has_element?(lv, "#group-value-form")
      assert render(lv) =~ "value to keep"
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

  describe "value reactions" do
    # Pill ids carry the emoji as lowercase hex: "👍" is f09f918d.
    @thumbs_up_key "f09f918d"

    setup %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "react-live",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "react-live-group")

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "react to this",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/values")

      %{lv: lv, profile: profile, group: group, value: value}
    end

    test "members get the picker trigger and a single picker for the feed", %{
      lv: lv,
      value: value
    } do
      assert has_element?(lv, "#value-react-#{value.id}[data-reaction-trigger]")
      assert has_element?(lv, "#reaction-picker[phx-hook='ReactionPicker'][data-i18n]")
      assert has_element?(lv, "#reaction-picker[data-data-source^='/emoji/en']")
      refute has_element?(lv, "#value-reactions-#{value.id}")
    end

    test "the picker event adds a reaction and clicking the pill removes it", %{
      lv: lv,
      value: value
    } do
      render_hook(lv, "toggle_reaction", %{"id" => to_string(value.id), "emoji" => "👍"})

      pill = "#value-reaction-#{value.id}-#{@thumbs_up_key}"
      assert has_element?(lv, "#{pill}[aria-pressed='true']", "1")

      lv
      |> element(pill)
      |> render_click()

      refute has_element?(lv, pill)
      refute has_element?(lv, "#value-reactions-#{value.id}")
    end

    test "rejects an invalid emoji without adding a reaction", %{lv: lv, value: value} do
      render_hook(lv, "toggle_reaction", %{"id" => to_string(value.id), "emoji" => "nope"})

      refute has_element?(lv, "#value-reactions-#{value.id}")
      assert render(lv) =~ "Could not update reaction."
    end

    test "shows other members' reactions live and joins them on click", %{
      lv: lv,
      profile: profile,
      group: group,
      value: value
    } do
      other = add_group_member!(profile, group, "react-other")
      {:ok, _value} = Social.toggle_value_reaction(other, group, value, "👍")

      pill = "#value-reaction-#{value.id}-#{@thumbs_up_key}"
      assert has_element?(lv, "#{pill}[aria-pressed='false'][title='react-other']", "1")

      lv
      |> element(pill)
      |> render_click()

      assert has_element?(
               lv,
               "#{pill}[aria-pressed='true'][title='react-other, react-live']",
               "2"
             )
    end
  end

  describe "app api" do
    setup %{conn: conn} do
      owner_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "app-api-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group =
        create_child_group!(owner_profile, "app-api-group", %{
          "description" => "<p>app</p>",
          "description_format" => :html,
          "is_public" => true,
          "uses_api" => true
        })

      owner_account = Accounts.get_account!(owner_account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/group_home")

      %{lv: lv, group: group, owner_profile: owner_profile, owner_account: owner_account}
    end

    test "inserts and lists data values", %{lv: lv, group: group} do
      assert has_element?(lv, "#group-app-frame")

      render_hook(lv, "app_api", %{
        "method" => "insert_value",
        "params" => %{"data" => ~s({"score": 3})}
      })

      assert_reply(lv, %{ok: true, value: %{is_data: true, data: %{"score" => 3}} = value})
      assert value.group_id == group.id
      assert value.creator_username == "app-api-owner"

      render_hook(lv, "app_api", %{"method" => "list_values", "params" => %{"limit" => "500"}})
      assert_reply(lv, %{ok: true, values: [listed], has_more: false})
      assert listed.id == value.id

      render_hook(lv, "app_api", %{
        "method" => "list_values",
        "params" => %{"after_id" => value.id}
      })

      assert_reply(lv, %{ok: true, values: [], has_more: false})

      # Data values never show up in the chat stream.
      assert Social.count_group_values(group) == 0
    end

    test "updates the description for the creator only", %{lv: lv, group: group, conn: conn} do
      render_hook(lv, "app_api", %{
        "method" => "update_description",
        "params" => %{"description" => "<p>v2</p>"}
      })

      assert_reply(lv, %{ok: true, group: %{description: "<p>v2</p>"}})
      assert Social.get_group!(group.id).description == "<p>v2</p>"

      viewer_account = account_fixture()

      {:ok, _viewer_profile} =
        Social.create_profile_for_account(viewer_account, %{
          username: "app-api-viewer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, viewer_lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(viewer_account.id))
        |> live(~p"/groups/#{group.id}/group_home")

      render_hook(viewer_lv, "app_api", %{
        "method" => "update_description",
        "params" => %{"description" => "<p>hijack</p>"}
      })

      assert_reply(viewer_lv, %{ok: false, error: "forbidden"})

      render_hook(viewer_lv, "app_api", %{
        "method" => "insert_value",
        "params" => %{"data" => "{}"}
      })

      assert_reply(viewer_lv, %{ok: false, error: "not_a_member"})

      render_hook(viewer_lv, "app_api", %{"method" => "get_description", "params" => %{}})
      assert_reply(viewer_lv, %{ok: true, group: %{description: "<p>v2</p>"}})

      assert Social.get_group!(group.id).description == "<p>v2</p>"
    end

    test "rejects unknown methods and rate limits writes", %{lv: lv} do
      render_hook(lv, "app_api", %{"method" => "delete_group", "params" => %{}})
      assert_reply(lv, %{ok: false, error: "unknown_method"})

      for _ <- 1..30 do
        render_hook(lv, "app_api", %{"method" => "insert_value", "params" => %{"data" => "{}"}})
        assert_reply(lv, %{ok: true})
      end

      render_hook(lv, "app_api", %{"method" => "insert_value", "params" => %{"data" => "{}"}})
      assert_reply(lv, %{ok: false, error: "rate_limited"})
    end

    test "sanitizes html chat values in app groups", %{
      conn: conn,
      group: group,
      owner_profile: owner_profile,
      owner_account: owner_account
    } do
      {:ok, _value} =
        Social.create_value(owner_profile, group, %{
          "content" => ~s|<b>bold</b><img src="x" onerror="alert(1)"><script>alert(2)</script>|,
          "content_format" => :html
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/values")

      rendered = lv |> element("#group-values-list") |> render()

      assert rendered =~ "<b>bold</b>"
      refute rendered =~ "onerror"
      refute rendered =~ "<script>"
    end
  end

  describe "value replies" do
    setup %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "reply-live",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = create_child_group!(profile, "reply-live-group")
      member = add_group_member!(profile, group, "reply-live-mate")

      {:ok, value} =
        Social.create_value(member, group, %{
          "content" => "**What** do you think?",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/values")

      %{
        conn: conn,
        account: account,
        lv: lv,
        profile: profile,
        member: member,
        group: group,
        value: value
      }
    end

    test "an inline reply quotes the replied-to value", %{lv: lv, group: group, value: value} do
      lv
      |> element("#value-reply-#{value.id}")
      |> render_click()

      assert_push_event(lv, "value_composer_focus", %{})
      assert has_element?(lv, "#group-value-reply-preview", "reply-live-mate")
      assert has_element?(lv, "#group-value-reply-preview", "What do you think?")

      lv
      |> form("#group-value-form", value: %{content: "I agree"})
      |> render_submit()

      refute has_element?(lv, "#group-value-reply-preview")

      assert [reply] = Enum.filter(Social.list_group_values(group), &(&1.parent_id == value.id))
      assert reply.content == "I agree"
      assert has_element?(lv, "#value-reply-quote-#{reply.id}", "What do you think?")
      assert has_element?(lv, ~s(#value-reply-quote-#{reply.id}[phx-click*="#value-#{value.id}"]))
    end

    test "cancelling the reply posts a plain value", %{lv: lv, group: group, value: value} do
      lv
      |> element("#value-reply-#{value.id}")
      |> render_click()

      lv
      |> element("#group-value-reply-cancel")
      |> render_click()

      refute has_element?(lv, "#group-value-reply-preview")

      lv
      |> form("#group-value-form", value: %{content: "unrelated"})
      |> render_submit()

      assert %{parent_id: nil} =
               Enum.find(Social.list_group_values(group), &(&1.content == "unrelated"))
    end

    test "ignores a parent_id sent by the client", %{lv: lv, group: group, value: value} do
      render_hook(lv, "create_value", %{
        "value" => %{"content" => "sneaky", "parent_id" => to_string(value.id)}
      })

      assert %{parent_id: nil} =
               Enum.find(Social.list_group_values(group), &(&1.content == "sneaky"))
    end

    test "reply in thread opens a new sub-group started from the value", %{
      conn: conn,
      account: account,
      lv: lv,
      group: group,
      value: value
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> element("#value-thread-#{value.id}")
               |> render_click()

      %{thread: thread} = Social.get_value_for_display(value.id)
      assert to == ~p"/groups/#{thread.id}/values"
      assert thread.parent_id == group.id

      {:ok, thread_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(to)

      assert has_element?(thread_lv, "#group-thread-origin", "reply-live-mate")
      assert has_element?(thread_lv, "#group-thread-origin", "What do you think?")

      assert has_element?(
               thread_lv,
               "#group-thread-origin-link[href='/groups/#{group.id}/values']"
             )

      assert has_element?(thread_lv, "#group-back-link[href='/groups/#{group.id}/values']")
      assert has_element?(thread_lv, "#group-value-form")
    end

    test "a value with a thread links to it instead of offering a new one", %{
      lv: lv,
      profile: profile,
      group: group,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(profile, group, value, %{"name" => "t"})

      assert has_element?(lv, "#value-thread-link-#{value.id}")
      refute has_element?(lv, "#value-thread-#{value.id}")

      assert {:error, {:live_redirect, %{to: to}}} =
               lv
               |> element("#value-thread-link-#{value.id}")
               |> render_click()

      assert to == ~p"/groups/#{thread.id}/values"
    end

    test "the sub-groups list marks threads and can hide them", %{
      conn: conn,
      account: account,
      profile: profile,
      group: group,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(profile, group, value, %{"name" => "t"})
      {:ok, plain} = Social.create_group(profile, group, %{"name" => "plain-sub"})

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/sub_groups")

      assert has_element?(lv, "#child-group-#{thread.id} #group-thread-badge-#{thread.id}")
      refute has_element?(lv, "#group-thread-badge-#{plain.id}")
      assert has_element?(lv, "#group-children-threads-toggle[aria-pressed='true']", "1")

      lv
      |> element("#group-children-threads-toggle")
      |> render_click()

      assert has_element?(lv, "#group-children-threads-toggle[aria-pressed='false']", "1")
      refute has_element?(lv, "#child-group-#{thread.id}")
      assert has_element?(lv, "#child-group-#{plain.id}")

      lv
      |> element("#group-children-threads-toggle")
      |> render_click()

      assert has_element?(lv, "#child-group-#{thread.id}")
    end

    test "hiding the only sub-groups explains the empty list", %{
      conn: conn,
      account: account,
      profile: profile,
      group: group,
      value: value
    } do
      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/sub_groups")

      refute has_element?(lv, "#group-children-threads-toggle")

      {:ok, _thread} = Social.get_or_create_value_thread(profile, group, value, %{"name" => "t"})
      assert has_element?(lv, "#group-children-threads-toggle")

      lv
      |> element("#group-children-threads-toggle")
      |> render_click()

      assert has_element?(lv, "#group-children-empty", "hidden")
    end

    test "a thread's header carries the thread mark", %{
      conn: conn,
      account: account,
      profile: profile,
      group: group,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(profile, group, value, %{"name" => "t"})

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{thread.id}/values")

      assert has_element?(lv, "#group-thread-badge-#{thread.id}")
    end

    test "direct conversations offer inline replies but no threads", %{
      conn: conn,
      account: account,
      profile: profile,
      member: member
    } do
      {:ok, direct} = Social.get_or_create_direct_group(profile, member)
      {:ok, direct_value} = Social.create_value(member, direct, %{"content" => "hi there"})

      {:ok, direct_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{direct.id}/values")

      assert has_element?(direct_lv, "#value-reply-#{direct_value.id}")
      refute has_element?(direct_lv, "#value-thread-#{direct_value.id}")
    end
  end

  defp create_child_group!(profile, name, attrs \\ %{}) do
    root_group = Social.get_root_group!()

    group_attrs =
      Map.merge(
        %{
          "name" => name,
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        },
        Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      )

    {:ok, group} =
      Social.create_group(profile, root_group, group_attrs)

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

  defp shown_online?(lv, profile_id) do
    lv
    |> element("#group-presence-style")
    |> render() =~ ".presence-p#{profile_id}{"
  end

  defp pad_2(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  defp child_group_dom_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#group-children-list > li")
    |> LazyHTML.attribute("id")
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
