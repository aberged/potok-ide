# Prints what a GroupLive.Show process holds, assign by assign. Run against
# the live release during a load run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/inspect_lv.exs")'
#
# Sizes are :erts_debug.flat_size (heap words * 8), averaged over up to 20
# processes, split into root-group and other pages.
defmodule LoadTest.InspectLV do
  def run(sample \\ 20) do
    pids =
      Process.list()
      |> Enum.filter(fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            match?({Phoenix.LiveView, PotokIdeWeb.GroupLive.Show, _}, dict[:"$process_label"])

          _ ->
            false
        end
      end)
      |> Enum.take_random(sample)

    states =
      Enum.flat_map(pids, fn pid ->
        try do
          {:memory, memory} = Process.info(pid, :memory)
          [{:sys.get_state(pid, 5_000), memory}]
        catch
          _, _ -> []
        end
      end)

    states
    |> Enum.group_by(fn {state, _} ->
      if state.socket.assigns.group.parent_id, do: :group_page, else: :root_page
    end)
    |> Enum.each(fn {kind, states} -> report(kind, states) end)
  end

  defp report(kind, states) do
    count = length(states)
    process_kb = states |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> div(count * 1024)

    sizes =
      states
      |> Enum.flat_map(fn {state, _} ->
        assigns = state.socket.assigns |> Map.drop([:__changed__, :flash])
        streams = Map.get(assigns, :streams, %{})

        Enum.map(Map.delete(assigns, :streams), fn {key, value} -> {key, words(value)} end) ++
          [
            {:"(streams)", words(streams)},
            {:"(socket.private)", words(state.socket.private)},
            {:"(fingerprints/components)", words(Map.drop(state, [:socket]))}
          ]
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {key, values} -> {key, div(Enum.sum(values) * 8, count * 1024)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(15)

    IO.puts(
      "#{kind}: #{count} processes, #{process_kb} KB process memory on average; largest parts (KB):"
    )

    Enum.each(sizes, fn {key, kb} ->
      IO.puts("  #{String.pad_trailing(inspect(key), 32)} #{kb}")
    end)
  end

  defp words(term), do: :erts_debug.flat_size(term)
end

LoadTest.InspectLV.run()
