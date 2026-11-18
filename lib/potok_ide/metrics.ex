defmodule PotokIde.Metrics do
  @moduledoc """
  What the app measures of itself beyond what Phoenix, Ecto and the VM report:
  the size of what grows with the people online (presences, PubSub
  subscriptions, cache entries), the mailboxes of the app's named processes,
  the push queue and how late the drawn processes run.

  `PotokIdeWeb.Telemetry` runs these on a poller and a `Peep` worker
  (`peep/0`) keeps the numbers; on a deploy they are served in Prometheus'
  text format on a private port (`:metrics_port`, see `PotokIde.Application`),
  which Fly reads (`[metrics]` in `fly.toml`). Every measurement survives a
  process or table that is not there (yet): the poller drops one that raises.
  """

  import Ecto.Query

  alias PotokIde.Processes.ValueProcess
  alias PotokIde.Repo

  @doc "The name of the `Peep` worker that keeps the metrics."
  def peep, do: PotokIde.Metrics.Peep

  # Named processes whose mailbox is worth seeing: the app's own, the PubSub
  # shards and the presence trackers.
  @mailbox_prefix "Elixir.PotokIde."

  @doc "Profiles online per group page (`PotokIde.Presence`) and PubSub subscriptions."
  def dispatch_online do
    measure(fn ->
      :telemetry.execute([:potok_ide, :presence, :online], %{
        size: ets_size(PotokIde.Presence.Online)
      })
    end)

    measure(fn ->
      :telemetry.execute(
        [:potok_ide, :pubsub, :subscriptions],
        %{count: Registry.count(PotokIde.PubSub)}
      )
    end)
  end

  @doc "The message queue of every named process of the app."
  def dispatch_mailboxes do
    measure(fn ->
      for name <- Process.registered(),
          String.starts_with?(Atom.to_string(name), @mailbox_prefix),
          pid = Process.whereis(name),
          is_pid(pid),
          {:message_queue_len, length} <- [Process.info(pid, :message_queue_len)] do
        :telemetry.execute(
          [:potok_ide, :mailbox],
          %{length: length},
          %{name: inspect(name)}
        )
      end
    end)
  end

  @doc "Jobs running and waiting in the push queue."
  def dispatch_job_queues do
    measure(fn ->
      queue = PotokIde.PushNotifications.Queue
      %{running: running, queued: queued} = GenServer.call(queue, :stats, 1_000)

      :telemetry.execute(
        [:potok_ide, :job_queue],
        %{running: running, queued: queued},
        %{queue: inspect(queue)}
      )
    end)
  end

  @doc "Entries and bytes of the app's ETS caches."
  def dispatch_caches do
    measure(fn ->
      :telemetry.execute(
        [:potok_ide, :cache],
        %{entries: ets_size(PotokIde.Cache), memory: ets_memory(PotokIde.Cache)},
        %{table: inspect(PotokIde.Cache)}
      )

      for cache <- [PotokIde.Cache.Bounded.rendered_html()] do
        :telemetry.execute(
          [:potok_ide, :cache],
          PotokIde.Cache.Bounded.info(cache),
          %{table: inspect(cache)}
        )
      end
    end)
  end

  @doc """
  How many seconds the longest due step of a drawn process has waited for
  `PotokIde.Processes.Scheduler`: 0 when nothing is due, more when passes
  fall behind. Returns the number it sent.
  """
  def dispatch_process_lag do
    measure(fn ->
      seconds = process_lag()
      :telemetry.execute([:potok_ide, :processes, :due_lag], %{seconds: seconds})
      seconds
    end)
  end

  @doc "The seconds since the longest due instance fell due, 0 with none due."
  def process_lag do
    now = DateTime.utc_now(:second)

    from(i in ValueProcess,
      where: i.status in [:running, :waiting] and i.wake_at <= ^now,
      select: min(i.wake_at)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      %DateTime{} = oldest -> max(DateTime.diff(now, oldest, :second), 0)
    end
  end

  defp ets_size(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  defp ets_memory(table) do
    case :ets.info(table, :memory) do
      :undefined -> 0
      words -> words * :erlang.system_info(:wordsize)
    end
  end

  # A measurement that raises would leave the poller for good, so a missing
  # process, table or database (during start, in tests) only skips one round.
  defp measure(fun) do
    fun.()
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end
end
