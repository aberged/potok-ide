defmodule PotokIdeWeb.AccountLive.PasswordLoginTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  describe "password login page" do
    test "renders password login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/password")

      assert html =~ "Log in with password"
      assert html =~ ~p"/accounts/log-in?mode=password"
      assert html =~ "Use a magic link instead"
    end

    test "renders password login page in polish when locale is stored in session", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> init_test_session(%{locale: "pl"})
        |> live(~p"/accounts/log-in/password")

      assert html =~ ~s(<html lang="pl")
      assert html =~ "Zaloguj się"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "shows password login page with email filled in", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/password")

      assert html =~ "You need to reauthenticate"

      assert html =~
               ~s(<input type="email" name="account[email]" id="login_form_password_email" value="#{account.email}")
    end
  end
end
