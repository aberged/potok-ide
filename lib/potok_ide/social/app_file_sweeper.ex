defmodule PotokIde.Social.AppFileSweeper do
  @moduledoc """
  Deletes the files apps took in that no value claimed within a day, and those
  whose value is gone (`PotokIde.Social.AppFiles.sweep/1`), every
  `interval_ms` and once at start. It runs on every node; two passes at once
  delete nothing twice.

  A failed pass is logged and the next one runs as usual, as in
  `PotokIde.Polls.Scheduler`.
  """

  use GenServer

  require Logger

  alias PotokIde.Social.AppFiles

  def start_link(opts) do
    config = Application.get_env(:potok_ide, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      GenServer.start_link(__MODULE__, Keyword.get(config, :interval_ms, :timer.hours(1)), opts)
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
    AppFiles.sweep()
  rescue
    error ->
      Logger.error("App file sweep failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("App file sweep failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
