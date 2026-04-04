defmodule PotokIde.Accounts.AccountNotifier do
  use Gettext, backend: PotokIdeWeb.Gettext

  import Swoosh.Email

  alias PotokIde.Mailer
  alias PotokIde.Accounts.Account

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, delivery_config} <- Mailer.delivery_config(),
         {:ok, _metadata} <- Mailer.deliver(email, delivery_config) do
      # IO.inspect(email)
      # IO.inspect(delivery_config)
      # IO.inspect(_metadata)
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a account email.
  """
  def deliver_update_email_instructions(account, url) do
    deliver(account.email, gettext("Update email instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: account.email)}

    #{gettext("You can change your email by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't request this change, please ignore this.")}

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(account, url) do
    case account do
      %Account{confirmed_at: nil} -> deliver_confirmation_instructions(account, url)
      _ -> deliver_magic_link_instructions(account, url)
    end
  end

  defp deliver_magic_link_instructions(account, url) do
    deliver(account.email, gettext("Log in instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: account.email)}

    #{gettext("You can log into your account by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't request this email, please ignore this.")}

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(account, url) do
    deliver(account.email, gettext("Confirmation instructions"), """

    ==============================

    #{gettext("Hi %{email},", email: account.email)}

    #{gettext("You can confirm your account by visiting the URL below:")}

    #{url}

    #{gettext("If you didn't create an account with us, please ignore this.")}

    ==============================
    """)
  end
end
