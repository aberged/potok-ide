defmodule PotokIdeWeb.AccountDeletionController do
  @moduledoc """
  Deleting an account (`PotokIde.Accounts.Deletion`).

  `/brisanje-naloga` is public, as app stores ask: anyone types an address and
  gets, when it has an account, a link that works for an hour. The link shows
  what goes and what stays, and only the form under it deletes, so a mail
  scanner that opens the link deletes nothing. An address invited by someone
  who never signed up can remove itself the same way.

  From the settings, `post "/accounts/delete"` deletes at once when the person
  logged in within the last minutes (`Accounts.sudo_mode?/1`); the settings
  send the link otherwise.
  """

  use PotokIdeWeb, :controller

  alias PotokIde.Accounts
  alias PotokIde.RateLimit
  alias PotokIdeWeb.AccountAuth
  alias PotokIdeWeb.RateLimited

  def new(conn, _params) do
    email =
      Phoenix.Flash.get(conn.assigns.flash, :email) ||
        get_in(conn.assigns, [:current_scope, Access.key(:account), Access.key(:email)])

    render(conn, :new, form: Phoenix.Component.to_form(%{"email" => email}, as: "account"))
  end

  @doc """
  Sends the link when the address has an account. It answers the same either
  way, and counts the typed address whether it has an account or not.
  """
  def create(conn, %{"account" => %{"email" => email}}) when is_binary(email) do
    email = String.trim(email)

    with :ok <- RateLimit.hit(:account_deletion_ip, RateLimit.ip_key(conn.remote_ip)),
         :ok <- RateLimit.hit(:account_deletion_email, RateLimit.email_key(email)) do
      if account = Accounts.get_account_by_email(email) do
        Accounts.deliver_account_deletion_instructions(
          account,
          &url(~p"/brisanje-naloga/#{&1}")
        )
      end

      conn
      |> put_flash(
        :info,
        gettext(
          "If this address has an account, a link to delete it is on its way. It works for an hour."
        )
      )
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/brisanje-naloga")
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> put_flash(:error, RateLimited.message(retry_after))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/brisanje-naloga")
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/brisanje-naloga")

  @doc "What deleting would do, with the form that deletes. Never deletes."
  def show(conn, %{"token" => token}) do
    case Accounts.get_account_by_deletion_token(token) do
      nil ->
        invalid_link(conn)

      account ->
        render(conn, :show,
          token: token,
          email: account.email,
          preview: Accounts.deletion_preview(account)
        )
    end
  end

  def delete(conn, %{"token" => token}) do
    case Accounts.get_account_by_deletion_token(token) do
      nil -> invalid_link(conn)
      account -> delete_account(conn, account, ~p"/brisanje-naloga/#{token}")
    end
  end

  @doc """
  From the settings: deletes the logged-in account when its person typed its
  address and logged in within the last minutes.
  """
  def delete_current(conn, %{"account" => %{"email" => email}}) when is_binary(email) do
    account = conn.assigns.current_scope.account

    cond do
      String.downcase(String.trim(email)) != String.downcase(account.email) ->
        conn
        |> put_flash(:error, gettext("The address you typed is not the one of this account."))
        |> redirect(to: ~p"/accounts/settings" <> "#settings-account")

      not Accounts.sudo_mode?(account) ->
        conn
        |> put_flash(:error, gettext("Log in again, or ask for the link by email."))
        |> redirect(to: ~p"/accounts/settings" <> "#settings-account")

      true ->
        delete_account(conn, account, ~p"/accounts/settings" <> "#settings-account")
    end
  end

  def delete_current(conn, _params),
    do: redirect(conn, to: ~p"/accounts/settings" <> "#settings-account")

  def done(conn, _params), do: render(conn, :done)

  # For those who type the address in English.
  def new_redirect(conn, _params), do: redirect(conn, to: ~p"/brisanje-naloga")

  defp delete_account(conn, account, back) do
    case Accounts.delete_account(account) do
      {:ok, tokens} ->
        AccountAuth.disconnect_sessions(tokens)

        conn
        |> AccountAuth.end_session()
        |> redirect(to: ~p"/brisanje-naloga/gotovo")

      {:error, {:blocked, _groups}} ->
        conn
        |> put_flash(
          :error,
          gettext(
            "First hand over the groups where you are the only admin, then delete the account."
          )
        )
        |> redirect(to: back)

      {:error, _reason} ->
        invalid_link(conn)
    end
  end

  defp invalid_link(conn) do
    conn
    |> put_flash(:error, gettext("The link is invalid or it has expired."))
    |> redirect(to: ~p"/brisanje-naloga")
  end
end
