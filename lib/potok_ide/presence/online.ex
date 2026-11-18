defmodule PotokIde.Presence.Online do
  @moduledoc """
  The set of `{topic, key}` pairs that have a presence (`PotokIde.Presence`),
  in a public ETS table that this process owns.

  The tracker runs in several shards (`:pool_size`), each one calling
  `PotokIde.Presence.handle_metas/4` for its own topics, so no shard can own
  the table. Each row names the shard that wrote it, and this process
  watches the shards: one that stops takes its rows with it, as its
  presences go with it.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Marks `{topic, key}` online for the calling shard, or offline."
  def put(topic, key, true) do
    watch_caller()
    :ets.insert(@table, {{topic, key}, self()})
  end

  def put(topic, key, false), do: :ets.delete(@table, {topic, key})

  @doc "Whether `{topic, key}` has a presence."
  def member?(topic, key) do
    :ets.member(@table, {topic, key})
  rescue
    ArgumentError -> false
  end

  # Once per shard process.
  defp watch_caller do
    unless Process.get({__MODULE__, :watched}) do
      GenServer.cast(__MODULE__, {:watch, self()})
      Process.put({__MODULE__, :watched}, true)
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, MapSet.new()}
  end

  @impl true
  def handle_cast({:watch, pid}, watched) do
    if MapSet.member?(watched, pid) do
      {:noreply, watched}
    else
      Process.monitor(pid)
      {:noreply, MapSet.put(watched, pid)}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, watched) do
    :ets.match_delete(@table, {:_, pid})
    {:noreply, MapSet.delete(watched, pid)}
  end
end
