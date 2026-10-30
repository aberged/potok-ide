# What the websocket transport processes and the LiveViews hold, and how much
# of it a garbage collection frees. Run against the live release during a load
# run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/inspect_ws.exs")'
#
# Bandit runs each HTTP connection in a `Bandit.DelegatingHandler` process; a
# websocket stays in the process that upgraded it, so those are the
# transports. Sizes in KB, averaged per process.
defmodule LoadTest.InspectWS do
  @sample 20

  def run do
    groups =
      Process.list()
      |> Enum.map(&{&1, kind(&1)})
      |> Enum.reject(fn {_pid, kind} -> is_nil(kind) end)
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

    Enum.each(groups, fn {kind, pids} -> report(kind, pids) end)
  end

  defp kind(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        cond do
          match?({Phoenix.LiveView, _, _}, dictionary[:"$process_label"]) ->
            {_, view, _} = dictionary[:"$process_label"]
            "LV " <> inspect(view)

          dictionary[:"$initial_call"] == {Bandit.DelegatingHandler, :init, 1} ->
            "Bandit handler"

          true ->
            nil
        end

      nil ->
        nil
    end
  end

  defp report(kind, pids) do
    before = Enum.map(pids, &stats/1) |> Enum.reject(&is_nil/1)
    sample = Enum.take_random(pids, @sample)
    sample_before = Enum.map(sample, &stats/1) |> Enum.reject(&is_nil/1)
    Enum.each(sample, &:erlang.garbage_collect/1)
    sample_after = Enum.map(sample, &stats/1) |> Enum.reject(&is_nil/1)

    IO.puts("""
    #{kind}: #{length(before)} processes
      all:            #{summary(before)}
      sample before:  #{summary(sample_before)}
      sample after GC #{summary(sample_after)}
    """)
  end

  defp stats(pid) do
    case Process.info(pid, [:memory, :heap_size, :total_heap_size, :binary, :message_queue_len]) do
      nil ->
        nil

      info ->
        word = :erlang.system_info(:wordsize)

        %{
          memory: info[:memory],
          heap: info[:heap_size] * word,
          total_heap: info[:total_heap_size] * word,
          binary: info[:binary] |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
          queue: info[:message_queue_len]
        }
    end
  end

  defp summary([]), do: "-"

  defp summary(stats) do
    avg = fn key -> div(Enum.sum(Enum.map(stats, & &1[key])), length(stats) * 1024) end
    max_memory = div(Enum.max(Enum.map(stats, & &1.memory)), 1024)

    "memory #{avg.(:memory)} (max #{max_memory}), heap #{avg.(:heap)}, total heap #{avg.(:total_heap)}, refc binaries #{avg.(:binary)}"
  end
end

LoadTest.InspectWS.run()
