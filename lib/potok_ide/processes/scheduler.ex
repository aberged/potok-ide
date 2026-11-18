defmodule PotokIde.Processes.Scheduler do
  @moduledoc """
  Takes forward the instances of apps' processes that are due
  (`PotokIde.Processes.Engine.run_due/1`): every `interval_ms`, once at start
  so that what fell due during a deploy goes on, and whenever a commit made
  one due (`nudge/0`), so a first step does not wait for the next pass. Each
  regular pass first starts the scheduled processes whose time has come
  (`Engine.start_scheduled/1`), and their first steps go in the same pass.

  It runs on every node; an instance one node holds is skipped by the others.
  A failed pass is logged and the next one runs as usual, as in
  `PotokIde.Polls.Scheduler`.
  """

  use GenServer

  require Logger

  alias PotokIde.Processes.Engine

  # Instances in one pass, so one busy app does not hold the others back.
  @batch 200

  def start_link(opts) do
    config = Application.get_env(:potok_ide, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      interval_ms = Keyword.get(config, :interval_ms, 30_000)
      GenServer.start_link(__MODULE__, interval_ms, Keyword.put_new(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "Asks this node's scheduler for a pass now; nothing when it is off."
  def nudge do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :nudge) && :ok
    end
  end

  @impl true
  def init(interval_ms), do: {:ok, interval_ms, {:continue, :tick}}

  @impl true
  def handle_continue(:tick, interval_ms) do
    start_scheduled()
    tick()
    Process.send_after(self(), :tick, interval_ms)
    {:noreply, interval_ms}
  end

  @impl true
  def handle_info(:tick, interval_ms), do: handle_continue(:tick, interval_ms)

  # A nudge runs a pass between the regular ones, which keep their time.
  # The nudges already waiting go in the same pass: a burst of commits makes
  # one pass, not one each.
  def handle_info(:nudge, interval_ms) do
    drain_nudges()
    tick()
    {:noreply, interval_ms}
  end

  defp drain_nudges do
    receive do
      :nudge -> drain_nudges()
    after
      0 -> :ok
    end
  end

  defp start_scheduled do
    Engine.start_scheduled(@batch)
  rescue
    error ->
      Logger.error(
        "Scheduled processes failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  catch
    kind, reason ->
      Logger.error(
        "Scheduled processes failed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  defp tick do
    Engine.run_due(@batch)
  rescue
    error ->
      Logger.error("Process steps failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("Process steps failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
