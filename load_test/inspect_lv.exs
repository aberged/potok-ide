# Prints what a GroupLive.Show process holds, assign by assign. Run against
# the live release during a load run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/inspect_lv.exs")'
#
# Sizes are :erts_debug.flat_size (heap words * 8) plus, in the second column,
# the bytes of the large (off-heap, reference-counted) binaries each assign
# holds, such as app descriptions; averaged over up to 20 processes per kind:
# the root page, app groups (`uses_api`) and other groups. "binaries held" is
# what Process.info(pid, :binary) lists: whole binaries, even when an assign
# keeps only a slice of one.
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
          {:binary, bins} = Process.info(pid, :binary)
          held = bins |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          [{:sys.get_state(pid, 5_000), {memory, held}}]
        catch
          _, _ -> []
        end
      end)

    states
    |> Enum.group_by(fn {state, _} ->
      group = state.socket.assigns.group

      cond do
        is_nil(group.parent_id) -> :root_page
        group.uses_api -> :app_page
        true -> :group_page
      end
    end)
    |> Enum.each(fn {kind, states} -> report(kind, states) end)
  end

  defp report(kind, states) do
    count = length(states)
    process_kb = states |> Enum.map(&elem(elem(&1, 1), 0)) |> Enum.sum() |> div(count * 1024)
    held_kb = states |> Enum.map(&elem(elem(&1, 1), 1)) |> Enum.sum() |> div(count * 1024)

    sizes =
      states
      |> Enum.flat_map(fn {state, _} ->
        assigns = state.socket.assigns |> Map.drop([:__changed__, :flash])
        streams = Map.get(assigns, :streams, %{})

        Enum.map(Map.delete(assigns, :streams), fn {key, value} -> {key, size(value)} end) ++
          [
            {:"(streams)", size(streams)},
            {:"(socket.private)", size(state.socket.private)},
            {:"(fingerprints/components)", size(Map.drop(state, [:socket]))}
          ]
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {key, values} ->
        heap = values |> Enum.map(&elem(&1, 0)) |> Enum.sum()
        bins = values |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        {key, div(heap * 8, count * 1024), div(bins, count * 1024)}
      end)
      |> Enum.sort_by(fn {_key, heap, bins} -> heap + bins end, :desc)
      |> Enum.take(15)

    IO.puts(
      "#{kind}: #{count} processes, #{process_kb} KB process memory and #{held_kb} KB of binaries held on average; largest parts (KB heap, KB binaries):"
    )

    Enum.each(sizes, fn {key, heap, bins} ->
      IO.puts("  #{String.pad_trailing(inspect(key), 32)} #{heap} #{bins}")
    end)
  end

  defp size(term), do: {:erts_debug.flat_size(term), big_binaries(term)}

  # Binaries over 64 bytes live off the heap; flat_size counts only their header.
  defp big_binaries(term) when is_binary(term) and byte_size(term) > 64, do: byte_size(term)
  defp big_binaries(term) when is_binary(term), do: 0
  defp big_binaries(term) when is_list(term), do: list_binaries(term, 0)
  defp big_binaries(term) when is_tuple(term), do: term |> Tuple.to_list() |> list_binaries(0)

  # Structs are maps too, but not Enumerable.
  defp big_binaries(term) when is_map(term),
    do: :maps.fold(fn k, v, acc -> acc + big_binaries(k) + big_binaries(v) end, 0, term)

  defp big_binaries(_term), do: 0

  defp list_binaries([head | tail], acc), do: list_binaries(tail, acc + big_binaries(head))
  defp list_binaries([], acc), do: acc
  defp list_binaries(improper_tail, acc), do: acc + big_binaries(improper_tail)
end

LoadTest.InspectLV.run()
