defmodule PotokIdeWeb.AccountSessionController do
  use PotokIdeWeb, :controller

  alias PotokIde.Accounts
  alias PotokIde.RateLimit
  alias PotokIdeWeb.AccountAuth
  alias PotokIdeWeb.RateLimited

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("Account confirmed successfully."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # magic link login
  defp create(conn, %{"account" => %{"token" => token} = account_params}, info) do
    case Accounts.login_account_by_magic_link(token) do
      {:ok, {account, tokens_to_disconnect}} ->
        AccountAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> AccountAuth.log_in_account(account, account_params)

      _ ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/accounts/log-in")
    end
  end

  # email + password login: counted per IP and, when it fails, per address,
  # both before the password is hashed.
  defp create(conn, %{"account" => account_params}, info) do
    %{"email" => email, "password" => _password} = account_params
    address = RateLimit.email_key(email)

    with :ok <- RateLimit.hit(:password_ip, RateLimit.ip_key(conn.remote_ip)),
         :ok <- RateLimit.check(:password_email, address) do
      password_log_in(conn, account_params, info, fn ->
        RateLimit.hit(:password_email, address)
      end)
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> put_flash(:error, RateLimited.message(retry_after))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/accounts/log-in")
    end
  end

  @doc """
  Sends an email with a sign-in link when the address has an account. It
  answers the same either way, and counts the typed address whether it has an
  account or not, so a refusal does not tell either.
  """
  def magic_link(conn, %{"account" => %{"email" => email}}) when is_binary(email) do
    with :ok <- RateLimit.hit(:magic_link_ip, RateLimit.ip_key(conn.remote_ip)),
         :ok <- RateLimit.hit(:magic_link_email, RateLimit.email_key(email)) do
      if account = Accounts.get_account_by_email(email) do
        Accounts.deliver_login_instructions(account, &url(~p"/accounts/log-in/#{&1}"))
      end

      conn
      |> put_flash(
        :info,
        gettext(
          "If your email is in our system, you will receive instructions for logging in shortly."
        )
      )
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/accounts/log-in/magic-link")
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> put_flash(:error, RateLimited.message(retry_after))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/accounts/log-in/magic-link")
    end
  end

  def magic_link(conn, _params), do: redirect(conn, to: ~p"/accounts/log-in/magic-link")

  def update_password(conn, %{"account" => account_params}) do
    account = conn.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)
    {:ok, {_account, expired_tokens}} = Accounts.update_account_password(account, account_params)

    # disconnect all existing LiveViews with old sessions
    AccountAuth.disconnect_sessions(expired_tokens)

    # Not rate limited: the password has just changed in sudo mode, and a
    # refusal here would leave the account logged out.
    conn
    |> put_session(:account_return_to, ~p"/accounts/settings")
    |> password_log_in(account_params, gettext("Password updated successfully!"), fn -> :ok end)
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> AccountAuth.log_out_account()
  end

  defp password_log_in(conn, account_params, info, on_failure) do
    %{"email" => email, "password" => password} = account_params

    if account = Accounts.get_account_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> AccountAuth.log_in_account(account, account_params)
    else
      on_failure.()

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, gettext("Invalid email or password"))
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/accounts/log-in")
    end
  end
end
