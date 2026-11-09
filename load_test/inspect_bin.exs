# Who holds the BEAM's binary memory: the processes referencing the most
# (unique) binaries, grouped by kind, and the ETS tables by size. Run against
# the live release during a load run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/inspect_bin.exs")'
defmodule LoadTest.InspectBin do
  def run do
    total = div(:erlang.memory(:binary), 1_048_576)

    per_process =
      for pid <- Process.list(),
          {:binary, bins} <- [Process.info(pid, :binary)],
          bins != [] do
        bytes = bins |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        {label(pid), bytes}
      end

    IO.puts("binary memory #{total} MB; held by processes, by kind (a binary shared by several counts in each):")

    per_process
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {kind, sizes} -> {kind, length(sizes), Enum.sum(sizes)} end)
    |> Enum.sort_by(&elem(&1, 2), :desc)
    |> Enum.take(12)
    |> Enum.each(fn {kind, n, bytes} ->
      IO.puts("  #{String.pad_trailing(kind, 48)} #{n} procs, #{div(bytes, 1_048_576)} MB, #{div(bytes, max(n, 1) * 1024)} KB each")
    end)

    IO.puts("ETS tables by memory (MB):")

    :ets.all()
    |> Enum.map(fn tab -> {tab, :ets.info(tab, :name), :ets.info(tab, :memory) || 0} end)
    |> Enum.sort_by(&elem(&1, 2), :desc)
    |> Enum.take(8)
    |> Enum.each(fn {_tab, name, words} ->
      IO.puts("  #{String.pad_trailing(inspect(name), 48)} #{Float.round(words * 8 / 1_048_576, 1)}")
    end)
  end

  defp label(pid) do
    case Process.info(pid, [:registered_name, :dictionary]) do
      [registered_name: name, dictionary: _] when is_atom(name) and name != [] ->
        inspect(name)

      [registered_name: _, dictionary: dict] ->
        cond do
          match?({Phoenix.LiveView, _, _}, dict[:"$process_label"]) ->
            {_, view, _} = dict[:"$process_label"]
            "LV " <> inspect(view)

          initial = dict[:"$initial_call"] ->
            inspect(initial)

          true ->
            "other"
        end

      _ ->
        "dead"
    end
  end
end

LoadTest.InspectBin.run()
