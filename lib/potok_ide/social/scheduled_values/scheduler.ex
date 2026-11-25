defmodule PotokIde.Social.ScheduledValues.Scheduler do
  @moduledoc """
  Sends the messages whose time has come
  (`PotokIde.Social.ScheduledValues.run_due/1`): once at start, so that what
  fell due during a deploy still goes out, then when the next one is due, and
  at the latest every `interval_ms`. `nudge/0` sets the time again once a
  message is scheduled or moved.

  It runs on every node, and a message one node is sending is skipped by the
  others. A node learns of what another one took in at its next regular pass,
  which only matters when that other one stops before the message is due. A
  failed pass is logged and the next one runs as usual, as in
  `PotokIde.Processes.Scheduler`.
  """

  use GenServer

  require Logger

  alias PotokIde.Social.ScheduledValues

  # What is still due after a pass is being sent by another node, or was more
  # than one pass takes.
  @again_ms 1_000

  # The pass comes a moment after the second it is for, never before it.
  @margin_ms 5

  def start_link(opts) do
    config = Application.get_env(:potok_ide, __MODULE__, [])

    if Keyword.get(config, :enabled, true) do
      interval_ms = Keyword.get(config, :interval_ms, 30_000)
      GenServer.start_link(__MODULE__, interval_ms, Keyword.put_new(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "Asks this node's scheduler to look when the next message is due; nothing when it is off."
  def nudge do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :nudge) && :ok
    end
  end

  # A deploy that comes while a message is being sent waits until its pages
  # and devices hear of it.
  @impl true
  def init(interval_ms) do
    Process.flag(:trap_exit, true)
    {:ok, %{interval_ms: interval_ms, timer: nil}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  # A burst of nudges sets the time once.
  def handle_info(:nudge, state) do
    drain_nudges()
    {:noreply, arm(state)}
  end

  defp drain_nudges do
    receive do
      :nudge -> drain_nudges()
    after
      0 -> :ok
    end
  end

  defp tick(state) do
    guarded(fn -> ScheduledValues.run_due() end)
    arm(state)
  end

  # One timer at a time: a tick that already waits in the mailbox when a nudge
  # sets a new one only makes a pass with nothing to send.
  defp arm(%{timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)

    next_at = guarded(fn -> ScheduledValues.next_at() end)
    delay = delay_ms(next_at, DateTime.utc_now(), state.interval_ms)

    %{state | timer: Process.send_after(self(), :tick, delay)}
  end

  @doc """
  How long after `now` the next pass comes when the next message goes out at
  `next_at` (nil for none), in milliseconds.
  """
  def delay_ms(nil, %DateTime{}, interval_ms), do: interval_ms

  def delay_ms(%DateTime{} = next_at, %DateTime{} = now, interval_ms) do
    case DateTime.diff(next_at, now, :millisecond) do
      ms when ms >= 0 -> min(ms + @margin_ms, interval_ms)
      _due -> min(@again_ms, interval_ms)
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      log(:error, error, __STACKTRACE__)
  catch
    kind, reason ->
      log(kind, reason, __STACKTRACE__)
  end

  defp log(kind, reason, stacktrace) do
    Logger.error("Scheduled messages failed: " <> Exception.format(kind, reason, stacktrace))
    nil
  end
end
