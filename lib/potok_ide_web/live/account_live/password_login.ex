defmodule PotokIdeWeb.AccountLive.PasswordLogin do
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
        id="login-password-card"
        title={gettext("Log in")}
        subtitle={
          if @current_scope,
            do: gettext("You need to reauthenticate to perform sensitive actions on your account."),
            else: gettext("Enter your email and password to sign in.")
        }
        invitation_note={!@current_scope}
      >
        <.form
          for={@form}
          id="login_form_password"
          action={~p"/accounts/log-in"}
          phx-mounted={JS.focus_first()}
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            id="login_form_password_email"
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            id="login_form_password_password"
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            required
          />
          <.input
            field={@form[:remember_me]}
            id="login_form_password_remember_me"
            type="checkbox"
            label={gettext("Keep me logged in on this device")}
          />
          <.button class="lp-button group mt-4 w-full justify-center">
            {gettext("Log in")}
            <.icon
              name="hero-arrow-right"
              class="size-4 transition-transform duration-200 group-hover:translate-x-0.5"
            />
          </.button>
        </.form>

        <p class="mt-6 text-center text-sm">
          <.link navigate={~p"/accounts/log-in/magic-link"} class="lp-link">
            {gettext("Use a magic link instead")}
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

    form =
      to_form(
        %{
          "email" => email,
          "password" => nil,
          "remember_me" => "false"
        },
        as: "account"
      )

    {:ok, assign(socket, form: form)}
  end
end
