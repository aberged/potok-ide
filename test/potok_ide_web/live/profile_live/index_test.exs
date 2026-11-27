defmodule PotokIdeWeb.ProfileLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "profiles page" do
    test "a row uses the profile and its menu holds the rest", %{conn: conn} do
      account = account_fixture()

      {:ok, first} =
        Social.create_profile_for_account(account, %{
          username: "row-first",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second} =
        Social.create_profile_for_account(account, %{
          username: "row-second",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(account.id))
        |> live(~p"/profiles")

      # The last profile made is the current one.
      assert has_element?(lv, "#use-profile-#{second.id}[disabled]")
      refute has_element?(lv, "#use-profile-#{first.id}[disabled]")

      assert has_element?(
               lv,
               "#profile-menu-#{first.id}-container #set-default-profile-#{first.id}"
             )

      assert has_element?(
               lv,
               "#profile-menu-#{first.id}-container a[href='/profiles/#{first.id}/edit']"
             )

      lv |> element("#use-profile-#{first.id}") |> render_click()

      assert has_element?(lv, "#use-profile-#{first.id}[disabled]")
      refute has_element?(lv, "#use-profile-#{second.id}[disabled]")
    end

    test "names a profile's sharing in the language of the page", %{conn: conn} do
      account = account_fixture()

      {:ok, _profile} =
        Social.create_profile_for_account(account, %{
          username: "sharing-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, lv, _html} =
        conn
        |> init_test_session(%{locale: "sr_Cyrl"})
        |> log_in_account(Accounts.get_account!(account.id))
        |> live(~p"/profiles")

      assert has_element?(lv, "li", "Дељени")
      refute has_element?(lv, "li", "shared")
    end

    test "shows dedicated create and edit page links instead of inline forms", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "linked-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      assert has_element?(lv, "#profiles-header h1", "Profiles")
      assert has_element?(lv, "a[href='/profiles/new']")
      assert has_element?(lv, "a[href='/profiles/#{profile.id}/edit']")
      refute has_element?(lv, "#create-profile-form")
      refute has_element?(lv, "#edit-profile-form")
    end

    test "selects a profile and updates the current profile banner", %{conn: conn} do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "alpha-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "beta-prof",
          profile_picture_url: "https://example.com/beta.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, account} = Accounts.set_current_profile(account, first_profile)
      account = Accounts.get_account!(account.id)

      {:ok, lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      assert html =~ "alpha-prof"
      assert has_element?(lv, "#profiles-summary #profiles-current", "alpha-prof")
      assert has_element?(lv, "#profiles-close[phx-hook]")

      lv
      |> element("button[phx-click=use][phx-value-id='#{second_profile.id}']")
      |> render_click()

      # The page closes in the browser, once the profile is saved.
      assert_push_event(lv, "profiles_close", %{})
      assert Accounts.get_account!(account.id).current_profile_id == second_profile.id
      assert has_element?(lv, "#profiles-current", "beta-prof")
      refute has_element?(lv, "#profiles-current", "alpha-prof")
    end

    test "sets a default profile from the profiles page", %{conn: conn} do
      account = account_fixture()

      {:ok, _first_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-a",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-b",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      {:ok, lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      assert html =~ "Default profile:"
      assert has_element?(lv, "#set-default-profile-#{second_profile.id}")

      result =
        lv
        |> element("#set-default-profile-#{second_profile.id}")
        |> render_click()

      assert result =~ "Default profile updated."
      # Making a profile the default leaves the page open.
      refute_push_event(lv, "profiles_close", %{})
      assert result =~ "Default profile:"
      assert has_element?(lv, "#profiles-summary #profiles-default", "default-b")
      refute has_element?(lv, "#profiles-default", "default-a")

      updated_account = Accounts.get_account!(account.id)
      assert updated_account.default_profile_id == second_profile.id
    end

    test "creates a profile on the dedicated page", %{conn: conn} do
      account = account_fixture()
      account = Accounts.get_account!(account.id)
      conn = log_in_account(conn, account)

      {:ok, lv, _html} =
        conn
        |> live(~p"/profiles/new")

      assert has_element?(lv, "#create-profile-form")
      assert has_element?(lv, "#profile_profile_picture_url-picker")

      assert has_element?(
               lv,
               "#profile_profile_picture_url-picker input[type='file'][accept='image/*']"
             )

      {:ok, _index_lv, html} =
        lv
        |> form("#create-profile-form",
          profile: %{
            username: "beta-prof",
            profile_picture_url: "https://example.com/avatar.png",
            description: "new description",
            sharing: "unique"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/profiles")

      assert html =~ "Profile created."
      assert html =~ "beta-prof"
      # Pictures are never inlined; they are served through the avatar route.
      refute html =~ "https://example.com/avatar.png"
      created = Social.get_profile_by_username("beta-prof")
      assert html =~ "/avatar/profile/#{created.id}"
    end

    test "edits a profile on the dedicated page and updates the selected profile banner", %{
      conn: conn
    } do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "alpha-prof",
          profile_picture_url: nil,
          description: "old description",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      conn = log_in_account(conn, account)

      {:ok, lv, _html} =
        conn
        |> live(~p"/profiles/#{profile.id}/edit")

      assert has_element?(lv, "#profile-edit-header", "alpha-prof")

      {:ok, _index_lv, result} =
        lv
        |> form("#edit-profile-form",
          profile: %{
            username: "beta-prof",
            profile_picture_url: "https://example.com/avatar.png",
            description: "new description",
            sharing: "unique"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/profiles")

      assert result =~ "Profile updated."
      assert result =~ "Current profile:"
      assert result =~ "beta-prof"
      refute result =~ "https://example.com/avatar.png"
      assert result =~ "/avatar/profile/#{profile.id}"
      refute result =~ "alpha-prof"
    end

    test "updates profiles when another process creates a profile", %{conn: conn} do
      account = account_fixture()
      account = Accounts.get_account!(account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      refute render(lv) =~ "gamma-prof"

      {:ok, _profile} =
        Social.create_profile_for_account(account, %{
          username: "gamma-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert render(lv) =~ "gamma-prof"
    end

    test "sends a shared profile invitation from the profile editor", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "shared-editor",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-share",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      inviter_account = Accounts.get_account!(inviter_account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(inviter_account)
        |> live(~p"/profiles/#{shared_profile.id}/edit")

      assert has_element?(lv, "#shared-profile-invitation-form")

      result =
        lv
        |> form("#shared-profile-invitation-form",
          profile_invitation: %{username: invitee_profile.username}
        )
        |> render_submit()

      assert result =~ "Shared profile invitation sent."

      [pending_invitation] = Social.list_pending_profile_invitations(invitee_profile)
      assert pending_invitation.profile_id == shared_profile.id
    end

    test "accepts a shared profile invitation from the profiles page", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "shared-invite",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_profile(
                 inviter_account,
                 shared_profile,
                 shared_profile,
                 invitee_profile
               )

      invitee_account = Accounts.get_account!(invitee_account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/profiles")

      assert has_element?(lv, "#shared-profile-invitations")

      result =
        lv
        |> element("#accept-profile-invitation-#{invitation.id}")
        |> render_click()

      assert result =~ "Shared profile invitation accepted."
      assert result =~ "shared-invite"
      refute has_element?(lv, "#accept-profile-invitation-#{invitation.id}")
    end

    test "keeps running and updates the unread badge when a value is posted in a group",
         %{conn: conn} do
      account = account_fixture()
      author_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "unread-reader",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, author} =
        Social.create_profile_for_account(author_account, %{
          username: "unread-author",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(author, Social.get_root_group!(), %{
          "name" => "unread-badge-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, invitation} = Social.invite_profile_to_group(author, group, profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(account.id))
        |> live(~p"/profiles")

      {:ok, _value} =
        Social.create_value(author, group, %{"content" => "hello", "content_format" => :markdown})

      assert_push_event(lv, "root_group_unread_count_updated", %{count: 1})
      assert has_element?(lv, "a[href='/profiles/#{profile.id}/edit']")
    end
  end

  # An account logged in with no profile yet gets the modal of an
  # invitation's link (`ProfileComponents.welcome_dialog/1`).
  describe "an account with no profile" do
    setup %{conn: conn} do
      {_owner_account, owner} = PotokIde.EventsFixtures.account_with_profile!("idx-owner")
      group = PotokIde.EventsFixtures.group_with_members!(owner, [])
      account = account_fixture()
      {:ok, _invitation} = Social.invite_account_to_group(owner, group, account)

      %{conn: log_in_account(conn, account), account: account, group: group}
    end

    test "gets the modal, and its profile goes into the invited group", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/profiles")

      assert has_element?(lv, "#welcome-dialog #welcome-profile-form")
      assert has_element?(lv, "#welcome-dialog-group")
      refute has_element?(lv, "#welcome-remember-me")

      lv |> element("#welcome-close") |> render_click()
      refute has_element?(lv, "#welcome-dialog")
      lv |> element("#profiles-create") |> render_click()
      assert has_element?(lv, "#welcome-dialog")

      lv
      |> form("#welcome-profile-form", %{"profile" => %{"username" => "idx-new"}})
      |> render_submit()

      flash = assert_redirect(lv, ~p"/groups/#{ctx.group.id}")
      assert flash["info"] =~ "Your profile is ready."
      profile = Social.get_account_current_profile(Accounts.get_account!(ctx.account.id))
      assert Social.member_of_group?(profile, ctx.group)
    end

    test "comes to the profiles page without an error", ctx do
      assert {:error, {:redirect, %{to: "/profiles", flash: flash}}} = live(ctx.conn, ~p"/groups")
      refute flash["error"]
    end

    test "an account with a profile gets no modal", %{conn: conn} do
      account = account_fixture()
      {:ok, _profile} = Social.create_profile_for_account(account, %{username: "idx-has"})

      {:ok, lv, _html} =
        conn
        |> log_in_account(Accounts.get_account!(account.id))
        |> live(~p"/profiles")

      refute has_element?(lv, "#welcome-dialog")
      assert has_element?(lv, "#profiles-create[href='/profiles/new']")
    end
  end
end
