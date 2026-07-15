defmodule PotokIdeWeb.AccountLive.Login do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_profile={@current_profile}
      current_locale={@current_locale}
      available_locales={@available_locales}
      pending_invitations_count={@pending_invitations_count}
      pending_group_join_requests_count={@pending_group_join_requests_count}
      root_group_unread_count={@root_group_unread_count}
    >
      <div class="mx-auto max-w-sm space-y-2 px-6 pt-4 pb-4 flex-1">
        <div class="flex justify-center mb-0">
          <img
            src={~p"/images/icon-transparent.svg"}
            alt="Potok"
            class="h-30 w-30"
          />
        </div>

        <div class="text-center">
          <.header>
            <p>{gettext("Log in")}</p>

            <:subtitle>
              <%= if @current_scope do %>
                {gettext("You need to reauthenticate to perform sensitive actions on your account.")}
              <% else %>
                {gettext("Enter your email and we'll send you a sign-in link.")}
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?() and false} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
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
          action={~p"/accounts/log-in"}
          phx-submit="submit_magic"
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
          <.button class="btn btn-primary rounded-full w-full mt-4 p-6">
            {gettext("Log in with email")} <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <p class="text-center text-sm text-base-content/70">
          <.link navigate={~p"/accounts/log-in"} class="font-medium underline">
            {gettext("Use email and password instead")}
          </.link>
        </p>
      </div>
    </Layouts.app>
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

  @impl true
  def handle_event("submit_magic", %{"account" => %{"email" => email}}, socket) do
    # || create_account_from_login_request(email)
    account = Accounts.get_account_by_email(email)

    if account do
      Accounts.deliver_login_instructions(account, &url(~p"/accounts/log-in/#{&1}"))
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions for logging in shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/accounts/log-in/magic-link")}
  end

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
