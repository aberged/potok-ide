defmodule PotokIdeWeb.AccountLive.ConfirmationTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  @remember_me_cookie "_potok_ide_web_account_remember_me"

  # The buttons are for an account that has a profile; one without gets the
  # modal that makes its first profile (see "Welcome" below).
  defp with_profile(account, username) do
    {:ok, _profile} = Social.create_profile_for_account(account, %{username: username})
    Accounts.get_account!(account.id)
  end

  defp token_for(account) do
    extract_account_token(fn url -> Accounts.deliver_login_instructions(account, url) end)
  end

  setup do
    %{
      unconfirmed_account: with_profile(unconfirmed_account_fixture(), "conf-unconf"),
      confirmed_account: with_profile(account_fixture(), "conf-conf")
    }
  end

  describe "Confirm account" do
    test "renders confirmation page for unconfirmed account", %{
      conn: conn,
      unconfirmed_account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")
      assert html =~ "Confirm and stay logged in"
      refute has_element?(lv, "#welcome-dialog")
    end

    test "renders login page for confirmed account", %{conn: conn, confirmed_account: account} do
      {:ok, lv, html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")
      refute html =~ "Confirm my account"
      assert html =~ "Keep me logged in on this device"
      assert has_element?(lv, "#login-confirmation-card #login_form")
      assert has_element?(lv, "#guest-about-link")
      refute has_element?(lv, "#login-confirmation-card-invitation-note")
      assert has_element?(lv, "#login-confirmation-card-terms-note a[href='/terms']")
    end

    test "auto-submits for already logged in confirmed account", %{
      conn: conn,
      confirmed_account: account
    } do
      conn = log_in_account(conn, account)

      {:ok, lv, html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")
      assert html =~ "Completing sign in..."
      refute html =~ "Log in"
      refute has_element?(lv, "#guest-about-link")

      form = form(lv, "#login_form")
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/accounts/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "auto-submits for already logged in unconfirmed account", %{
      conn: conn,
      unconfirmed_account: account
    } do
      conn = log_in_account(conn, account)

      {:ok, lv, html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")
      assert html =~ "Confirming your account and signing you in..."
      refute html =~ "Confirm and stay logged in"

      form = form(lv, "#confirmation_form")
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/accounts/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account confirmed successfully"
      assert Accounts.get_account!(account.id).confirmed_at
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_account: account} do
      token = token_for(account)
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"account" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Account confirmed successfully"

      assert Accounts.get_account!(account.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/groups"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/#{token}")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed account in without changing confirmed_at", %{
      conn: conn,
      confirmed_account: account
    } do
      token = token_for(account)
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token}")

      form = form(lv, "#login_form", %{"account" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_account!(account.id).confirmed_at == account.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/#{token}")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/accounts/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/accounts/log-in")

      assert html =~ "Magic link is invalid or it has expired"
    end
  end

  describe "Welcome" do
    setup do
      {_owner_account, owner} = account_with_profile!("conf-owner")
      group = group_with_members!(owner, [], %{"name" => "Zgrada Lipa 5"})
      account = unconfirmed_account_fixture()
      {:ok, _invitation} = Social.invite_account_to_group(owner, group, account)

      %{owner: owner, group: group, account: account, token: token_for(account)}
    end

    test "an invited account sees the modal with the group and who invites", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/accounts/log-in/#{ctx.token}")

      assert has_element?(lv, "#welcome-dialog #welcome-profile-form")
      assert has_element?(lv, "#welcome-dialog-group")
      assert has_element?(lv, "#welcome-dialog-lead", "@conf-owner")
      assert has_element?(lv, "#welcome-dialog-lead", "Zgrada Lipa 5")
      assert has_element?(lv, "#welcome-remember-me[checked]")
      assert has_element?(lv, "#welcome-submit", "Create profile and join the group")
      assert has_element?(lv, "#welcome-card h1", "Zgrada Lipa 5")
      assert has_element?(lv, "#welcome-card-terms-note a[href='/terms']")
      assert has_element?(lv, "#welcome-terms-note a[href='/terms']")
      refute has_element?(lv, "#confirmation_form")
    end

    test "the modal closes and opens again", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/accounts/log-in/#{ctx.token}")

      lv |> element("#welcome-close") |> render_click()
      refute has_element?(lv, "#welcome-dialog")

      lv |> element("#welcome-open") |> render_click()
      assert has_element?(lv, "#welcome-dialog")
    end

    test "the name shows its initials and a taken one its error, spending nothing", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/accounts/log-in/#{ctx.token}")

      lv
      |> form("#welcome-profile-form", %{"profile" => %{"username" => "nova komsinica"}})
      |> render_change()

      assert has_element?(lv, "#welcome-picture-preview", "NK")

      lv
      |> form("#welcome-profile-form", %{"profile" => %{"username" => "conf-owner"}})
      |> render_submit()

      assert has_element?(lv, "#welcome-profile-form", "has already been taken")
      refute Social.account_has_profiles?(ctx.account)
      refute Accounts.get_account!(ctx.account.id).confirmed_at
      assert Accounts.get_account_by_magic_link_token(ctx.token)
    end

    test "the button makes the profile, logs in and leads into the group", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/accounts/log-in/#{ctx.token}")

      lv
      |> form("#welcome-profile-form", %{
        "profile" => %{"username" => "nova"},
        "remember_me" => "true"
      })
      |> render_submit()

      conn = follow_trigger_action(form(lv, "#welcome-login-form"), ctx.conn)

      assert redirected_to(conn) == ~p"/groups/#{ctx.group.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Your profile is ready."
      assert get_session(conn, :account_token)
      assert conn.resp_cookies[@remember_me_cookie]

      account = Accounts.get_account!(ctx.account.id)
      assert account.confirmed_at
      profile = Social.get_account_current_profile(account)
      assert profile.username == "nova"
      assert Social.member_of_group?(profile, ctx.group)
    end

    test "without the box ticked the log-in lasts this time only", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/accounts/log-in/#{ctx.token}")

      lv
      |> form("#welcome-profile-form", %{
        "profile" => %{"username" => "nova2"},
        "remember_me" => "false"
      })
      |> render_submit()

      conn = follow_trigger_action(form(lv, "#welcome-login-form"), ctx.conn)

      assert redirected_to(conn) == ~p"/groups/#{ctx.group.id}"
      assert get_session(conn, :account_token)
      refute conn.resp_cookies[@remember_me_cookie]
    end

    test "with no invitation the profile leads to the groups", %{conn: conn} do
      account = unconfirmed_account_fixture()
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")

      assert has_element?(lv, "#welcome-card h1", "Welcome!")
      refute has_element?(lv, "#welcome-dialog-group")
      assert has_element?(lv, "#welcome-submit", "Create profile")

      lv
      |> form("#welcome-profile-form", %{"profile" => %{"username" => "samo-ja"}})
      |> render_submit()

      conn = follow_trigger_action(form(lv, "#welcome-login-form"), conn)
      assert redirected_to(conn) == ~p"/groups"
      assert Accounts.get_account!(account.id).confirmed_at
    end

    test "a confirmed account with no profile gets the modal too", %{conn: conn} do
      account = account_fixture()
      {:ok, lv, _html} = live(conn, ~p"/accounts/log-in/#{token_for(account)}")

      assert has_element?(lv, "#welcome-dialog")
      refute has_element?(lv, "#login_form")
    end

    test "a changed group id only leads to that group's page", ctx do
      conn =
        post(ctx.conn, ~p"/accounts/log-in?_action=welcome", %{
          "account" => %{"token" => ctx.token, "group_id" => "nope"}
        })

      assert redirected_to(conn) == ~p"/groups"
    end
  end
end
