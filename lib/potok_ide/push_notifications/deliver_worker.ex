defmodule PotokIde.PushNotifications.DeliverWorker do
  @moduledoc """
  Delivers one push notification to up to 500 accounts, as a job in Postgres
  (Oban, queue `push`): it outlives a deploy, and a job that fails as a
  whole (the push service unreachable) is tried again.

  Args: `account_ids`, `payload` (`PotokIde.PushNotifications.localized/1`:
  the payload per language), `context` and `context_id`, for the log. The
  subscriptions are read when the job runs, every device gets the payload in
  its language, and the successes are written in one statement
  (`PotokIde.Accounts.send_push_batch/1`). A job that runs after the
  payload's `expires_at` sends nothing.
  """

  use Oban.Worker, queue: :push, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PotokIde.Accounts
  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.PushNotifications
  alias PotokIde.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payload" => payload} = args}) do
    # Past its `expires_at` (a job that waited, or was tried again too late)
    # nobody needs it any more: a reminder after its event started.
    if PushNotifications.stale?(payload), do: :ok, else: deliver(args)
  end

  defp deliver(%{"account_ids" => account_ids, "payload" => payload} = args) do
    pairs =
      from(subscription in PushSubscription,
        where: subscription.account_id in ^account_ids,
        order_by: [asc: subscription.account_id, desc: subscription.updated_at]
      )
      |> Repo.all()
      |> Enum.map(&{&1, PushNotifications.payload_for(payload, &1.locale)})

    results = Accounts.send_push_batch(pairs)

    failures =
      for {%PushSubscription{account_id: account_id}, {:error, reason}} <- results,
          reason != :expired do
        Logger.warning(
          "Push delivery failed for account #{account_id} (#{args["context"]}#{format_context_id(args["context_id"])}): #{inspect(reason)}"
        )

        reason
      end

    # Tried again only when nothing went out, so nobody gets it twice.
    if failures != [] and not Enum.any?(results, &match?({_subscription, {:ok, _}}, &1)),
      do: {:error, {:nothing_delivered, hd(failures)}},
      else: :ok
  end

  defp format_context_id(nil), do: ""
  defp format_context_id(context_id), do: " #{context_id}"
end
