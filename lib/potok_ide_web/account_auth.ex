defmodule PotokIdeWeb.AccountAuth do
  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Scope
  alias PotokIde.Social

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in AccountToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_potok_ide_web_account_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the account in.

  Redirects to the session's `:account_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_account(conn, account, params \\ %{}) do
    account_return_to = get_session(conn, :account_return_to)

    conn
    |> create_or_extend_session(account, params)
    |> redirect(to: account_return_to || signed_in_path(conn, account))
  end

  @doc """
  Logs the account out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_account(conn) do
    account_token = get_session(conn, :account_token)
    account_token && Accounts.delete_account_session_token(account_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      PotokIdeWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the account by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  def fetch_current_scope_for_account(conn, _opts) do
    with {token, conn} <- ensure_account_token(conn),
         {account, token_inserted_at} <- Accounts.get_account_by_session_token(token) do
      current_profile = current_profile_for_account(account)

      conn
      |> assign(:current_scope, Scope.for_account(account))
      |> assign(:current_profile, current_profile)
      |> assign(
        :pending_invitations_count,
        pending_invitations_count_for_profile(current_profile)
      )
      |> maybe_reissue_account_session_token(account, token_inserted_at)
    else
      nil ->
        conn
        |> assign(:current_scope, Scope.for_account(nil))
        |> assign(:current_profile, nil)
        |> assign(:pending_invitations_count, 0)
    end
  end

  defp ensure_account_token(conn) do
    if token = get_session(conn, :account_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:account_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_account_session_token(conn, account, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, account, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, account, params) do
    token = Accounts.generate_account_session_token(account)
    remember_me = get_session(conn, :account_remember_me)

    conn
    |> renew_session(account)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the account is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, account) when conn.assigns.current_scope.account.id == account.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _account) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _account) do
    delete_csrf_token()

    locale = get_session(conn, :locale)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> maybe_put_locale(locale)
  end

  defp maybe_put_locale(conn, nil), do: conn
  defp maybe_put_locale(conn, locale), do: put_session(conn, :locale, locale)

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:account_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:account_token, token)
    |> put_session(:live_socket_id, account_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      PotokIdeWeb.Endpoint.broadcast(account_session_topic(token), "disconnect", %{})
    end)
  end

  defp account_session_topic(token), do: "accounts_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on account_token, or nil if
      there's no account_token or no matching account.

    * `:require_authenticated` - Authenticates the account from the session,
      and assigns the current_scope to socket assigns based
      on account_token.
      Redirects to login page if there's no logged account.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule PotokIdeWeb.PageLive do
        use PotokIdeWeb, :live_view

        on_mount {PotokIdeWeb.AccountAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{PotokIdeWeb.AccountAuth, :require_authenticated}] do
        live "/profile", ProfileLive, :index
      end
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.account do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, gettext("You must log in to access this page."))
        |> Phoenix.LiveView.redirect(to: ~p"/accounts/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.account, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("You must re-authenticate to access this page.")
        )
        |> Phoenix.LiveView.redirect(to: ~p"/accounts/log-in")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    socket =
      Phoenix.Component.assign_new(socket, :current_scope, fn ->
        {account, _} =
          if account_token = session["account_token"] do
            Accounts.get_account_by_session_token(account_token)
          end || {nil, nil}

        Scope.for_account(account)
      end)

    Phoenix.Component.assign_new(socket, :current_profile, fn ->
      current_profile_for_scope(socket.assigns[:current_scope])
    end)
    |> Phoenix.Component.assign_new(:pending_invitations_count, fn ->
      pending_invitations_count_for_profile(socket.assigns[:current_profile])
    end)
  end

  defp current_profile_for_scope(%Scope{account: %Accounts.Account{} = account}),
    do: current_profile_for_account(account)

  defp current_profile_for_scope(_), do: nil

  defp current_profile_for_account(%Accounts.Account{} = account),
    do: Social.get_account_current_profile(account)

  defp current_profile_for_account(_), do: nil

  defp pending_invitations_count_for_profile(nil), do: 0

  defp pending_invitations_count_for_profile(profile),
    do: Social.count_pending_invitations(profile)

  @doc "Returns the path to redirect to after log in."
  # the account was already logged in, redirect to settings
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{account: %Accounts.Account{}}}}) do
    ~p"/accounts/settings"
  end

  def signed_in_path(%Phoenix.LiveView.Socket{assigns: %{current_profile: current_profile}})
      when not is_nil(current_profile) do
    ~p"/groups"
  end

  def signed_in_path(%Phoenix.LiveView.Socket{
        assigns: %{current_scope: %Scope{account: %Accounts.Account{}}}
      }) do
    ~p"/profiles"
  end

  def signed_in_path(_), do: ~p"/profiles"

  defp signed_in_path(
         %Plug.Conn{assigns: %{current_scope: %Scope{account: %Accounts.Account{}}}},
         _account
       ) do
    ~p"/accounts/settings"
  end

  defp signed_in_path(_, %Accounts.Account{current_profile_id: nil}), do: ~p"/profiles"
  defp signed_in_path(_, %Accounts.Account{}), do: ~p"/groups"

  @doc """
  Plug for routes that require the account to be authenticated.
  """
  def require_authenticated_account(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.account do
      conn
    else
      conn
      |> put_flash(:error, gettext("You must log in to access this page."))
      |> maybe_store_return_to()
      |> redirect(to: ~p"/accounts/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :account_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
