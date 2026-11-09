defmodule PotokIdeWeb.AccountSessionControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Accounts.AccountToken
  alias PotokIde.RateLimit
  alias PotokIde.Repo

  setup do
    %{unconfirmed_account: unconfirmed_account_fixture(), account: account_fixture()}
  end

  describe "POST /accounts/log-in - email and password" do
    test "logs the account in", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/profiles"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/profiles")
      response = html_response(conn, 200)
      assert response =~ "Profiles"
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "logs the account in with remember me", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_potok_ide_web_account_remember_me"]
      assert redirected_to(conn) == ~p"/profiles"
    end

    test "logs the account in with return to", %{conn: conn, account: account} do
      account = set_password(account)

      conn =
        conn
        |> init_test_session(account_return_to: "/foo/bar")
        |> post(~p"/accounts/log-in", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/accounts/log-in?mode=password", %{
          "account" => %{"email" => account.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/accounts/log-in"
    end

    test "redirects to home when account is already authenticated", %{
      conn: conn,
      account: account
    } do
      account = set_password(account)

      conn =
        conn
        |> log_in_account(account)
        |> post(~p"/accounts/log-in", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert redirected_to(conn) == ~p"/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You are already logged in. Please log out first if you want to log in to another account."
    end
  end

  describe "POST /accounts/log-in - magic link" do
    test "logs the account in", %{conn: conn, account: account} do
      {token, _hashed_token} = generate_account_magic_link_token(account)

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => token}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/profiles"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/profiles")
      response = html_response(conn, 200)
      assert response =~ "Profiles"
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "confirms unconfirmed account", %{conn: conn, unconfirmed_account: account} do
      {token, _hashed_token} = generate_account_magic_link_token(account)
      refute account.confirmed_at

      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/profiles"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account confirmed successfully."

      assert Accounts.get_account!(account.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/profiles")
      response = html_response(conn, 200)
      assert response =~ "Profiles"
      assert response =~ ~p"/accounts/settings"
      assert response =~ ~p"/accounts/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/accounts/log-in", %{
          "account" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/accounts/log-in"
    end

    test "allows magic link login when another account is already authenticated", %{
      conn: conn,
      account: account
    } do
      other_account = account_fixture()
      {token, _hashed_token} = generate_account_magic_link_token(other_account)

      conn =
        conn
        |> log_in_account(account)
        |> post(~p"/accounts/log-in", %{
          "account" => %{"token" => token}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/accounts/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end
  end

  describe "DELETE /accounts/log-out" do
    test "logs the account out", %{conn: conn, account: account} do
      conn = conn |> log_in_account(account) |> delete(~p"/accounts/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the account is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/accounts/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  describe "POST /accounts/log-in - password rate limits" do
    test "refuses an address after its failed attempts, even with the right password", %{
      conn: conn,
      account: account
    } do
      account = set_password(account)
      {max, _window} = RateLimit.limit(:password_email)

      for _ <- 1..max do
        conn = post(conn, ~p"/accounts/log-in", password_params(account.email, "wrong password"))
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      end

      conn = post(conn, ~p"/accounts/log-in", password_params(account.email))

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many requests"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == account.email
      assert redirected_to(conn) == ~p"/accounts/log-in"
    end

    test "a successful log-in is not a failure", %{conn: conn, account: account} do
      account = set_password(account)
      {max, _window} = RateLimit.limit(:password_email)

      for _ <- 1..max do
        conn = post(conn, ~p"/accounts/log-in", password_params(account.email))
        assert get_session(conn, :account_token)
      end

      assert :ok = RateLimit.check(:password_email, RateLimit.email_key(account.email))
    end

    test "refuses an IP after its attempts on any address", %{conn: conn, account: account} do
      account = set_password(account)
      {max, _window} = RateLimit.limit(:password_ip)

      for _ <- 1..max do
        post(conn, ~p"/accounts/log-in", password_params(unique_account_email(), "x"))
      end

      conn = post(conn, ~p"/accounts/log-in", password_params(account.email))

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many requests"

      # Another IP is not refused.
      conn = post(build_conn(), ~p"/accounts/log-in", password_params(account.email))
      assert get_session(conn, :account_token)
    end

    test "the confirmed action is limited the same", %{conn: conn, account: account} do
      account = set_password(account)
      fill(:password_email, RateLimit.email_key(account.email))

      conn =
        post(
          conn,
          ~p"/accounts/log-in",
          Map.put(password_params(account.email), "_action", "confirmed")
        )

      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many requests"
    end

    test "a new password logs in even when the address is limited", %{
      conn: conn,
      account: account
    } do
      new_password = "a new password!"
      fill(:password_email, RateLimit.email_key(account.email))

      conn =
        conn
        |> log_in_account(account)
        |> post(~p"/accounts/update-password", %{
          "account" => %{
            "email" => account.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/accounts/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully!"
      assert Accounts.get_account_by_email_and_password(account.email, new_password)
    end
  end

  describe "POST /accounts/log-in/magic-link" do
    test "sends a sign-in link when the address has an account", %{conn: conn, account: account} do
      before = login_tokens(account)

      conn = post(conn, ~p"/accounts/log-in/magic-link", magic_link_params(account.email))

      assert redirected_to(conn) == ~p"/accounts/log-in/magic-link"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Phoenix.Flash.get(conn.assigns.flash, :email) == account.email
      assert login_tokens(account) == before + 1
    end

    test "answers the same for an address without an account", %{conn: conn} do
      conn =
        post(conn, ~p"/accounts/log-in/magic-link", magic_link_params("idonotexist@example.com"))

      assert redirected_to(conn) == ~p"/accounts/log-in/magic-link"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
    end

    test "refuses an address after its requests, whether it has an account or not", %{
      conn: conn,
      account: account
    } do
      {max, _window} = RateLimit.limit(:magic_link_email)
      before = login_tokens(account)

      for email <- [account.email, "nobody#{System.unique_integer()}@example.com"] do
        for _ <- 1..max do
          conn = post(conn, ~p"/accounts/log-in/magic-link", magic_link_params(email))
          assert Phoenix.Flash.get(conn.assigns.flash, :info)
        end

        # Typed in another case, it is the same address.
        conn =
          post(conn, ~p"/accounts/log-in/magic-link", magic_link_params(String.upcase(email)))

        assert redirected_to(conn) == ~p"/accounts/log-in/magic-link"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many requests"
        refute Phoenix.Flash.get(conn.assigns.flash, :info)
      end

      assert login_tokens(account) == before + max
    end

    test "refuses an IP after its requests", %{conn: conn, account: account} do
      {max, _window} = RateLimit.limit(:magic_link_ip)
      before = login_tokens(account)

      for _ <- 1..max do
        post(conn, ~p"/accounts/log-in/magic-link", magic_link_params(unique_account_email()))
      end

      conn = post(conn, ~p"/accounts/log-in/magic-link", magic_link_params(account.email))

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many requests"
      assert login_tokens(account) == before
    end
  end

  defp password_params(email, password \\ valid_account_password()),
    do: %{"account" => %{"email" => email, "password" => password}}

  defp magic_link_params(email), do: %{"account" => %{"email" => email}}

  defp fill(name, id) do
    {max, _window} = RateLimit.limit(name)
    for _ <- 1..max, do: RateLimit.hit(name, id)
  end

  defp login_tokens(account) do
    Repo.aggregate(
      from(t in AccountToken, where: t.account_id == ^account.id and t.context == "login"),
      :count
    )
  end
end
