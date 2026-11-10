defmodule PotokIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    maybe_warn_missing_imagemagick()

    children = [
      PotokIdeWeb.Telemetry,
      PotokIde.Cache,
      {Task.Supervisor, name: PotokIde.TaskSupervisor},
      # ImageMagick runs outside the BEAM, so its memory is not the app's to
      # manage: link cards and PNG avatars are drawn one at a time.
      {Task.Supervisor, name: PotokIde.Renderers, max_children: 1},
      # A link preview reads up to 1 MB of a page; past three at once a value
      # goes without its card rather than wait.
      {Task.Supervisor, name: PotokIde.LinkPreviews.Fetchers, max_children: 3},
      {PotokIde.JobQueue,
       name: PotokIde.PushNotifications.Queue,
       task_supervisor: PotokIde.TaskSupervisor,
       max_running: 2,
       max_queued: 2_000},
      PotokIde.Repo,
      # The simplified borders maps asked for, kept once made.
      PotokIde.Social.AreaShapes,
      {DNSCluster, query: Application.get_env(:potok_ide, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PotokIde.PubSub},
      PotokIde.Presence,
      PotokIde.Events.ReminderScheduler,
      PotokIde.Polls.Scheduler,
      PotokIde.Social.AppFileSweeper,
      # Start to serve requests, typically the last entry
      PotokIdeWeb.Endpoint,
      PotokIde.AccountBootstrap
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PotokIde.Supervisor]
    Supervisor.start_link(children, opts)
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
