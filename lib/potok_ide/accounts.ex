defmodule PotokIde.Accounts do
  @moduledoc """
  The Accounts context.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query, warn: false

  # Devices one delivery job sends to at a time.
  @push_concurrency 16
  alias PotokIde.Repo

  alias PotokIde.Accounts.{Account, AccountNotifier, AccountToken, PushSubscription}
  alias PotokIde.PushNotifications
  alias PotokIde.Social.{AccountProfile, Profile}

  ## Database getters

  @doc """
  Gets a account by email.

  ## Examples

      iex> get_account_by_email("foo@example.com")
      %Account{}

      iex> get_account_by_email("unknown@example.com")
      nil

  """
  def get_account_by_email(email) when is_binary(email) do
    Repo.get_by(Account, email: email)
  end

  @doc """
  Gets a account by email and password.

  ## Examples

      iex> get_account_by_email_and_password("foo@example.com", "correct_password")
      %Account{}

      iex> get_account_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_account_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    account = Repo.get_by(Account, email: email)
    if Account.valid_password?(account, password), do: account
  end

  @doc """
  Gets a single account.

  Raises `Ecto.NoResultsError` if the Account does not exist.

  ## Examples

      iex> get_account!(123)
      %Account{}

      iex> get_account!(456)
      ** (Ecto.NoResultsError)

  """
  def get_account!(id), do: Repo.get!(Account, id)

  @doc "Gets a single account, or nil."
  def get_account(id), do: Repo.get(Account, id)

  ## Account registration

  @doc """
  Registers a account.

  ## Examples

      iex> register_account(%{field: value})
      {:ok, %Account{}}

      iex> register_account(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_account(attrs, invited_by_profile \\ nil)

  def register_account(attrs, %Profile{} = invited_by_profile) do
    %Account{}
    |> Account.email_changeset(attrs)
    |> Ecto.Changeset.put_change(:invited_by_id, invited_by_profile.id)
    |> Ecto.Changeset.foreign_key_constraint(:invited_by_id)
    |> Repo.insert()
  end

  def register_account(attrs, nil) do
    %Account{}
    |> Account.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Ensures an account exists for the given email and password.

  If the account already exists with the configured email, its password is
  updated to match. Accounts ensured through this flow are also confirmed so
  they do not end up in the unsupported unconfirmed-with-password state.
  """
  def ensure_account_with_password(email, password)
      when is_binary(email) and is_binary(password) do
    email = String.trim(email)

    case get_account_by_email_and_password(email, password) do
      %Account{} = account ->
        maybe_confirm_account(account)

      nil ->
        case get_account_by_email(email) do
          %Account{} = account ->
            with {:ok, {updated_account, _expired_tokens}} <-
                   update_account_password(account, %{password: password}) do
              maybe_confirm_account(updated_account)
            end

          nil ->
            with {:ok, account} <- register_account(%{email: email}),
                 {:ok, {updated_account, _expired_tokens}} <-
                   update_account_password(account, %{password: password}) do
              maybe_confirm_account(updated_account)
            end
        end
    end
  end

  @doc """
  Sets the account's current profile.

  The profile must be linked to the account through `accounts_profiles`.
  """
  def set_current_profile(%Account{} = account, %Profile{} = profile) do
    update_account_profile_reference(account, :current_profile_id, profile)
  end

  def clear_current_profile(%Account{} = account) do
    clear_account_profile_reference(account, :current_profile_id)
  end

  @doc """
  Sets the account's default profile.

  The profile must be linked to the account through `accounts_profiles`.
  """
  def set_default_profile(%Account{} = account, %Profile{} = profile) do
    update_account_profile_reference(account, :default_profile_id, profile)
  end

  def clear_default_profile(%Account{} = account) do
    clear_account_profile_reference(account, :default_profile_id)
  end

  @doc """
  Lists the saved push subscriptions for an account.
  """
  def list_push_subscriptions(%Account{} = account) do
    from(subscription in PushSubscription,
      where: subscription.account_id == ^account.id,
      order_by: [desc: subscription.updated_at]
    )
    |> Repo.all()
  end

  def list_push_subscriptions(_), do: []

  @doc """
  Stores or updates a push subscription for an account.
  """
  def upsert_push_subscription(%Account{} = account, attrs) when is_map(attrs) do
    subscription =
      attrs
      |> PushSubscription.normalize_type()
      |> find_push_subscription(attrs)

    subscription
    |> PushSubscription.changeset(attrs)
    |> Ecto.Changeset.put_change(:account_id, account.id)
    |> Repo.insert_or_update()
  end

  @doc """
  Deletes a saved push subscription for an account.
  """
  def delete_push_subscription(%Account{} = account, identifier)
      when is_binary(identifier) and identifier != "" do
    from(subscription in PushSubscription,
      where:
        subscription.account_id == ^account.id and
          (subscription.endpoint == ^identifier or subscription.device_token == ^identifier)
    )
    |> Repo.one()
    |> case do
      nil ->
        :ok

      subscription ->
        _ = Repo.delete(subscription)
        :ok
    end
  end

  def delete_push_subscription(_account, _endpoint), do: :ok

  @doc """
  Delivers a push notification payload to all saved subscriptions for an account.
  """
  def deliver_push_notification(%Account{} = account, payload) when is_map(payload) do
    account
    |> list_push_subscriptions()
    |> deliver_push_notification_to_subscriptions(payload)
  end

  @doc """
  Delivers a push notification payload to subscriptions that are already
  loaded, so a caller notifying many accounts can load them all in one query.
  """
  def deliver_push_notification_to_subscriptions([], _payload),
    do: {:error, :no_push_subscriptions}

  def deliver_push_notification_to_subscriptions(subscriptions, payload)
      when is_list(subscriptions) and is_map(payload) do
    {:ok,
     subscriptions
     |> Enum.map(&{&1, payload})
     |> send_push_batch()
     |> Enum.map(fn {_subscription, result} -> result end)}
  end

  @doc """
  Sends each `{subscription, payload}`, several at a time, and returns each
  with its result. Successes are written in one statement; an expired
  subscription is deleted and another failure written on its row.
  """
  def send_push_batch(pairs) when is_list(pairs) do
    results =
      pairs
      |> Task.async_stream(
        fn {subscription, payload} ->
          {subscription, send_push(subscription, payload)}
        end,
        max_concurrency: @push_concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    case for {%PushSubscription{id: id}, {:ok, _}} <- results, do: id do
      [] ->
        :ok

      delivered ->
        from(subscription in PushSubscription, where: subscription.id in ^delivered)
        |> Repo.update_all(
          set: [
            last_success_at: DateTime.utc_now(:second),
            last_failure_at: nil,
            failure_reason: nil
          ]
        )
    end

    results
  end

  # A success is written by the caller, together with the others.
  defp send_push(%PushSubscription{} = subscription, payload) do
    case PushNotifications.send_notification(subscription, payload) do
      {:ok, _response} ->
        {:ok, PushSubscription.identifier(subscription)}

      {:error, :expired} ->
        _ = Repo.delete(subscription)
        {:error, :expired}

      {:error, reason} ->
        subscription
        |> Ecto.Changeset.change(
          last_failure_at: DateTime.utc_now(:second),
          failure_reason: format_push_failure_reason(reason)
        )
        |> Repo.update()

        {:error, reason}
    end
  end

  @doc """
  Sends a test push notification to one of the account's saved subscriptions,
  in the language that subscription was saved with.
  """
  def send_test_push_notification(%Account{} = account, identifier \\ nil) do
    subscription =
      case identifier do
        value when is_binary(value) and value != "" ->
          from(subscription in PushSubscription,
            where:
              subscription.account_id == ^account.id and
                (subscription.endpoint == ^value or subscription.device_token == ^value),
            limit: 1
          )
          |> Repo.one()

        _ ->
          from(subscription in PushSubscription,
            where: subscription.account_id == ^account.id,
            order_by: [desc: subscription.updated_at],
            limit: 1
          )
          |> Repo.one()
      end

    case subscription do
      %PushSubscription{} = push_subscription ->
        payload =
          PushNotifications.localized(fn ->
            %{
              title: dgettext("notifications", "Potok notifications are active"),
              body: dgettext("notifications", "Push notifications are enabled for your account."),
              tag: "potok-push-test",
              url: "/accounts/settings",
              icon: "/images/pwa/icon-192.png",
              badge: "/images/pwa/icon-192.png"
            }
          end)

        deliver_push_notification_to_subscription(
          push_subscription,
          PushNotifications.payload_for(payload, push_subscription.locale)
        )

      nil ->
        {:error, :not_found}
    end
  end

  ## Settings

  @doc """
  Checks whether the account is in sudo mode.

  The account is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(account, minutes \\ -20)

  def sudo_mode?(%Account{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_account, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account email.

  See `PotokIde.Accounts.Account.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_email(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_email(account, attrs \\ %{}, opts \\ []) do
    Account.email_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account email using the given token.

  If the token matches, the account email is updated and the token is deleted.
  """
  def update_account_email(account, token) do
    context = "change:#{account.email}"

    Repo.transact(fn ->
      with {:ok, query} <- AccountToken.verify_change_email_token_query(token, context),
           %AccountToken{sent_to: email} <- Repo.one(query),
           {:ok, account} <- Repo.update(Account.email_changeset(account, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(
               from(AccountToken, where: [account_id: ^account.id, context: ^context])
             ) do
        {:ok, account}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the account password.

  See `PotokIde.Accounts.Account.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_account_password(account)
      %Ecto.Changeset{data: %Account{}}

  """
  def change_account_password(account, attrs \\ %{}, opts \\ []) do
    Account.password_changeset(account, attrs, opts)
  end

  @doc """
  Updates the account password.

  Returns a tuple with the updated account, as well as a list of expired tokens.

  ## Examples

      iex> update_account_password(account, %{password: ...})
      {:ok, {%Account{}, [...]}}

      iex> update_account_password(account, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_account_password(account, attrs) do
    account
    |> Account.password_changeset(attrs)
    |> update_account_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_account_session_token(account) do
    {token, account_token} = AccountToken.build_session_token(account)
    Repo.insert!(account_token)
    token
  end

  @doc """
  Gets the account with the given signed token.

  If the token is valid `{account, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_account_by_session_token(token) do
    {:ok, query} = AccountToken.verify_session_token_query(token)
    Repo.one(query)
  end

  defp update_account_profile_reference(%Account{} = account, field, %Profile{} = profile) do
    if account_has_profile?(account, profile) do
      account
      |> Ecto.Changeset.change([{field, profile.id}])
      |> Repo.update()
      |> broadcast_account_profile_update()
    else
      {:error, :profile_not_linked_to_account}
    end
  end

  defp clear_account_profile_reference(%Account{} = account, field) do
    account
    |> Ecto.Changeset.change([{field, nil}])
    |> Repo.update()
    |> broadcast_account_profile_update()
  end

  defp account_has_profile?(%Account{} = account, %Profile{} = profile) do
    from(ap in AccountProfile,
      where: ap.account_id == ^account.id and ap.profile_id == ^profile.id,
      select: 1
    )
    |> Repo.exists?()
  end

  defp broadcast_account_profile_update({:ok, updated_account} = ok) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      "accounts:#{updated_account.id}",
      {:account_profiles_updated, updated_account.id}
    )

    ok
  end

  defp broadcast_account_profile_update(error), do: error

  @doc """
  Gets the account with the given magic link token.
  """
  def get_account_by_magic_link_token(token) do
    with {:ok, query} <- AccountToken.verify_magic_link_token_query(token),
         {account, _token} <- Repo.one(query) do
      account
    else
      _ -> nil
    end
  end

  @doc """
  Logs the account in by magic link.

  There are three cases to consider:

  1. The account has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The account has not confirmed their email and no password is set.
     In this case, the account gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The account has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_account_by_magic_link(token) do
    {:ok, query} = AccountToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Account{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Account{confirmed_at: nil} = account, _token} ->
        account
        |> Account.confirm_changeset()
        |> update_account_and_delete_all_tokens()

      {account, token} ->
        Repo.delete!(token)
        {:ok, {account, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given account.

  ## Examples

      iex> deliver_account_update_email_instructions(account, current_email, &url(~p"/accounts/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_account_update_email_instructions(
        %Account{} = account,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, account_token} =
      AccountToken.build_email_token(account, "change:#{current_email}")

    Repo.insert!(account_token)

    AccountNotifier.deliver_update_email_instructions(
      account,
      current_email,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic link login instructions to the given account.

  An unconfirmed account gets an invitation instead, naming its inviter: the
  `:invited_by` profile, or else the profile that registered the account.

  ## Options

    * `:invited_by` - the profile inviting the account
    * `:group` - the group the account is invited to
  """
  def deliver_login_instructions(%Account{} = account, magic_link_url_fun, opts \\ [])
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, account_token} = AccountToken.build_email_token(account, "login")
    Repo.insert!(account_token)

    web_url = to_string(magic_link_url_fun.(encoded_token))

    AccountNotifier.deliver_login_instructions(
      account,
      web_url,
      build_magic_link_app_url(web_url),
      invitation_details(account, opts)
    )
  end

  @doc """
  Emails an account in use that `inviter` invites it, into `group`, or to
  Potok when there is none. It holds no link to sign in.
  """
  def deliver_invitation_notice(%Account{} = account, %Profile{username: inviter}, nil),
    do: AccountNotifier.deliver_potok_invitation(account, inviter)

  def deliver_invitation_notice(%Account{} = account, %Profile{username: inviter}, group),
    do: AccountNotifier.deliver_group_invitation(account, inviter, group.name)

  defp invitation_details(%Account{confirmed_at: nil} = account, opts) do
    inviter =
      cond do
        opts[:invited_by] -> opts[:invited_by]
        account.invited_by_id -> Repo.get(Profile, account.invited_by_id)
        true -> nil
      end

    [
      inviter: inviter && inviter.username,
      group: opts[:group] && opts[:group].name
    ]
  end

  defp invitation_details(%Account{}, _opts), do: []

  ## Deleting an account

  @doc "What deleting the account would do (`PotokIde.Accounts.Deletion.preview/1`)."
  defdelegate deletion_preview(account), to: PotokIde.Accounts.Deletion, as: :preview

  @doc """
  Deletes the account (`PotokIde.Accounts.Deletion.delete/1`) and sends a last
  email to its address. Returns `{:ok, tokens}` with the tokens whose sessions
  the caller disconnects, or `{:error, {:blocked, groups}}`.
  """
  def delete_account(%Account{} = account) do
    with {:ok, %{email: email, tokens: tokens}} <- PotokIde.Accounts.Deletion.delete(account) do
      _ = AccountNotifier.deliver_account_deleted(email)
      {:ok, tokens}
    end
  end

  @doc """
  Sends the link that deletes the account to its address. It works for
  #{AccountToken.delete_validity_in_minutes()} minutes.
  """
  def deliver_account_deletion_instructions(%Account{} = account, url_fun)
      when is_function(url_fun, 1) do
    {encoded_token, account_token} = AccountToken.build_email_token(account, "delete")
    Repo.insert!(account_token)
    AccountNotifier.deliver_deletion_instructions(account, url_fun.(encoded_token))
  end

  @doc "The account a link that deletes it belongs to, or nil."
  def get_account_by_deletion_token(token) when is_binary(token) do
    with {:ok, query} <- AccountToken.verify_delete_token_query(token),
         {account, _token} <- Repo.one(query) do
      account
    else
      _ -> nil
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_account_session_token(token) do
    Repo.delete_all(from(AccountToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Deletes the tokens no check accepts any more: sessions older than
  #{AccountToken.session_validity_in_days()} days (a session is reissued every week and the
  old token stays until then), sign-in links and links to confirm a new
  address older than the longest they last, links that delete an account older
  than an hour. Returns how many went.
  """
  def delete_expired_tokens do
    session_days = AccountToken.session_validity_in_days()

    link_days =
      max(
        AccountToken.invitation_validity_in_days(),
        AccountToken.change_email_validity_in_days()
      )

    {deleted, _} =
      from(t in AccountToken,
        # Every expired token is at least this old: the index on inserted_at.
        where: t.inserted_at < ago(^min(session_days, link_days), "day"),
        where:
          (t.context == "session" and t.inserted_at < ago(^session_days, "day")) or
            ((t.context == "login" or like(t.context, "change:%")) and
               t.inserted_at < ago(^link_days, "day"))
      )
      |> Repo.delete_all()

    {deleting, _} =
      from(t in AccountToken,
        where:
          t.context == "delete" and
            t.inserted_at < ago(^AccountToken.delete_validity_in_minutes(), "minute")
      )
      |> Repo.delete_all()

    deleted + deleting
  end

  defp build_magic_link_app_url(%URI{} = uri) do
    build_magic_link_app_url(URI.to_string(uri))
  end

  defp build_magic_link_app_url(web_url) when is_binary(web_url) do
    uri = URI.parse(web_url)

    query =
      uri.query
      |> case do
        nil -> %{}
        value -> URI.decode_query(value)
      end
      |> Map.put("app", "1")
      |> URI.encode_query()

    %URI{uri | query: query}
    |> URI.to_string()
  end

  defp deliver_push_notification_to_subscription(%PushSubscription{} = subscription, payload) do
    case PushNotifications.send_notification(subscription, payload) do
      {:ok, _response} ->
        now = DateTime.utc_now(:second)

        subscription
        |> Ecto.Changeset.change(
          last_success_at: now,
          last_failure_at: nil,
          failure_reason: nil
        )
        |> Repo.update()

        {:ok, PushSubscription.identifier(subscription)}

      {:error, :expired} ->
        _ = Repo.delete(subscription)
        {:error, :expired}

      {:error, reason} ->
        now = DateTime.utc_now(:second)

        subscription
        |> Ecto.Changeset.change(
          last_failure_at: now,
          failure_reason: format_push_failure_reason(reason)
        )
        |> Repo.update()

        {:error, reason}
    end
  end

  defp format_push_failure_reason({type, detail}), do: "#{type}: #{detail}"
  defp format_push_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_push_failure_reason(reason), do: inspect(reason)

  defp maybe_confirm_account(%Account{confirmed_at: nil} = account) do
    account
    |> Account.confirm_changeset()
    |> Repo.update()
  end

  defp maybe_confirm_account(%Account{} = account), do: {:ok, account}

  defp find_push_subscription(:fcm, attrs) do
    device_token = Map.get(attrs, :device_token) || Map.get(attrs, "device_token")

    if is_binary(device_token) and device_token != "" do
      Repo.get_by(PushSubscription, device_token: device_token) || %PushSubscription{}
    else
      %PushSubscription{}
    end
  end

  defp find_push_subscription(:web_push, attrs) do
    endpoint = Map.get(attrs, :endpoint) || Map.get(attrs, "endpoint")

    if is_binary(endpoint) and endpoint != "" do
      Repo.get_by(PushSubscription, endpoint: endpoint) || %PushSubscription{}
    else
      %PushSubscription{}
    end
  end

  ## Token helper

  defp update_account_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, account} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(AccountToken, account_id: account.id)

        Repo.delete_all(
          from(t in AccountToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {account, tokens_to_expire}}
      end
    end)
  end
end
