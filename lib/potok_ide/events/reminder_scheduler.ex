defmodule PotokIde.Events.ReminderScheduler do
  @moduledoc """
  Sends event reminders that are due (`PotokIde.Events.Reminders`) every
  `interval_ms`, and once at start so reminders that fell due during a deploy
  still go out. It runs on every node; the reminder query skips events that
  another node is handling.

  A failed pass is logged and the next one runs as usual: crashing instead
  would restart it in a loop while the database is away, and take the
  application down with it.
  """

  use GenServer

  require Logger

  alias PotokIde.Events.Reminders

  def start_link(opts) do
    config = Application.get_env(:potok_ide, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      GenServer.start_link(__MODULE__, Keyword.get(config, :interval_ms, 30_000), opts)
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
    Reminders.send_due_reminders()
  rescue
    error ->
      Logger.error("Event reminders failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("Event reminders failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
