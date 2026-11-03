defmodule PotokIde.Accounts.AccountNotifier do
  import Swoosh.Email
  require Logger

  alias PotokIde.Mailer
  alias PotokIde.Accounts.Account
  alias PotokIdeWeb.AccountEmails

  # Delivers the email using the application mailer.
  defp deliver(recipient, %{subject: subject, html: html, text: text}) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> html_body(html)
      |> text_body(text)

    with {:ok, delivery_config} <- Mailer.delivery_config(),
         {:ok, _metadata} <- Mailer.deliver(email, delivery_config) do
      {:ok, email}
    else
      error ->
        Logger.error("Email delivery failed for #{inspect(subject)}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Deliver instructions to confirm a new account email, to that new address.
  """
  def deliver_update_email_instructions(account, current_email, url) do
    deliver(
      account.email,
      AccountEmails.email_change(%{to: account.email, old_email: current_email, url: url})
    )
  end

  @doc """
  Deliver a magic link: the sign-in link of a confirmed account, or the
  invitation of an unconfirmed one, which an invitation opened.

  ## Options

    * `:inviter` - the username of the profile who invited the account
    * `:group` - the name of the group the account is invited to
  """
  def deliver_login_instructions(account, web_url, app_url \\ nil, opts \\ []) do
    params = %{to: account.email, url: web_url, app_url: app_url}

    email =
      case account do
        %Account{confirmed_at: nil} ->
          AccountEmails.invitation(Map.merge(params, Map.new(opts)))

        _ ->
          AccountEmails.sign_in(params)
      end

    deliver(account.email, email)
  end
end
