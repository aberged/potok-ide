# A sampling profiler that needs nothing outside the release: for
# PROFILE_SECONDS (default 15) it records, every few milliseconds, the
# stack of each running process and prints the most frequent frames.
# Send traffic meanwhile:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/profile_requests.exs")'
defmodule LoadTest.Profile do
  def run(seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    self_pid = self()
    loop(deadline, self_pid, %{}, %{}, 0)
  end

  defp loop(deadline, self_pid, frames, tops, samples) do
    if System.monotonic_time(:millisecond) > deadline do
      {frames, tops, samples}
    else
      {frames, tops} =
        Process.list()
        |> Enum.reject(&(&1 == self_pid))
        |> Enum.reduce({frames, tops}, fn pid, {frames, tops} ->
          case Process.info(pid, [:status, :current_stacktrace]) do
            [status: status, current_stacktrace: stack] when status in [:running, :runnable] ->
              ours = Enum.take(stack, 12)

              frames =
                ours
                |> Enum.map(&frame/1)
                |> Enum.uniq()
                |> Enum.reduce(frames, &Map.update(&2, &1, 1, fn n -> n + 1 end))

              top = ours |> Enum.take(1) |> Enum.map(&frame/1)
              {frames, Map.update(tops, top, 1, &(&1 + 1))}

            _ ->
              {frames, tops}
          end
        end)

      Process.sleep(2)
      loop(deadline, self_pid, frames, tops, samples + 1)
    end
  end

  defp frame({m, f, a, _loc}) when is_list(a), do: "#{inspect(m)}.#{f}/#{length(a)}"
  defp frame({m, f, a, _loc}), do: "#{inspect(m)}.#{f}/#{a}"
end

seconds = String.to_integer(System.get_env("PROFILE_SECONDS", "15"))
{frames, tops, samples} = LoadTest.Profile.run(seconds)
total = tops |> Map.values() |> Enum.sum()
IO.puts("#{samples} rounds, #{total} running-process samples")
IO.puts("--- top frame (where the time is spent)")

tops
|> Enum.sort_by(&elem(&1, 1), :desc)
|> Enum.take(25)
|> Enum.each(fn {frame, n} -> IO.puts("#{String.pad_leading("#{div(n * 100, max(total, 1))}%", 5)} #{frame}") end)

IO.puts("--- anywhere in the stack (inclusive)")

frames
|> Enum.sort_by(&elem(&1, 1), :desc)
|> Enum.take(40)
|> Enum.each(fn {frame, n} -> IO.puts("#{String.pad_leading("#{div(n * 100, max(total, 1))}%", 5)} #{frame}") end)
