defmodule PotokIde.Cache.Bounded do
  @moduledoc """
  An in-memory cache that never holds more than twice `:max_entries`, for
  what is cheap enough to compute twice and would otherwise grow with use:
  the rendered HTML of every message shown (`rendered_html/0`), people's
  access to groups (`PotokIde.Social.Access`).

  It keeps two generations, two public ETS tables. Reads look in the current
  one, then in the previous one, and an entry found there moves to the
  current one, so what is still used survives. When a write finds the
  current table full, the owner empties the previous table and makes it the
  current one: what nobody read for a generation goes. No caller waits for
  another (unlike `PotokIde.Cache.fetch/3`): two misses of one key both
  compute it.

  Which table is current is an atomic, read on every call; the table names
  and the atomic stand in `:persistent_term`, written once at start.
  """

  use GenServer

  @doc "The cache of rendered message HTML (`Components.formatted_content/1`)."
  def rendered_html, do: PotokIde.Cache.RenderedHtml

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The value under `key`, or `:error` when missing or expired."
  def get(cache, key) do
    {current, previous} = tables(cache)

    case lookup(current, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case :ets.lookup(previous, key) do
          [{^key, value, expires_at} = entry] ->
            if alive?(expires_at) do
              :ets.insert(current, entry)
              {:ok, value}
            else
              :error
            end

          [] ->
            :error
        end
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Keeps `value` under `key` for `ttl` milliseconds (or `:infinity`); returns it."
  def put(cache, key, value, ttl \\ :infinity) do
    {current, _previous} = tables(cache)
    :ets.insert(current, {key, value, expires_at(ttl)})

    if :ets.info(current, :size) >= max_entries(cache), do: rotate(cache)

    value
  rescue
    ArgumentError -> value
  end

  @doc "The value under `key`, computed with `fun` and kept when missing."
  def fetch(cache, key, ttl, fun) when is_function(fun, 0) do
    case get(cache, key) do
      {:ok, value} -> value
      :error -> put(cache, key, fun.(), ttl)
    end
  end

  @doc "Forgets `key` in both generations."
  def delete(cache, key) do
    {current, previous} = tables(cache)
    :ets.delete(current, key)
    :ets.delete(previous, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets everything."
  def clear(cache) do
    {current, previous} = tables(cache)
    :ets.delete_all_objects(current)
    :ets.delete_all_objects(previous)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Entries and bytes in both generations, for the metrics."
  def info(cache) do
    {current, previous} = tables(cache)
    word = :erlang.system_info(:wordsize)

    %{
      entries: :ets.info(current, :size) + :ets.info(previous, :size),
      memory: (:ets.info(current, :memory) + :ets.info(previous, :memory)) * word
    }
  rescue
    ArgumentError -> %{entries: 0, memory: 0}
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table_opts = [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]
    a = :ets.new(:"#{name}.A", table_opts)
    b = :ets.new(:"#{name}.B", table_opts)
    # 1: the index of the current table (0 or 1); 2: whether a rotation is asked.
    state = :atomics.new(2, signed: false)

    :persistent_term.put(
      {__MODULE__, name},
      {{a, b}, state, Keyword.get(opts, :max_entries, 10_000)}
    )

    {:ok, name}
  end

  @impl true
  def handle_info(:rotate, name) do
    {{a, b}, state, _max} = :persistent_term.get({__MODULE__, name})

    # Empty first, then switch: a reader between the two finds the new
    # current table empty and looks in the old one, which still holds it all.
    next = 1 - :atomics.get(state, 1)
    :ets.delete_all_objects(elem({a, b}, next))
    :atomics.put(state, 1, next)
    :atomics.put(state, 2, 0)
    {:noreply, name}
  end

  # One rotation per full generation: the first writer to find it full asks.
  defp rotate(cache) do
    {_tables, state, _max} = :persistent_term.get({__MODULE__, cache})

    if :atomics.compare_exchange(state, 2, 0, 1) == :ok do
      send(cache, :rotate)
    end

    :ok
  end

  defp tables(cache) do
    {{a, b}, state, _max} = :persistent_term.get({__MODULE__, cache})

    case :atomics.get(state, 1) do
      0 -> {a, b}
      1 -> {b, a}
    end
  end

  defp max_entries(cache) do
    {_tables, _state, max} = :persistent_term.get({__MODULE__, cache})
    max
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] ->
        if alive?(expires_at), do: {:ok, value}, else: :error

      [] ->
        :error
    end
  end

  defp alive?(:infinity), do: true
  defp alive?(expires_at), do: System.monotonic_time(:millisecond) < expires_at

  defp expires_at(:infinity), do: :infinity
  defp expires_at(ttl) when is_integer(ttl), do: System.monotonic_time(:millisecond) + ttl
end
