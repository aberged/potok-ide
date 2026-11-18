defmodule PotokIde.Social.AppFileSweeper do
  @moduledoc """
  Deletes the files apps took in that no value claimed within a day, and those
  whose value is gone (`PotokIde.Social.AppFiles.sweep/1`), every
  `interval_ms` and once at start. It runs on every node, and the first of
  them in an hour does the pass (`PotokIde.RateLimit.once?/1`); two passes at
  once would still delete nothing twice.

  The same pass deletes the profiles of processes whose app is gone and that
  left nothing they wrote (`PotokIde.Social.AppProcesses.sweep/0`), and
  fails the runs that wait for a run deleted with its process or its group
  (`PotokIde.Processes.Engine.fail_orphaned_calls/1`), and deletes the shared
  counters of limits whose window has ended (`PotokIde.RateLimit.prune/0`).

  A failed pass is logged and the next one runs as usual, as in
  `PotokIde.Polls.Scheduler`.
  """

  use GenServer

  require Logger

  alias PotokIde.RateLimit
  alias PotokIde.Social.{AppFiles, AppProcesses}

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
    pass()
    Process.send_after(self(), :tick, interval_ms)
    {:noreply, interval_ms}
  end

  @impl true
  def handle_info(:tick, interval_ms), do: handle_continue(:tick, interval_ms)

  @doc false
  # `:done`, or `:skipped` when another machine did this hour's pass.
  def pass do
    if RateLimit.once?(:app_file_sweep) do
      AppFiles.sweep()
      AppProcesses.sweep()
      PotokIde.Processes.Engine.fail_orphaned_calls()
      RateLimit.prune()
      :done
    else
      :skipped
    end
  rescue
    error ->
      Logger.error("App file sweep failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("App file sweep failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
