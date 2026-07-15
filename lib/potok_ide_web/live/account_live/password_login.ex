defmodule PotokIdeWeb.AccountLive.PasswordLogin do
  use PotokIdeWeb, :live_view

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
      <div class="mx-auto flex-1 max-w-sm space-y-4 px-6 pt-4 pb-4">
        <div class="mb-0 flex justify-center">
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
                {gettext("Enter your email and password to sign in.")}
              <% end %>
            </:subtitle>
          </.header>
        </div>

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
          <.button class="btn btn-primary rounded-full w-full p-6">
            {gettext("Log in")} <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <p class="text-center text-sm text-base-content/70">
          <.link navigate={~p"/accounts/log-in/magic-link"} class="font-medium underline">
            {gettext("Use a magic link instead")}
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
