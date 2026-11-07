defmodule PotokIde.Polls.Scheduler do
  @moduledoc """
  Closes polls past their deadline and sends poll reminders
  (`PotokIde.Polls.Deadlines`) every `interval_ms`, and once at start so that
  what fell due during a deploy still goes out. It runs on every node.

  A failed pass is logged and the next one runs as usual, as in
  `PotokIde.Events.ReminderScheduler`.
  """

  use GenServer

  require Logger

  alias PotokIde.Polls.Deadlines

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
    Deadlines.run()
  rescue
    error ->
      Logger.error("Poll deadlines failed: " <> Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason ->
      Logger.error("Poll deadlines failed: " <> Exception.format(kind, reason, __STACKTRACE__))
  end
end
