defmodule PotokIdeWeb.ProfileLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "profiles page" do
    test "toggles the create profile section", %{conn: conn} do
      account = account_fixture()
      account = Accounts.get_account!(account.id)

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      refute has_element?(lv, "#create-profile-form")

      lv
      |> element("#toggle-create-profile")
      |> render_click()

      assert has_element?(lv, "#create-profile-form")

      lv
      |> element("#toggle-create-profile")
      |> render_click()

      refute has_element?(lv, "#create-profile-form")
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

    test "edits a profile and updates the selected profile banner", %{conn: conn} do
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

      {:ok, lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/profiles")

      assert html =~ "alpha profile"
      assert html =~ "Current profile:"

      lv
      |> element("button[phx-click=edit][phx-value-id='#{profile.id}']")
      |> render_click()

      result =
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

      assert result =~ "Profile updated."
      assert result =~ "beta profile"
      assert result =~ "https://example.com/avatar.png"
      refute result =~ "alpha profile"
    end

    test "collapses the edit profile section from its header", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "collapse profile",
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

      lv
      |> element("button[phx-click=edit][phx-value-id='#{profile.id}']")
      |> render_click()

      assert has_element?(lv, "#edit-profile-form")

      lv
      |> element("#toggle-edit-profile")
      |> render_click()

      refute has_element?(lv, "#edit-profile-form")
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
  end
end
