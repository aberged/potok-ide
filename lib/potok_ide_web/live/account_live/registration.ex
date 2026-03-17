defmodule PotokIdeWeb.AccountLive.Registration do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            {gettext("Register for an account")}
            <:subtitle>
              {gettext("Already registered?")}
              <.link navigate={~p"/accounts/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Log in")}
              </.link>
              {gettext("to your account now.")}
            </:subtitle>
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

          <.button phx-disable-with={gettext("Creating account...")} class="btn btn-primary w-full">
            {gettext("Create an account")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{account: account}}} = socket)
      when not is_nil(account) do
    {:ok, redirect(socket, to: PotokIdeWeb.AccountAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_account_email(%Account{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"account" => account_params}, socket) do
    case Accounts.register_account(account_params) do
      {:ok, account} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            account,
            &url(~p"/accounts/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "An email was sent to %{email}, please access it to confirm your account.",
             email: account.email
           )
         )
         |> push_navigate(to: ~p"/accounts/log-in")}

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
