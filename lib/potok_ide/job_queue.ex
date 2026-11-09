defmodule PotokIde.JobQueue do
  @moduledoc """
  Runs jobs off the caller, at most `:max_running` at a time; the rest wait
  in line, up to `:max_queued`, and past that a job is dropped with a warning.

  Push notifications go through one (`PotokIde.PushNotifications.Queue`):
  each sends to several accounts at once, so a burst of posts in big groups
  used to start that many HTTP calls in parallel, each with its own payload
  encryption, on a machine with a fraction of a CPU core.
  """

  use GenServer

  require Logger

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "Puts `fun` in line; it runs under the queue's task supervisor."
  def run(queue, fun) when is_function(fun, 0) do
    GenServer.cast(queue, {:run, fun})
  end

  @doc "How many jobs run and how many wait, for tests and inspection."
  def stats(queue), do: GenServer.call(queue, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       name: Keyword.fetch!(opts, :name),
       supervisor: Keyword.fetch!(opts, :task_supervisor),
       max_running: Keyword.get(opts, :max_running, 2),
       max_queued: Keyword.get(opts, :max_queued, 1_000),
       running: %{},
       queue: :queue.new(),
       queued: 0
     }}
  end

  @impl true
  def handle_cast({:run, fun}, state) do
    cond do
      map_size(state.running) < state.max_running ->
        {:noreply, start(state, fun)}

      state.queued < state.max_queued ->
        {:noreply, %{state | queue: :queue.in(fun, state.queue), queued: state.queued + 1}}

      true ->
        Logger.warning("#{inspect(state.name)} has #{state.queued} jobs waiting; dropped one")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{running: map_size(state.running), queued: state.queued}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{state | running: Map.delete(state.running, ref)}

    case :queue.out(state.queue) do
      {{:value, fun}, queue} ->
        {:noreply, start(%{state | queue: queue, queued: state.queued - 1}, fun)}

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  defp start(state, fun) do
    {:ok, pid} = Task.Supervisor.start_child(state.supervisor, fun)
    %{state | running: Map.put(state.running, Process.monitor(pid), pid)}
  end
end
