defmodule PotokIde.PushNotifications.Dispatch do
  @moduledoc """
  Sends notifications to many accounts: off the caller, with the
  subscriptions of every account loaded in one query and several accounts
  served at a time, so a notification for a big group does not trickle out
  one account after another.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PotokIde.Accounts
  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.Repo

  @account_concurrency 8

  @doc """
  Runs `fun` off the caller (usually a LiveView process), so the UI responds
  while the push services are called. Tests run it inline so they can assert
  on the requests deterministically.
  """
  def run(fun) when is_function(fun, 0) do
    if Application.get_env(:potok_ide, :async_notifications, true) do
      {:ok, _pid} = Task.Supervisor.start_child(PotokIde.TaskSupervisor, fun)
      :ok
    else
      fun.()
      :ok
    end
  end

  @doc """
  The push subscriptions of the accounts selected by `account_ids` (a query
  selecting account ids), as one list per account, newest first. Accounts
  without a subscribed device cost nothing.
  """
  def subscriptions_by_account(account_ids) do
    from(subscription in PushSubscription,
      where: subscription.account_id in subquery(account_ids),
      order_by: [asc: subscription.account_id, desc: subscription.updated_at]
    )
    |> Repo.all()
    |> Enum.chunk_by(& &1.account_id)
  end

  @doc """
  Delivers to every account of `subscriptions_by_account`, several accounts
  at a time. `payload_fun` gets an account's subscriptions and returns
  `{payload, context}`, or nil to skip the account.
  """
  def deliver_each(subscriptions_by_account, context_id, payload_fun)
      when is_function(payload_fun, 1) do
    subscriptions_by_account
    |> Task.async_stream(
      fn [%PushSubscription{account_id: account_id} | _] = subscriptions ->
        case payload_fun.(subscriptions) do
          {payload, context} -> deliver(subscriptions, account_id, payload, context, context_id)
          nil -> :ok
        end
      end,
      max_concurrency: @account_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  @doc """
  Like `deliver_each/3`, but every device gets the payload in the language
  it saved its subscription with: `payload_for` gets that locale (nil for
  devices that saved none) and returns the payload.
  """
  def deliver_localized(subscriptions_by_account, context, context_id, payload_for)
      when is_function(payload_for, 1) do
    subscriptions_by_account
    |> Task.async_stream(
      fn [%PushSubscription{account_id: account_id} | _] = subscriptions ->
        subscriptions
        |> Enum.group_by(& &1.locale)
        |> Enum.each(fn {locale, same_locale} ->
          deliver(same_locale, account_id, payload_for.(locale), context, context_id)
        end)
      end,
      max_concurrency: @account_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  @doc """
  Delivers `payload` to an account's subscriptions; failures are logged
  (expired subscriptions are removed by `Accounts`).
  """
  def deliver(subscriptions, account_id, payload, context, context_id) do
    case Accounts.deliver_push_notification_to_subscriptions(subscriptions, payload) do
      {:ok, _results} ->
        :ok

      {:error, :no_push_subscriptions} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Push delivery failed for account #{account_id} (#{context}#{format_context_id(context_id)}): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_context_id(nil), do: ""
  defp format_context_id(context_id), do: " #{context_id}"
end
