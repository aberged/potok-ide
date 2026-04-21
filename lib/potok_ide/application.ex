defmodule PotokIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  alias PotokIde.GmailRefreshToken

  @impl true
  def start(_type, _args) do
    maybe_warn_missing_imagemagick()

    children = [
      PotokIdeWeb.Telemetry,
      PotokIde.Repo,
      {DNSCluster, query: Application.get_env(:potok_ide, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PotokIde.PubSub},
      PotokIde.Presence,
      # Start a worker by calling: PotokIde.Worker.start_link(arg)
      # {PotokIde.Worker, arg},
      # Start to serve requests, typically the last entry
      PotokIdeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PotokIde.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_warn_missing_imagemagick do
    has_magick = System.find_executable("magick")

    has_convert =
      case :os.type() do
        {:win32, _} -> false
        _ -> System.find_executable("convert")
      end

    if is_nil(has_magick) and is_nil(has_convert) do
      Logger.warning(
        "ImageMagick executable not found. Avatar initials cannot be rasterized to PNG; Potok will fall back to the default avatar image. Install ImageMagick so `magick` is available in PATH."
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
