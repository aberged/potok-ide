defmodule PotokIdeWeb.ProfileLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "profiles page" do
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
  end
end
