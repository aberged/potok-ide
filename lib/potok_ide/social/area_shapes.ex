defmodule PotokIde.Social.AreaShapes do
  @moduledoc """
  The simplified borders maps ask for (`GroupAreas.shapes/4`), kept once made:
  simplifying a border of thousands of points for each request cost more
  than the rest of a map's view.

  A border is kept by its area's id, version (`updated_at`), size and level of
  detail, so an edited area is made again, even twice in the same second.
  Readers go to the ETS table directly; this process only keeps the table
  under its size, dropping the borders used longest ago.
  """

  use GenServer

  @table __MODULE__
  @max_bytes 64 * 1024 * 1024
  # What a trim leaves, of the bound.
  @trim_to 0.75

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The borders of `areas` (`%{id, updated_at, size}`) at `level`, in their
  order, as `[{area, geojson}]`: the kept ones, and for the others what
  `make.(ids)` (`%{id => geojson}`) gives, which is kept from then on. An area
  `make` gives nothing for is left out.
  """
  def fetch(areas, level, make) when is_list(areas) and is_function(make, 1) do
    if :ets.whereis(@table) == :undefined do
      made = if areas == [], do: %{}, else: make.(Enum.map(areas, & &1.id))
      for area <- areas, geojson = made[area.id], do: {area, geojson}
    else
      kept = Map.new(areas, &{&1.id, lookup(key(&1, level))})
      missing = for area <- areas, is_nil(kept[area.id]), do: area
      made = if missing == [], do: %{}, else: make.(Enum.map(missing, & &1.id))
      Enum.each(missing, &(made[&1.id] && put(key(&1, level), made[&1.id])))

      for area <- areas, geojson = kept[area.id] || made[area.id], do: {area, geojson}
    end
  end

  defp key(%{id: id, updated_at: updated_at, size: size}, level),
    do: {id, DateTime.to_unix(updated_at), size, level}

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, geojson, _bytes, _used}] ->
        :ets.update_element(@table, key, {4, now()})
        geojson

      [] ->
        nil
    end
  end

  defp put(key, geojson) do
    bytes = byte_size(geojson)
    :ets.insert(@table, {key, geojson, bytes, now()})
    GenServer.cast(__MODULE__, {:added, bytes})
  end

  defp now, do: System.monotonic_time()

  @impl true
  def init(opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{bytes: 0, max_bytes: Keyword.get(opts, :max_bytes, @max_bytes)}}
  end

  @impl true
  def handle_cast({:added, bytes}, state) do
    state = %{state | bytes: state.bytes + bytes}
    {:noreply, if(state.bytes > state.max_bytes, do: trim(state), else: state)}
  end

  # Drops the borders used longest ago until the table is back under
  # `@trim_to` of its bound.
  defp trim(state) do
    entries = :ets.select(@table, [{{:"$1", :_, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    {dropped, left} = to_drop(entries, trunc(state.max_bytes * @trim_to))
    Enum.each(dropped, &:ets.delete(@table, &1))
    %{state | bytes: left}
  end

  @doc """
  Of `entries` (`{key, bytes, last_used}`), the keys to drop, used longest
  ago first, for the rest to fit in `target` bytes, and the bytes left:
  `{keys, bytes}`.
  """
  def to_drop(entries, target) do
    total = Enum.reduce(entries, 0, fn {_key, bytes, _used}, sum -> sum + bytes end)

    entries
    |> Enum.sort_by(fn {_key, _bytes, used} -> used end)
    |> Enum.reduce_while({[], total}, fn {key, bytes, _used}, {dropped, left} ->
      if left <= target,
        do: {:halt, {dropped, left}},
        else: {:cont, {[key | dropped], left - bytes}}
    end)
    |> then(fn {dropped, left} -> {Enum.reverse(dropped), left} end)
  end
end
