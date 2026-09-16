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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the cached value for `key`, computing and storing it with `fun`
  when missing or expired. `ttl` is in milliseconds or `:infinity`.
  """
  def fetch(key, ttl, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, value} ->
        value

      :error ->
        value = fun.()
        put(key, value, ttl)
        value
    end
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
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:andalso, {:is_integer, :"$1"}, {:<, :"$1", now}}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
