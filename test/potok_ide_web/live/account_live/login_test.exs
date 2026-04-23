defmodule PotokIdeWeb.AccountLive.LoginTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "Log in"
      assert html =~ "Log in with email"
      assert html =~ ~p"/accounts/log-in/password"
    end

    test "renders PWA metadata in the shared root layout", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ ~s(rel="manifest")
      assert html =~ "/manifest.webmanifest"
      assert html =~ "/images/pwa/apple-touch-icon.svg"
      assert html =~ ~s(name="theme-color")
    end

    test "renders login page in polish when locale is stored in session", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> init_test_session(%{locale: "pl"})
        |> live(~p"/accounts/log-in")

      assert html =~ "Zaloguj się"
      assert html =~ "Zaloguj się przez e-mail"
    end
  end

  describe "account login - magic link" do
    test "sends magic link email when account exists", %{conn: conn} do
      account = account_fixture()

      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: account.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"

      assert PotokIde.Repo.get_by!(PotokIde.Accounts.AccountToken, account_id: account.id).context ==
               "login"
    end

    test "does not disclose if account is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", account: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "shows login page with email filled in", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in")

      assert html =~ "You need to reauthenticate"
      assert html =~ "Log in with email"

      assert html =~
               ~s(<input type="email" name="account[email]" id="login_form_magic_email" value="#{account.email}")
    end
  end
end
