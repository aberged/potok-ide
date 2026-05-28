defmodule PotokIdeWeb.AccountLive.Registration do
  use PotokIdeWeb, :live_view

  require Logger

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account

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
      <div class="mx-auto max-w-sm px-6 pt-4">
        <div class="text-center">
          <.header>
            {gettext("Invite people to potok by email")}
            <%!-- <:subtitle>
              {gettext("Already registered?")}
              <.link navigate={~p"/accounts/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Log in")}
              </.link>
              {gettext("to your account now.")}
            </:subtitle> --%>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with={gettext("Sending invitation...")} class="btn btn-primary w-full">
            {gettext("Invite")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  # def mount(_params, _session, %{assigns: %{current_scope: %{account: account}}} = socket)
  #     when not is_nil(account) do
  #   {:ok, redirect(socket, to: PotokIdeWeb.AccountAuth.signed_in_path(socket))}
  # end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_account_email(%Account{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"account" => account_params}, socket) do
    case Accounts.register_account(account_params, socket.assigns.current_profile) do
      {:ok, account} ->
        case Accounts.deliver_login_instructions(
               account,
               &url(~p"/accounts/log-in/#{&1}")
             ) do
          {:ok, _email} ->
            {
              :noreply,
              socket
              |> put_flash(
                :info,
                gettext(
                  "An invitation email was sent to %{email}",
                  email: account.email
                )
              )
              # |> push_navigate(to: ~p"/accounts/log-in")
            }

          error ->
            Logger.error("Invitation email delivery failed: #{inspect(error)}")

            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("We couldn't send the invitation email right now. Please try again later.")
             )}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset = Accounts.change_account_email(%Account{}, account_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "account")
    assign(socket, form: form)
  end
end
