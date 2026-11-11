defmodule PotokIdeWeb.AccountLive.Settings do
  use PotokIdeWeb, :live_view

  # on_mount {PotokIdeWeb.AccountAuth, :require_sudo_mode}

  require Logger

  alias PotokIde.Accounts
  alias PotokIde.Notices
  alias PotokIde.PushNotifications
  alias PotokIde.RateLimit
  alias PotokIdeWeb.NoticeComponents
  alias PotokIdeWeb.RateLimited

  # The cards of the page, like those of the group settings tabs.
  defp settings_card_class,
    do: "rounded-3xl border border-base-300/70 bg-base-100/80 p-4 shadow-sm sm:p-5"

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
      unread_notices_count={@unread_notices_count}
      full_width
    >
      <.page_container id="settings-page" class="space-y-4">
        <.page_header id="settings-header" icon="hero-cog-6-tooth" class="mb-1">
          {gettext("Account Settings")}
          <:subtitle>
            {gettext("Manage your account email address and password settings")}
          </:subtitle>
        </.page_header>

        <section id="settings-email" class={settings_card_class()}>
          <.card_title
            icon="hero-envelope"
            title={gettext("Email")}
            subtitle={gettext("The address you log in with.")}
            class="mb-4"
          />
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              readonly
              class="input w-full bg-base-200 text-base-content/70"
            />
            <%!-- <.button variant="primary" phx-disable-with={gettext("Changing...")}>
            {gettext("Change Email")}
          </.button> --%>
          </.form>
        </section>

        <section id="settings-password" class={settings_card_class()}>
          <.card_title
            icon="hero-key"
            title={gettext("Password")}
            subtitle={gettext("Set a password to log in without a link from your email.")}
            class="mb-4"
          />
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
            <div class="mt-2 flex justify-end">
              <.button variant="primary" phx-disable-with={gettext("Saving...")}>
                {gettext("Save Password")}
              </.button>
            </div>
          </.form>
        </section>
        <section
          id="push-notifications-panel"
          phx-hook="PushNotifications"
          phx-update="ignore"
          data-vapid-public-key={@push_vapid_public_key || ""}
          data-subscribe-url={~p"/accounts/push-subscriptions"}
          data-test-url={~p"/accounts/push-subscriptions/test"}
          data-i18n={Jason.encode!(push_i18n())}
          class={settings_card_class()}
        >
          <div class="space-y-4">
            <.card_title
              icon="hero-bell"
              title={gettext("Push Notifications")}
              subtitle={
                gettext(
                  "Enable notifications for this browser or for the installed Potok app on your device."
                )
              }
            />

            <div
              data-push-status
              aria-live="polite"
              class="rounded-2xl border border-base-300 bg-base-200/70 px-4 py-3 text-sm text-base-content/70"
            >
              {gettext("Checking browser support...")}
            </div>

            <div class="flex flex-wrap gap-3">
              <.button type="button" data-push-enable variant="primary">
                {gettext("Enable notifications")}
              </.button>
              <.button type="button" data-push-test hidden>
                {gettext("Send test notification")}
              </.button>
              <.button type="button" data-push-disable hidden>
                {gettext("Disable")}
              </.button>
            </div>

            <p class="text-xs text-base-content/65">
              {gettext(
                "Browser push requires an active service worker and HTTPS outside localhost. The installed Potok app uses native device permissions and Firebase Cloud Messaging."
              )}
            </p>
          </div>
        </section>

        <%!-- The profile's switch for every notice of the groups it follows;
             each follow has its own on the Notices page. --%>
        <section id="notice-push-settings" class={settings_card_class()}>
          <div class="space-y-3">
            <.card_title
              icon="hero-bell-alert"
              title={gettext("Notices of followed groups")}
              subtitle={
                gettext(
                  "For the profile %{profile}. Each followed group also has its own switch, on the Notices page.",
                  profile: @current_profile.username
                )
              }
            />
            <NoticeComponents.push_switch
              id="notice-push-toggle"
              checked={@current_profile.notice_push}
              label={gettext("Push notifications for notices")}
              phx-click="toggle_notice_push"
              phx-value-push={to_string(!@current_profile.notice_push)}
            />
            <p class="text-xs text-base-content/65">
              {gettext("It holds for every device of every account that uses this profile.")}
            </p>
          </div>
        </section>

        <section
          id="push-subscriptions-panel"
          class={settings_card_class()}
        >
          <%!-- For working out why a device gets no notifications. --%>
          <details
            id="push-subscriptions-details"
            phx-mounted={JS.ignore_attributes(["open"])}
            class="group/details space-y-4"
          >
            <summary class="flex cursor-pointer list-none items-start gap-3 [&::-webkit-details-marker]:hidden">
              <.card_title
                icon="hero-device-phone-mobile"
                title={gettext("Stored Push Subscriptions")}
                subtitle={gettext("All saved push subscription entities for this account.")}
                class="flex-1"
              />
              <.icon
                name="hero-chevron-down"
                class="mt-1 size-4 shrink-0 text-base-content/65 transition-transform duration-150 group-open/details:rotate-180"
              />
            </summary>

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

                  <div class="text-right text-xs text-base-content/65">
                    <p>{gettext("Updated")}: {format_push_datetime(subscription.updated_at)}</p>

                    <p>{gettext("Inserted")}: {format_push_datetime(subscription.inserted_at)}</p>
                  </div>
                </div>

                <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("ID")}
                    </dt>

                    <dd class="mt-1 font-mono text-xs text-base-content/80">{subscription.id}</dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Last Success")}
                    </dt>

                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.last_success_at)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Endpoint")}
                    </dt>

                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.endpoint)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Device Token")}
                    </dt>

                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.device_token)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Auth")}
                    </dt>

                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.auth)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("P256DH")}
                    </dt>

                    <dd class="mt-1 font-mono text-xs break-all text-base-content/80">
                      {present_push_field(subscription.p256dh)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Expires At")}
                    </dt>

                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.expires_at)}
                    </dd>
                  </div>

                  <div>
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Last Failure")}
                    </dt>

                    <dd class="mt-1 text-base-content/80">
                      {format_push_datetime(subscription.last_failure_at)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("Failure Reason")}
                    </dt>

                    <dd class="mt-1 wrap-break-word text-base-content/80">
                      {present_push_field(subscription.failure_reason)}
                    </dd>
                  </div>

                  <div class="sm:col-span-2">
                    <dt class="text-xs font-medium uppercase tracking-wide text-base-content/65">
                      {gettext("User Agent")}
                    </dt>

                    <dd class="mt-1 wrap-break-word text-base-content/80">
                      {present_push_field(subscription.user_agent)}
                    </dd>
                  </div>
                </dl>
              </article>
            </div>
          </details>
        </section>

        <section id="settings-preferences" class={settings_card_class()}>
          <.card_title
            icon="hero-language"
            title={gettext("Preferences")}
            subtitle={gettext("The language and the look of the app.")}
            class="mb-4"
          />
          <div class="flex flex-wrap items-center gap-3">
            <Layouts.locale_switcher
              current_locale={@current_locale}
              available_locales={@available_locales}
            />
            <Layouts.theme_toggle />
          </div>
        </section>
      </.page_container>
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

    changeset = Accounts.change_account_email(account, account_params)

    with true <- changeset.valid?,
         :ok <- RateLimit.hit(:email_change, account.id) do
      send_email_change(socket, account, changeset)
    else
      false ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}

      {:error, :rate_limited, retry_after} ->
        {:noreply, put_flash(socket, :error, RateLimited.message(retry_after))}
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

  def handle_event("toggle_notice_push", %{"push" => push}, socket) do
    {:ok, profile} = Notices.set_notice_push(socket.assigns.current_profile, push == "true")
    {:noreply, assign(socket, :current_profile, profile)}
  end

  def handle_event("refresh_push_subscriptions", _params, socket) do
    {:noreply,
     assign(
       socket,
       :push_subscriptions,
       list_push_subscriptions(socket.assigns.current_scope.account)
     )}
  end

  defp send_email_change(socket, account, changeset) do
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
           gettext("We couldn't send the confirmation email right now. Please try again later.")
         )}
    end
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

  # The messages of the `PushNotifications` hook in app.js.
  defp push_i18n do
    %{
      browserPermissionBlocked: gettext("Browser permission for notifications is blocked."),
      browserUnavailable: gettext("Push notifications are unavailable in this browser session."),
      devicePermissionBlocked: gettext("Device notification permission is blocked."),
      disabledForBrowser: gettext("Push notifications are disabled for this browser."),
      disabledForDevice: gettext("Push notifications are disabled for this device."),
      enableBeforeTest: gettext("Enable notifications before sending a test push."),
      enableFailed: gettext("Unable to enable push notifications."),
      enabled: gettext("Push notifications are enabled."),
      fcmUnavailable:
        gettext(
          "FCM is unavailable on this device right now. Ensure Google Play services are installed and updated, verify network access to Google services, then try again."
        ),
      finishingIphone: gettext("Finishing iPhone notification registration..."),
      nativeUnavailable:
        gettext("Native push notifications are unavailable in this app session."),
      notConfigured: gettext("Push notifications are not configured on this server yet."),
      permissionNotGranted: gettext("Notification permission was not granted."),
      playServicesMissing:
        gettext(
          "Google Play services are missing or outdated on this device, so push registration cannot complete."
        ),
      refreshingToken: gettext("Refreshing device notification token..."),
      registerFailed: gettext("Unable to register this device for push notifications."),
      removeFailed: gettext("Unable to remove the push subscription."),
      removingSubscription: gettext("Removing push subscription..."),
      removingToken: gettext("Removing device notification token..."),
      requestFailed: gettext("Push notification request failed."),
      requestingDevicePermission: gettext("Requesting device notification permission..."),
      requestingPermission: gettext("Requesting notification permission..."),
      requiresHttps: gettext("Push notifications require HTTPS or localhost."),
      saveFailed:
        gettext(
          "Push notifications are active on this device but Potok could not save the token."
        ),
      sendingTest: gettext("Sending test notification..."),
      testFailed: gettext("Unable to send the test notification."),
      testSentNative:
        gettext(
          "Test notification sent. Background the app if Android suppresses foreground banners."
        ),
      testSentWeb:
        gettext(
          "Test notification sent. Minimize the app if the browser suppresses foreground notifications."
        ),
      webPushUnsupported: gettext("This browser does not support Web Push notifications.")
    }
  end
end
