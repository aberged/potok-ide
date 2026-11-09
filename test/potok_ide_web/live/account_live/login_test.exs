defmodule PotokIdeWeb.AccountLive.LoginTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/magic-link")

      assert html =~ "Log in"
      assert html =~ "Log in with email"
      assert html =~ ~p"/accounts/log-in"
    end

    test "uses the landing page's look, with the way back to it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/magic-link")

      assert has_element?(lv, "#guest-header #guest-about-link[href='/']")
      assert has_element?(lv, "#guest-footer")
      assert has_element?(lv, "#login-magic-card #login_form_magic")
      assert has_element?(lv, "#login-magic-card-invitation-note a[href='/#landing-join']")
    end

    test "renders PWA metadata in the shared root layout", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/accounts/log-in/magic-link")

      assert html =~ ~s(rel="manifest")
      assert html =~ "/manifest.webmanifest"
      assert html =~ "/images/pwa/icon-180.png"
      assert html =~ ~s(name="theme-color")
      assert html =~ ~s|media="(prefers-color-scheme: dark)"|
      assert html =~ ~s(id="app-update-toast")
      assert html =~ ~s(id="lp-action-sheet")
    end

    test "renders login page in Cyrillic when locale is stored in session", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> init_test_session(%{locale: "sr_Cyrl"})
        |> live(~p"/accounts/log-in/magic-link")

      assert html =~ "Пријави се"
      assert html =~ "Пријави се имејлом"
    end
  end

  describe "account login - magic link" do
    # Sending is `AccountSessionControllerTest`'s: the form is a plain POST, so
    # the rate limit can see the IP.
    test "the form posts to the controller that sends the link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/magic-link")

      assert has_element?(
               lv,
               ~s(#login_form_magic[action="/accounts/log-in/magic-link"][method="post"])
             )

      refute has_element?(lv, "#login_form_magic[phx-submit]")
    end

    test "fills in the address the controller sends back", %{conn: conn} do
      conn =
        post(conn, ~p"/accounts/log-in/magic-link", %{
          "account" => %{"email" => "someone@example.com"}
        })

      assert redirected_to(conn) == ~p"/accounts/log-in/magic-link"

      {:ok, lv, html} = live(recycle(conn), ~p"/accounts/log-in/magic-link")

      assert html =~ "If your email is in our system"
      assert has_element?(lv, ~s(#login_form_magic_email[value="someone@example.com"]))
    end
  end

  describe "authenticated account" do
    setup %{conn: conn} do
      account = account_fixture()
      %{account: account, conn: log_in_account(conn, account)}
    end

    test "redirects to home with flash message", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/accounts/log-in/magic-link")
    end
  end
end
