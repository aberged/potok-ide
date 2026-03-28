defmodule PotokIdeWeb.ProfileLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "profiles page" do
    test "shows dedicated create and edit page links instead of inline forms", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "linked profile",
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

      assert has_element?(lv, "a[href='/profiles/new']")
      assert has_element?(lv, "a[href='/profiles/#{profile.id}/edit']")
      refute has_element?(lv, "#create-profile-form")
      refute has_element?(lv, "#edit-profile-form")
    end

    test "selects a profile and updates the current profile banner", %{conn: conn} do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "alpha profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "beta profile",
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

      assert html =~ "alpha profile"
      refute html =~ "Profile selected."

      result =
        lv
        |> element("button[phx-click=use][phx-value-id='#{second_profile.id}']")
        |> render_click()

      assert result =~ "Profile selected."
      assert result =~ "beta profile"

      refute result =~
               "Current profile:</div>\n        <div class=\"truncate font-semibold text-base-content\">alpha profile"
    end

    test "creates a profile on the dedicated page", %{conn: conn} do
      account = account_fixture()
      account = Accounts.get_account!(account.id)
      conn = log_in_account(conn, account)

      {:ok, lv, _html} =
        conn
        |> live(~p"/profiles/new")

      assert has_element?(lv, "#create-profile-form")

      {:ok, _index_lv, html} =
        lv
        |> form("#create-profile-form",
          profile: %{
            username: "beta profile",
            profile_picture_url: "https://example.com/avatar.png",
            description: "new description",
            description_format: "markdown",
            sharing: "unique"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/profiles")

      assert html =~ "Profile created."
      assert html =~ "beta profile"
      assert html =~ "https://example.com/avatar.png"
    end

    test "edits a profile on the dedicated page and updates the selected profile banner", %{
      conn: conn
    } do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "alpha profile",
          profile_picture_url: nil,
          description: "old description",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      conn = log_in_account(conn, account)

      {:ok, lv, html} =
        conn
        |> live(~p"/profiles/#{profile.id}/edit")

      assert html =~ "alpha profile"
      assert html =~ "Update the selected profile details."

      {:ok, _index_lv, result} =
        lv
        |> form("#edit-profile-form",
          profile: %{
            username: "beta profile",
            profile_picture_url: "https://example.com/avatar.png",
            description: "new description",
            description_format: "markdown",
            sharing: "unique"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/profiles")

      assert result =~ "Profile updated."
      assert result =~ "Current profile:"
      assert result =~ "beta profile"
      assert result =~ "https://example.com/avatar.png"
      refute result =~ "alpha profile"
    end

    test "updates profiles when another process creates a profile", %{conn: conn} do
      account = account_fixture()
      account = Accounts.get_account!(account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      refute render(lv) =~ "gamma profile"

      {:ok, _profile} =
        Social.create_profile_for_account(account, %{
          username: "gamma profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert render(lv) =~ "gamma profile"
    end

    test "sends a shared profile invitation from the profile editor", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "shared editor profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-shared-target",
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
          username: "shared invite profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-shared-current",
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
      assert result =~ "shared invite profile"
      refute has_element?(lv, "#accept-profile-invitation-#{invitation.id}")
    end
  end
end
