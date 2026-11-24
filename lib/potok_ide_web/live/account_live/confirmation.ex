defmodule PotokIdeWeb.AccountLive.Confirmation do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  @impl true
  def render(%{welcome: true} = assigns) do
    ~H"""
    <Layouts.guest
      flash={@flash}
      current_locale={@current_locale}
      available_locales={@available_locales}
      about_link={!@current_scope}
      centered
    >
      <%!-- What the invitation is, behind the modal that answers it. --%>
      <Layouts.guest_card
        id="welcome-card"
        image={@invitation && Avatars.group_avatar_url(@invitation.group)}
        title={if @invitation, do: @invitation.group.name, else: gettext("Welcome!")}
        subtitle={welcome_subtitle(@invitation, @account)}
      >
        <.button
          id="welcome-open"
          type="button"
          phx-click="welcome_open"
          variant="landing"
          class="w-full"
        >
          {gettext("Create your profile")}
        </.button>
      </Layouts.guest_card>

      <ProfileComponents.welcome_dialog
        :if={@welcome_open}
        form={@profile_form}
        invitation={@invitation}
        remember_me={@remember_me}
        button_variant="landing"
      />

      <%!-- The log-in itself, once the profile is made: a plain POST, as only
           a request sets the session's cookie. --%>
      <.form
        for={%{}}
        as={:account}
        id="welcome-login-form"
        action={~p"/accounts/log-in?_action=welcome"}
        phx-trigger-action={@trigger_submit}
        class="hidden"
      >
        <input type="hidden" name="account[token]" value={@token} />
        <input type="hidden" name="account[remember_me]" value={to_string(@remember_me)} />
        <input :if={@group_id} type="hidden" name="account[group_id]" value={@group_id} />
      </.form>
    </Layouts.guest>
    """
  end

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

  # An account with no profile yet, most often one an invitation opened, gets
  # the modal that makes its first profile (`welcome_dialog/1`) and, with the
  # invitation, goes into its group. The link is spent only by the button, so
  # a mail scanner that opens it spends nothing.
  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if account = Accounts.get_account_by_magic_link_token(token) do
      if Social.account_has_profiles?(account) do
        form = to_form(%{"token" => token}, as: "account")
        auto_submit = authenticated_account?(socket)

        {:ok,
         assign(socket,
           welcome: false,
           account: account,
           form: form,
           trigger_submit: auto_submit,
           auto_submit: auto_submit
         ), temporary_assigns: [form: nil]}
      else
        {:ok,
         assign(socket,
           welcome: true,
           account: account,
           token: token,
           invitation: Social.first_pending_account_invitation(account),
           profile_form: ProfileComponents.welcome_form(),
           welcome_open: true,
           remember_me: true,
           group_id: nil,
           trigger_submit: false
         )}
      end
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

  def handle_event("welcome_open", _params, socket),
    do: {:noreply, assign(socket, :welcome_open, true)}

  def handle_event("welcome_close", _params, socket),
    do: {:noreply, assign(socket, :welcome_open, false)}

  def handle_event("validate_profile", params, socket) do
    {:noreply,
     assign(socket,
       profile_form: ProfileComponents.welcome_form(params["profile"] || %{}, :validate),
       remember_me: params["remember_me"] == "true"
     )}
  end

  # The profile first, so a taken name shows here; then the log-in.
  def handle_event("create_profile", params, socket) do
    attrs = ProfileComponents.welcome_attrs(params["profile"] || %{})
    socket = assign(socket, :remember_me, params["remember_me"] == "true")

    case Social.create_profile_from_invitation(socket.assigns.account, attrs) do
      {:ok, _profile, group} ->
        {:noreply, assign(socket, group_id: group && group.id, trigger_submit: true)}

      {:error, %Ecto.Changeset{data: %Profile{}} = changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create the profile."))}
    end
  end

  defp welcome_subtitle(%{inviter: %{username: username}}, _account) when is_binary(username),
    do: gettext("@%{username} invites you to this group on Potok.", username: username)

  defp welcome_subtitle(_invitation, account), do: account.email

  defp authenticated_account?(socket) do
    match?(%_{account: %{}}, socket.assigns.current_scope)
  end
end
