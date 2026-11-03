defmodule PotokIdeWeb.ProfileLive.FormSectionsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  defp profile_for!(account, username, sharing \\ :unique) do
    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: sharing
      })

    profile
  end

  defp live_as(conn, account, path) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(path)
  end

  defp open_tab(lv, tab), do: lv |> element(tab) |> render_click()

  describe "new profile" do
    test "shows one card at a time and keeps the others in the form", %{conn: conn} do
      {:ok, lv, _html} = live_as(conn, account_fixture(), ~p"/profiles/new")

      assert has_element?(lv, "#profile-new-header h1")
      assert has_element?(lv, "#profile-new-basics:not(.hidden)")
      assert has_element?(lv, "#profile-new-sharing.hidden")

      open_tab(lv, "#profile-new-tab-sharing")

      assert has_element?(lv, "#profile-new-sharing:not(.hidden)")
      assert has_element?(lv, "#create-profile-form #profile-new-basics.hidden #profile_username")
      assert has_element?(lv, "#profile-new-bar #profile-new-submit[form='create-profile-form']")
    end

    test "a card the page does not have changes nothing", %{conn: conn} do
      {:ok, lv, _html} = live_as(conn, account_fixture(), ~p"/profiles/new")

      render_click(lv, "set_section", %{"section" => "tags"})

      assert has_element?(lv, "#profile-new-basics:not(.hidden)")
    end

    test "a failed create opens the card with the error", %{conn: conn} do
      {:ok, lv, _html} = live_as(conn, account_fixture(), ~p"/profiles/new")

      open_tab(lv, "#profile-new-tab-sharing")

      lv
      |> form("#create-profile-form", profile: %{username: ""})
      |> render_submit()

      assert has_element?(lv, "#profile-new-basics:not(.hidden)")
      assert has_element?(lv, "#profile-new-sharing.hidden")
    end
  end

  describe "edit profile" do
    setup do
      account = account_fixture()
      %{account: account, profile: profile_for!(account, "sections-prof")}
    end

    test "the header leads back to the profiles", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{ctx.profile.id}/edit")

      assert has_element?(lv, "#profile-edit-header", "sections-prof")
      assert has_element?(lv, "#profile-edit-back[href='/profiles']")
    end

    test "the save bar shows over every card while there are unsaved changes",
         %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{ctx.profile.id}/edit")

      refute has_element?(lv, "#profile-edit-save-bar")

      lv
      |> form("#edit-profile-form", profile: %{description: "changed"})
      |> render_change()

      assert has_element?(
               lv,
               "#profile-edit-save-bar #profile-edit-save[form='edit-profile-form']"
             )

      open_tab(lv, "#profile-edit-tab-tags")
      assert has_element?(lv, "#profile-edit-save-bar")

      lv |> element("#profile-edit-discard") |> render_click()

      refute has_element?(lv, "#profile-edit-save-bar")
      refute has_element?(lv, "#profile_description", "changed")
    end

    test "a cleared name counts as unsaved, and saving it opens its card", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{ctx.profile.id}/edit")

      lv
      |> form("#edit-profile-form", profile: %{username: ""})
      |> render_change()

      assert has_element?(lv, "#profile-edit-save-bar")

      open_tab(lv, "#profile-edit-tab-description")

      lv
      |> form("#edit-profile-form", profile: %{username: ""})
      |> render_submit()

      assert has_element?(lv, "#profile-edit-basics:not(.hidden)")
      assert has_element?(lv, "#profile-edit-description.hidden")
    end

    test "tags have a card of their own", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{ctx.profile.id}/edit")

      assert has_element?(lv, "#profile-tags-section.hidden")

      open_tab(lv, "#profile-edit-tab-tags")

      assert has_element?(lv, "#profile-tags-section:not(.hidden)")
      assert has_element?(lv, "#profile-edit-basics.hidden")
    end

    test "the invitation sits with the sharing of a shared profile only", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{ctx.profile.id}/edit")
      refute has_element?(lv, "#profile-edit-invite")

      shared = profile_for!(ctx.account, "sections-shared", :shared)
      {:ok, lv, _html} = live_as(conn, ctx.account, ~p"/profiles/#{shared.id}/edit")

      assert has_element?(lv, "#profile-edit-invite.hidden")

      open_tab(lv, "#profile-edit-tab-sharing")

      assert has_element?(lv, "#profile-edit-sharing:not(.hidden)")
      assert has_element?(lv, "#profile-edit-invite:not(.hidden)")
    end
  end
end
