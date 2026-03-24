defmodule PotokIdeWeb.AccountLive.Settings do
  use PotokIdeWeb, :live_view

  on_mount {PotokIdeWeb.AccountAuth, :require_sudo_mode}

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6 px-4 py-4 overflow-y-auto">
        <div class="text-center">
          <.header>
            {gettext("Account Settings")}
            <:subtitle>
              {gettext("Manage your account email address and password settings")}
            </:subtitle>
          </.header>
        </div>

        <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
          <.input
            field={@email_form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.button variant="primary" phx-disable-with={gettext("Changing...")}>
            {gettext("Change Email")}
          </.button>
        </.form>

        <div class="divider" />

        <.form
          for={@password_form}
          id="password_form"
          action={~p"/accounts/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_account_email"
            spellcheck="false"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
            autocomplete="new-password"
            spellcheck="false"
          />
          <.button variant="primary" phx-disable-with={gettext("Saving...")}>
            {gettext("Save Password")}
          </.button>
        </.form>

        <div class="divider" />

        <section
          id="push-notifications-panel"
          phx-hook="PushNotifications"
          phx-update="ignore"
          data-vapid-public-key={@push_vapid_public_key || ""}
          data-subscribe-url={~p"/accounts/push-subscriptions"}
          data-test-url={~p"/accounts/push-subscriptions/test"}
          class="rounded-[2rem] border border-base-300/70 bg-base-100/80 p-5 shadow-sm shadow-primary/5"
        >
          <div class="space-y-4">
            <div class="space-y-1">
              <h2 class="text-lg font-semibold text-base-content">
                {gettext("Push Notifications")}
              </h2>
              <p class="text-sm text-base-content/70">
                {gettext("Enable device notifications for your installed Potok web app.")}
              </p>
            </div>

            <div
              data-push-status
              aria-live="polite"
              class="rounded-2xl border border-base-300 bg-base-200/70 px-4 py-3 text-sm text-base-content/70"
            >
              {gettext("Checking browser support...")}
            </div>

            <div class="flex flex-wrap gap-3">
              <button
                type="button"
                data-push-enable
                class="inline-flex items-center justify-center rounded-2xl bg-base-content px-4 py-3 text-sm font-medium text-base-100 transition-opacity hover:opacity-90"
              >
                {gettext("Enable notifications")}
              </button>

              <button
                type="button"
                data-push-test
                hidden
                class="inline-flex items-center justify-center rounded-2xl border border-base-300 bg-base-100 px-4 py-3 text-sm font-medium text-base-content transition-colors hover:bg-base-200"
              >
                {gettext("Send test notification")}
              </button>

              <button
                type="button"
                data-push-disable
                hidden
                class="inline-flex items-center justify-center rounded-2xl border border-base-300 bg-base-100 px-4 py-3 text-sm font-medium text-base-content transition-colors hover:bg-base-200"
              >
                {gettext("Disable")}
              </button>
            </div>

            <p class="text-xs text-base-content/55">
              {gettext(
                "Push notifications require an active service worker, browser permission, and HTTPS outside localhost."
              )}
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_account_email(socket.assigns.current_scope.account, token) do
        {:ok, _account} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/accounts/settings")}
  end

  def mount(_params, _session, socket) do
    account = socket.assigns.current_scope.account
    email_changeset = Accounts.change_account_email(account, %{}, validate_unique: false)
    password_changeset = Accounts.change_account_password(account, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, account.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:push_vapid_public_key, PushNotifications.public_key())
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"account" => account_params} = params

    email_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_email(account_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"account" => account_params} = params
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)

    case Accounts.change_account_email(account, account_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_account_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          account.email,
          &url(~p"/accounts/settings/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"account" => account_params} = params

    password_form =
      socket.assigns.current_scope.account
      |> Accounts.change_account_password(account_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"account" => account_params} = params
    account = socket.assigns.current_scope.account
    true = Accounts.sudo_mode?(account)

    case Accounts.change_account_password(account, account_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
