defmodule PotokIde.HostingCosts.Sampler do
  @moduledoc """
  Writes the estimate of what Potok costs on Fly (`PotokIde.HostingCosts.sample/1`)
  every `interval_ms`, and once at start, so the hour of a deploy is not lost.
  It runs only where Potok can read Fly (`FLY_COSTS_TOKEN`), on every node:
  the rows of an hour are replaced, never added twice.

  A failed pass is logged and the next one runs as usual.
  """

  use GenServer

  require Logger

  alias PotokIde.HostingCosts

  def start_link(opts) do
    config = Application.get_env(:potok_ide, __MODULE__, [])

    if Keyword.get(config, :enabled, true) and HostingCosts.estimating?() do
      GenServer.start_link(
        __MODULE__,
        Keyword.get(config, :interval_ms, :timer.minutes(15)),
        opts
      )
    else
      :ignore
    end
  end

  @impl true
  def init(interval_ms), do: {:ok, interval_ms, {:continue, :tick}}

  @impl true
  def handle_continue(:tick, interval_ms) do
    tick()
    Process.send_after(self(), :tick, interval_ms)
    {:noreply, interval_ms}
  end

  @impl true
  def handle_info(:tick, interval_ms), do: handle_continue(:tick, interval_ms)

  defp tick do
    HostingCosts.sample()
  rescue
    error ->
      Logger.error("Hosting costs failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("Hosting costs failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
