defmodule PotokIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    maybe_warn_missing_imagemagick()

    children =
      [
        PotokIdeWeb.Telemetry,
        PotokIde.Cache,
        # The rendered HTML of the messages shown: at most 2 × 5,000 of them.
        {PotokIde.Cache.Bounded, name: PotokIde.Cache.RenderedHtml, max_entries: 5_000},
        # Who holds which roles in which group (PotokIde.Social.Access).
        {PotokIde.Cache.Bounded, name: PotokIde.Social.Access.Facts, max_entries: 20_000},
        {Task.Supervisor, name: PotokIde.TaskSupervisor},
        # ImageMagick runs outside the BEAM, so its memory is not the app's to
        # manage: link cards and PNG avatars are drawn one at a time.
        {Task.Supervisor, name: PotokIde.Renderers, max_children: 1},
        # A link preview reads up to 1 MB of a page; past three at once a value
        # or a notice goes without its card rather than wait.
        {Task.Supervisor, name: PotokIde.LinkPreviews.Fetchers, max_children: 3},
        # Working out who gets a push, off the caller; the sending is in Oban.
        {Task.Supervisor, name: PotokIde.PushNotifications.Fanout, max_children: 8},
        PotokIde.Repo,
        {Oban, Application.fetch_env!(:potok_ide, Oban)},
        # The simplified borders maps asked for, kept once made.
        PotokIde.Social.AreaShapes,
        {DNSCluster, query: Application.get_env(:potok_ide, :dns_cluster_query) || :ignore},
        # Four partitions, so broadcasts from other nodes and subscriptions
        # are not all handled by one process. Changing the number on a running
        # cluster takes two deploys (`:broadcast_pool_size`, see Phoenix.PubSub).
        {Phoenix.PubSub, name: PotokIde.PubSub, pool_size: 4},
        PotokIde.Presence.Online,
        PotokIde.Presence,
        PotokIde.Events.ReminderScheduler,
        PotokIde.Polls.Scheduler,
        PotokIde.Processes.Scheduler,
        PotokIde.Social.ScheduledValues.Scheduler,
        PotokIde.Social.ScheduledPublications.Scheduler,
        PotokIde.Social.AppFileSweeper,
        PotokIde.HostingCosts.Sampler,
        # Start to serve requests, typically the last entry
        PotokIdeWeb.Endpoint,
        PotokIde.AccountBootstrap
      ] ++ metrics_server()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PotokIde.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The metrics (PotokIdeWeb.Telemetry) on a port of their own, apart from
  # the endpoint: no route of the app leads there, and on Fly only the private
  # network reaches it, which is IPv6 (`::` takes IPv4 too on Linux).
  defp metrics_server do
    case Application.get_env(:potok_ide, :metrics_port) do
      port when is_integer(port) ->
        [
          Supervisor.child_spec(
            {Bandit,
             plug: {Peep.Plug, peep_worker: PotokIde.Metrics.peep(), on_unmatched_path: :halt},
             scheme: :http,
             ip: {0, 0, 0, 0, 0, 0, 0, 0},
             port: port,
             startup_log: false},
            id: :metrics_server
          )
        ]

      _none ->
        []
    end
  end

  defp maybe_warn_missing_imagemagick do
    if is_nil(PotokIde.ImageMagick.find()) do
      Logger.warning(
        "ImageMagick executable not found. Avatar initials cannot be rasterized to PNG and shared links get Potok's own picture. Install ImageMagick so `magick` is available in PATH."
      )
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PotokIdeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
