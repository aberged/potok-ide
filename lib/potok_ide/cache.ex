defmodule PotokIde.Cache do
  @moduledoc """
  Small in-memory TTL cache backed by a public ETS table.

  Used for values that are expensive to compute but change rarely
  (root group, FCM access token, rendered markdown, generated avatars).
  Entries are stored as `{key, value, expires_at_ms | :infinity}`.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms :timer.minutes(5)
  # How long a caller waits for another one computing the same key before it
  # computes the value itself.
  @claim_timeout_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached value for `key`, computing and storing it with `fun`
  when missing or expired. `ttl` is in milliseconds or `:infinity`.

  Concurrent misses of one key compute it once: the first caller runs `fun`
  and the others wait for it. A page of uncached avatars requested by many
  browsers at once would otherwise run ImageMagick once per request.
  """
  def fetch(key, ttl, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, value} -> value
      :error -> fetch_missing(key, ttl, fun)
    end
  end

  defp fetch_missing(key, ttl, fun) do
    case claim(key) do
      :compute ->
        try do
          put(key, fun.(), ttl)
        after
          GenServer.cast(__MODULE__, {:done, key, self()})
        end

      # Another caller finished (or failed): look again.
      :ready ->
        fetch(key, ttl, fun)
    end
  end

  defp claim(key) do
    GenServer.call(__MODULE__, {:claim, key}, @claim_timeout_ms)
  catch
    # Not running, or the computing caller is stuck.
    :exit, _reason -> :compute
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, :infinity}] ->
        {:ok, value}

      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :error
        end

      [] ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  def put(key, value, ttl \\ :infinity) do
    expires_at =
      case ttl do
        :infinity -> :infinity
        ms when is_integer(ms) -> System.monotonic_time(:millisecond) + ms
      end

    :ets.insert(@table, {key, value, expires_at})
    value
  rescue
    ArgumentError -> value
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete_many(keys) when is_list(keys) do
    Enum.each(keys, &delete/1)
  end

  @doc "Deletes every entry whose key is a tuple starting with `prefix`."
  def delete_prefix(prefix) do
    :ets.select_delete(@table, [
      {{:"$1", :_, :_}, [{:andalso, {:is_tuple, :"$1"}, {:==, {:element, 1, :"$1"}, prefix}}],
       [true]}
    ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    # key => {computing pid, monitor ref, waiting callers}
    {:ok, %{computing: %{}}}
  end

  @impl true
  def handle_call({:claim, key}, {pid, _tag} = from, state) do
    case state.computing do
      # A nested fetch of the key from inside its own computation.
      %{^key => {^pid, _ref, _waiters}} ->
        {:reply, :compute, state}

      %{^key => {owner, ref, waiters}} ->
        {:noreply, put_in(state.computing[key], {owner, ref, [from | waiters]})}

      _ ->
        if match?({:ok, _}, get(key)) do
          {:reply, :ready, state}
        else
          ref = Process.monitor(pid)
          {:reply, :compute, put_in(state.computing[key], {pid, ref, []})}
        end
    end
  end

  @impl true
  def handle_cast({:done, key, pid}, state), do: {:noreply, release(state, key, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Enum.find(state.computing, fn {_key, {_pid, key_ref, _}} -> key_ref == ref end) do
      {key, _computing} -> {:noreply, release(state, key, pid)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:andalso, {:is_integer, :"$1"}, {:<, :"$1", now}}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp release(state, key, pid) do
    case state.computing do
      %{^key => {^pid, ref, waiters}} ->
        Process.demonitor(ref, [:flush])
        Enum.each(waiters, &GenServer.reply(&1, :ready))
        %{state | computing: Map.delete(state.computing, key)}

      _ ->
        state
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
