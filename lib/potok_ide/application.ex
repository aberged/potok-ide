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
      {Task.Supervisor, name: PotokIde.LinkCards.Renderers, max_children: 1},
      PotokIde.Repo,
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
