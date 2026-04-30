defmodule PotokIdeWeb.AccountLive.Settings do
  use PotokIdeWeb, :live_view

  # on_mount {PotokIdeWeb.AccountAuth, :require_sudo_mode}

  require Logger

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6 px-4 py-4 h-[calc(100dvh-8rem)] overflow-y-auto">
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
            class="disabled"
          />
          <%!-- <.button variant="primary" phx-disable-with={gettext("Changing...")}>
            {gettext("Change Email")}
          </.button> --%>
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
          class="rounded-4xl border border-base-300/70 bg-base-100/80 p-5 shadow-sm shadow-primary/5"
        >
          <div class="space-y-4">
            <div class="space-y-1">
              <h2 class="text-lg font-semibold text-base-content">
                {gettext("Push Notifications")}
              </h2>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Enable notifications for this browser or for the installed Potok app on your device."
                )}
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
                "Browser push requires an active service worker and HTTPS outside localhost. The installed Potok app uses native device permissions and Firebase Cloud Messaging."
              )}
            </p>
          </div>
        </section>

        <section
          id="push-subscriptions-panel"
          class="rounded-4xl border border-base-300/70 bg-base-100/80 p-5 shadow-sm shadow-primary/5"
        >
          <div class="space-y-4">
            <div class="space-y-1">
              <h2 class="text-lg font-semibold text-base-content">
                {gettext("Stored Push Subscriptions")}
              </h2>
              <p class="text-sm text-base-content/70">
                {gettext("All saved push subscription entities for this account.")}
              </p>
            </div>

            <div
              :if={@push_subscriptions == []}
              class="rounded-2xl border border-dashed border-base-300 bg-base-200/40 px-4 py-5 text-sm text-base-content/65"
            >
              {gettext("No push subscriptions have been stored for this account yet.")}
            </div>

            <div :if={@push_subscriptions != []} id="push-subscriptions-list" class="space-y-3">
              <article
                :for={subscription <- @push_subscriptions}
                id={"push-subscription-#{subscription.id}"}
                class="rounded-2xl border border-base-300/80 bg-base-100 px-4 py-4"
              >
                <div class="flex flex-wrap items-start justify-between gap-3">
                  <div class="space-y-1">
                    <div class="flex flex-wrap items-center gap-2 text-sm">
                      <span class="rounded-full bg-base-200 px-2.5 py-1 font-medium text-base-content">
                        {push_subscription_type(subscription)}
                      </span>
                      <span class="rounded-full border border-base-300 px-2.5 py-1 text-base-content/70">
                        {push_subscription_platform(subscription)}
                      </span>
                    </div>
                    <p class="font-mono text-xs break-all text-base-content/75">
                      {push_subscription_identifier(subscription)}
                    </p>
                  </div>

                  <div class="text-right text-xs text-base-content/55">
                    <p>{gettext("Updated")}: {format_push_datetime(subscription.updated_at)}</p>
                    <p>{gettext("Inserted")}: {format_push_datetime(subscription.inserted_at)}</p>
                  </div>
                </div>

                <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("ID")}
                    </dt>
                    <dd class="mt-1 font-mono text-xs text-base-content/80">{subscription.id}</dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Last Success")}
                    </dt>
                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.last_success_at)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Endpoint")}
                    </dt>
                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.endpoint)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Device Token")}
                    </dt>
                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.device_token)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Auth")}
                    </dt>
                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.auth)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("P256DH")}
                    </dt>
                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.p256dh)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Expires At")}
                    </dt>
                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.expires_at)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Last Failure")}
                    </dt>
                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.last_failure_at)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("Failure Reason")}
                    </dt>
                    <dd class="mt-1 wrap-break-word text-base-content/80">
                      {present_push_field(subscription.failure_reason)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/45">
                      {gettext("User Agent")}
                    </dt>
                    <dd class="mt-1 wrap-break-word text-base-content/80">
                      {present_push_field(subscription.user_agent)}
                    </dd>
                  </div>
                </dl>
              </article>
            </div>
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
      |> assign(:push_subscriptions, list_push_subscriptions(account))
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
        case Accounts.deliver_account_update_email_instructions(
               Ecto.Changeset.apply_action!(changeset, :insert),
               account.email,
               &url(~p"/accounts/settings/confirm-email/#{&1}")
             ) do
          {:ok, _email} ->
            info =
              gettext("A link to confirm your email change has been sent to the new address.")

            {:noreply, socket |> put_flash(:info, info)}

          error ->
            Logger.error("Update email confirmation delivery failed: #{inspect(error)}")

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "We couldn't send the confirmation email right now. Please try again later."
               )
             )}
        end

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

  def handle_event("refresh_push_subscriptions", _params, socket) do
    {:noreply,
     assign(
       socket,
       :push_subscriptions,
       list_push_subscriptions(socket.assigns.current_scope.account)
     )}
  end

  defp push_subscription_type(subscription) do
    subscription.subscription_type
    |> to_string()
    |> String.replace("_", " ")
    |> String.upcase()
  end

  defp push_subscription_platform(subscription) do
    subscription.device_platform
    |> case do
      nil -> gettext("Unknown")
      value -> value |> to_string() |> String.upcase()
    end
  end

  defp push_subscription_identifier(subscription) do
    subscription.device_token || subscription.endpoint || gettext("No identifier")
  end

  defp present_push_field(value) when is_binary(value) do
    case String.trim(value) do
      "" -> gettext("Not set")
      trimmed -> trimmed
    end
  end

  defp present_push_field(_value), do: gettext("Not set")

  defp format_push_datetime(nil), do: gettext("Never")

  defp format_push_datetime(%DateTime{} = value) do
    Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp list_push_subscriptions(account), do: Accounts.list_push_subscriptions(account)
end
