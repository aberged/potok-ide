defmodule PotokIdeWeb.AccountLive.Login do
  use PotokIdeWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.guest
      flash={@flash}
      current_locale={@current_locale}
      available_locales={@available_locales}
      about_link={!@current_scope}
      centered
    >
      <Layouts.guest_card
        id="login-magic-card"
        title={gettext("Log in")}
        subtitle={
          if @current_scope,
            do: gettext("You need to reauthenticate to perform sensitive actions on your account."),
            else: gettext("Enter your email and we'll send you a sign-in link.")
        }
        invitation_note={!@current_scope}
      >
        <div :if={local_mail_adapter?() and false} class="lp-note mb-6">
          <.icon name="hero-information-circle" class="lp-accent size-5 shrink-0" />
          <div>
            <p>{gettext("You are running the local mail adapter.")}</p>

            <p>
              {gettext("To see sent emails, visit")} <.link href="/dev/mailbox" class="underline">{gettext("the mailbox page")}</.link>.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="login_form_magic"
          action={~p"/accounts/log-in/magic-link"}
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            id="login_form_magic_email"
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="landing" class="group mt-4 w-full">
            {gettext("Log in with email")}
            <.icon
              name="hero-arrow-right"
              class="size-4 transition-transform duration-200 group-hover:translate-x-0.5"
            />
          </.button>
        </.form>

        <p class="mt-6 text-center text-sm">
          <.link navigate={~p"/accounts/log-in"} class="lp-link">
            {gettext("Use email and password instead")}
          </.link>
        </p>
      </Layouts.guest_card>
    </Layouts.guest>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:account), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "account")

    {:ok, assign(socket, form: form)}
  end

  # The form posts to `AccountSessionController.magic_link/2`, which sends the link.

  # defp create_account_from_login_request(email) do
  #   case Accounts.register_account(%{email: email}) do
  #     {:ok, account} ->
  #       account

  #     {:error, _changeset} ->
  #       # In case of race conditions (or invalid email), just fall back.
  #       Accounts.get_account_by_email(email)
  #   end
  # end

  defp local_mail_adapter? do
    Application.get_env(:potok_ide, PotokIde.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
