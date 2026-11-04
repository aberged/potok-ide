defmodule PotokIdeWeb.AccountLive.PasswordLoginTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  describe "password login page" do
    test "renders password login page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "Log in"
      assert html =~ ~p"/accounts/log-in"
      assert html =~ "Use a magic link instead"
      assert has_element?(lv, "#login_form_password [data-password-toggle]")
    end

    test "uses the landing page's look, with the way back to it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      assert has_element?(lv, "#guest-header #guest-about-link[href='/']")
      assert has_element?(lv, "#guest-footer #guest-privacy-link")
      assert has_element?(lv, "#login-password-card #login_form_password")
      assert has_element?(lv, "#login-password-card-invitation-note a[href='/#landing-join']")
    end

    test "renders password login page in Cyrillic when locale is stored in session", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> init_test_session(%{locale: "sr_Cyrl"})
        |> live(~p"/accounts/log-in")

      assert html =~ ~s(<html lang="sr-Cyrl")
      assert html =~ "Пријави се"
    end
  end

  describe "authenticated account" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "redirects to home with flash message", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/accounts/log-in")
    end
  end
end
