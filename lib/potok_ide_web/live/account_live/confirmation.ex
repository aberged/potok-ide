defmodule PotokIdeWeb.AccountLive.Confirmation do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts

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
        id="login-confirmation-card"
        title={gettext("Welcome!")}
        subtitle={@account.email}
      >
        <div :if={@auto_submit} class="lp-note">
          <.icon name="hero-arrow-path" class="lp-accent size-5 shrink-0 animate-spin" />
          <span>
            <%= if @account.confirmed_at do %>
              {gettext("Completing sign in...")}
            <% else %>
              {gettext("Confirming your account and signing you in...")}
            <% end %>
          </span>
        </div>

        <.form
          :if={!@account.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/accounts/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <div :if={!@auto_submit}>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with={gettext("Confirming...")}
              variant="landing"
              class="w-full"
            >
              {gettext("Confirm and stay logged in")}
            </.button>
            <.button
              phx-disable-with={gettext("Confirming...")}
              variant="landing_quiet"
              class="mt-3 w-full"
            >
              {gettext("Confirm and log in only this time")}
            </.button>
          </div>
        </.form>

        <.form
          :if={@account.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/accounts/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @auto_submit do %>
          <% else %>
            <%= if @current_scope do %>
              <.button
                phx-disable-with={gettext("Logging in...")}
                variant="landing"
                class="w-full"
              >
                {gettext("Log in")}
              </.button>
            <% else %>
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with={gettext("Logging in...")}
                variant="landing"
                class="w-full"
              >
                {gettext("Keep me logged in on this device")}
              </.button>
              <.button
                phx-disable-with={gettext("Logging in...")}
                variant="landing_quiet"
                class="mt-3 w-full"
              >
                {gettext("Log me in only this time")}
              </.button>
            <% end %>
          <% end %>
        </.form>

        <p :if={!@account.confirmed_at} class="lp-note mt-6">
          <.icon name="hero-information-circle" class="lp-accent size-5 shrink-0" />
          <span>
            {gettext("Tip: If you prefer passwords, you can enable them in the account settings.")}
          </span>
        </p>
      </Layouts.guest_card>
    </Layouts.guest>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if account = Accounts.get_account_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "account")
      auto_submit = authenticated_account?(socket)

      {:ok,
       assign(socket,
         account: account,
         form: form,
         trigger_submit: auto_submit,
         auto_submit: auto_submit
       ), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Magic link is invalid or it has expired."))
       |> push_navigate(to: ~p"/accounts/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"account" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "account"), trigger_submit: true)}
  end

  defp authenticated_account?(socket) do
    match?(%_{account: %{}}, socket.assigns.current_scope)
  end
end
