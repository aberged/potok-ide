defmodule PotokIde.PushNotifications.Dispatch do
  @moduledoc """
  Sends notifications to many accounts. Who gets one, and in which words, is
  worked out off the caller (`run/1`); the sending itself goes into jobs of
  up to 500 accounts each (`PotokIde.PushNotifications.DeliverWorker`, Oban
  queue `push`), which outlive a deploy and are tried again when nothing
  went out.
  """

  import Ecto.Query, only: [from: 2]

  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.PushNotifications.DeliverWorker
  alias PotokIde.Repo

  @batch 500

  @doc """
  Runs `fun` off the caller (usually a LiveView process), so the UI responds
  while recipients are worked out. At most a few run at once
  (`PotokIde.PushNotifications.Fanout`); past that the caller runs it, which
  slows a burst instead of piling it up. Tests run it inline so they can
  assert on the requests deterministically.
  """
  def run(fun) when is_function(fun, 0) do
    if Application.get_env(:potok_ide, :async_notifications, true) do
      case Task.Supervisor.start_child(PotokIde.PushNotifications.Fanout, fun) do
        {:ok, _pid} -> :ok
        {:error, _full} -> run_here(fun)
      end
    else
      run_here(fun)
    end
  end

  defp run_here(fun) do
    fun.()
    :ok
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
  Sends to every account of `subscriptions_by_account`. `payload_fun` gets an
  account's subscriptions and returns `{payload, context}` (`payload` from
  `PotokIde.PushNotifications.localized/1`), or nil to skip the account.
  Accounts with the same payload go out in the same jobs.
  """
  def deliver_each(subscriptions_by_account, context_id, payload_fun)
      when is_function(payload_fun, 1) do
    subscriptions_by_account
    |> Enum.flat_map(fn [%PushSubscription{account_id: account_id} | _] = subscriptions ->
      case payload_fun.(subscriptions) do
        {payload, context} -> [{{payload, context}, account_id}]
        nil -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {{payload, context}, account_ids} ->
      enqueue(account_ids, payload, context, context_id)
    end)
  end

  @doc "`deliver_each/3` with the same payload for every account."
  def deliver_localized(subscriptions_by_account, context, context_id, payload) do
    deliver_each(subscriptions_by_account, context_id, fn _subscriptions -> {payload, context} end)
  end

  @doc "Sends `payload` to one account's subscriptions."
  def deliver([], _account_id, _payload, _context, _context_id), do: :ok

  def deliver(_subscriptions, account_id, payload, context, context_id),
    do: enqueue([account_id], payload, context, context_id)

  @doc """
  Puts the sending of `payload` to `account_ids` into jobs of up to
  #{@batch} accounts, in one insert.
  """
  def enqueue(account_ids, payload, context, context_id) do
    account_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@batch)
    |> Enum.map(fn batch ->
      DeliverWorker.new(%{
        account_ids: batch,
        payload: payload,
        context: context,
        context_id: context_id
      })
    end)
    |> case do
      [] -> :ok
      jobs -> Oban.insert_all(jobs) && :ok
    end
  end
end
