# The binary memory no process holds: TCP ports (driver buffers of every open
# socket) and the binaries kept in PotokIde.Cache (ETS counts only their
# headers). Run against the live release during a load run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/inspect_ports.exs")'
defmodule LoadTest.InspectPorts do
  def run do
    tcp =
      Enum.filter(:erlang.ports(), fn port ->
        match?({:name, ~c"tcp_inet"}, :erlang.port_info(port, :name))
      end)

    memory =
      tcp
      |> Enum.map(fn port ->
        case :erlang.port_info(port, :memory) do
          {:memory, bytes} -> bytes
          _ -> 0
        end
      end)
      |> Enum.sum()

    queued =
      tcp
      |> Enum.map(fn port ->
        case :erlang.port_info(port, :queue_size) do
          {:queue_size, bytes} -> bytes
          _ -> 0
        end
      end)
      |> Enum.sum()

    IO.puts(
      "binary memory #{div(:erlang.memory(:binary), 1_048_576)} MB; #{length(tcp)} tcp ports: " <>
        "port_info memory #{div(memory, 1024)} KB total, output queues #{div(queued, 1024)} KB"
    )

    tcp
    |> Enum.take_random(5)
    |> Enum.each(fn port ->
      IO.puts("  sample #{inspect(port)} #{inspect(:inet.getopts(port, [:buffer, :recbuf, :sndbuf, :active]))}")
    end)

    cache_bytes =
      try do
        :ets.foldl(fn entry, acc -> acc + binary_bytes(entry) end, 0, PotokIde.Cache)
      catch
        _, _ -> :unknown
      end

    IO.puts(
      "PotokIde.Cache: #{:ets.info(PotokIde.Cache, :size)} entries, " <>
        "binaries in them #{if is_integer(cache_bytes), do: div(cache_bytes, 1024), else: cache_bytes} KB"
    )
  end

  defp binary_bytes(term) when is_binary(term), do: byte_size(term)
  defp binary_bytes(term) when is_tuple(term), do: term |> Tuple.to_list() |> binary_bytes()
  defp binary_bytes(term) when is_list(term), do: Enum.reduce(term, 0, &(&2 + binary_bytes(&1)))

  defp binary_bytes(term) when is_map(term),
    do: :maps.fold(fn k, v, acc -> acc + binary_bytes(k) + binary_bytes(v) end, 0, term)

  defp binary_bytes(_term), do: 0
end

LoadTest.InspectPorts.run()
