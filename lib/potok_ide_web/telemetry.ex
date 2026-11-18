defmodule PotokIdeWeb.Telemetry do
  @moduledoc """
  The metrics the app keeps of itself, in a `Peep` worker
  (`PotokIde.Metrics.peep/0`) that the private metrics port serves to Fly
  (see `PotokIde.Application`).

  Durations are kept in microseconds and exported in milliseconds, so that
  the short ones (a connection checkout) still spread over the histogram's
  buckets. Tags stay few and bounded: a table, a route, a LiveView module,
  never anything a client sends.
  """

  use Supervisor
  import Telemetry.Metrics

  @ms [peep_export_conversion_factor: 1.0e-3]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children =
      [
        {Peep, name: PotokIde.Metrics.peep(), metrics: metrics()},
        Supervisor.child_spec(
          {:telemetry_poller,
           measurements: periodic_measurements(), period: 10_000, name: :potok_ide_poller},
          id: :potok_ide_poller
        )
      ] ++ process_lag_poller()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # One query a round, so less often than the rest.
  defp process_lag_poller do
    if Keyword.get(Application.get_env(:potok_ide, __MODULE__, []), :process_lag, true) do
      [
        Supervisor.child_spec(
          {:telemetry_poller,
           measurements: [{PotokIde.Metrics, :dispatch_process_lag, []}],
           period: 30_000,
           name: :potok_ide_slow_poller},
          id: :potok_ide_slow_poller
        )
      ]
    else
      []
    end
  end

  def metrics do
    [
      # Phoenix
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),
      counter("phoenix.router_dispatch.exception.duration", tags: [:route]),
      distribution("phoenix.socket_connected.duration",
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),
      sum("phoenix.socket_drain.count"),

      # LiveView, per page module
      distribution("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),
      distribution("phoenix.live_view.handle_params.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),
      distribution("phoenix.live_view.handle_event.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :microsecond},
        reporter_options: @ms
      ),

      # Websockets opened and closed: open ones are the difference.
      counter("bandit.websocket.start.count"),
      counter("bandit.websocket.stop.count"),

      # Database
      distribution("potok_ide.repo.query.queue_time",
        unit: {:native, :microsecond},
        reporter_options: @ms,
        description: "The time spent waiting for a database connection"
      ),
      distribution("potok_ide.repo.query.query_time",
        tags: [:source],
        tag_values: &repo_tags/1,
        unit: {:native, :microsecond},
        reporter_options: @ms,
        description: "The time spent executing the query"
      ),
      distribution("potok_ide.repo.query.total_time",
        unit: {:native, :microsecond},
        reporter_options: @ms,
        description: "The sum of the other measurements"
      ),

      # What grows with the people online (PotokIde.Metrics)
      last_value("potok_ide.presence.online.size"),
      last_value("potok_ide.pubsub.subscriptions.count"),
      last_value("potok_ide.mailbox.length", tags: [:name]),
      last_value("potok_ide.job_queue.running", tags: [:queue]),
      last_value("potok_ide.job_queue.queued", tags: [:queue]),
      counter("potok_ide.job_queue.dropped.count", tags: [:queue]),
      last_value("potok_ide.processes.due_lag.seconds"),
      last_value("potok_ide.cache.entries", tags: [:table]),
      last_value("potok_ide.cache.memory", tags: [:table], unit: :byte),
      counter("potok_ide.cache.fetch.count", tags: [:result]),

      # VM (telemetry_poller's own default poller)
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count")
    ]
  end

  defp periodic_measurements do
    [
      {PotokIde.Metrics, :dispatch_online, []},
      {PotokIde.Metrics, :dispatch_mailboxes, []},
      {PotokIde.Metrics, :dispatch_job_queues, []},
      {PotokIde.Metrics, :dispatch_caches, []}
    ]
  end

  defp live_view_tags(%{socket: %{view: view}}), do: %{view: inspect(view)}
  defp live_view_tags(_metadata), do: %{view: "unknown"}

  # Ecto names the table of a query; raw SQL has none.
  defp repo_tags(%{source: source}) when is_binary(source), do: %{source: source}
  defp repo_tags(_metadata), do: %{source: "sql"}
end
