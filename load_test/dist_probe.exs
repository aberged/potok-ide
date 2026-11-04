# What one value costs between two nodes, measured on a quiet cluster. Started
# by `./run.sh --profile cluster --scenario probe` on the first node:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/dist_probe.exs"); LoadTest.DistProbe.run()'
#
# For groups of about 10, 100, 1000 and 10000 members it posts @values values and
# reads the distribution socket to the other node before and after. An idle
# period of the same length, measured first, gives the traffic that has nothing
# to do with the values (ticks, tracker heartbeats) and is subtracted.
defmodule LoadTest.DistProbe do
  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupMembership, Profile}

  @values 20
  @sizes [10, 100, 1000, 10_000]
  # Long enough for the work a value starts in the background to end.
  @settle_ms 3_000

  def run do
    # Node.list/0 leaves out the hidden node of this rpc.
    [peer] = Node.list()
    port = :erlang.system_info(:dist_ctrl)[peer]
    IO.puts("peer #{peer}, #{@values} values per group")

    idle = delta(port, fn -> Process.sleep(@settle_ms) end)
    idle_rate = per_ms(idle, @settle_ms)
    print("idle #{@settle_ms} ms", idle, 1)

    Enum.each(@sizes, fn size ->
      {group, members} = group_of_about(size)
      poster = poster(group)

      {ms, sent} =
        :timer.tc(
          fn ->
            delta(port, fn ->
              for n <- 1..@values do
                {:ok, _value} =
                  Social.create_value(poster, group, %{
                    "content" => "probe #{n}",
                    "content_format" => :markdown
                  })
              end

              Process.sleep(@settle_ms)
            end)
          end,
          :millisecond
        )

      print("#{members} members", minus(sent, scale(idle_rate, ms)), @values)
    end)
  end

  defp group_of_about(size) do
    {group_id, members} =
      from(m in GroupMembership,
        join: g in Group,
        on: g.id == m.group_id,
        where: not g.is_root and not g.is_direct,
        group_by: m.group_id,
        order_by: fragment("abs(count(*) - ?)", ^size),
        limit: 1,
        select: {m.group_id, count()}
      )
      |> Repo.one!()

    {Social.get_group!(group_id), members}
  end

  defp poster(%Group{id: group_id}) do
    from(p in Profile,
      join: m in GroupMembership,
      on: m.profile_id == p.id,
      where: m.group_id == ^group_id,
      limit: 1
    )
    |> Repo.one!()
  end

  defp delta(port, fun) do
    before = counters(port)
    fun.()
    Map.merge(counters(port), before, fn _key, now, then -> now - then end)
  end

  defp counters(port) do
    {:ok, stats} = :inet.getstat(port, [:send_oct, :send_cnt])
    Map.new(stats)
  end

  defp per_ms(stats, ms), do: Map.new(stats, fn {key, value} -> {key, value / ms} end)
  defp scale(rates, ms), do: Map.new(rates, fn {key, value} -> {key, value * ms} end)

  defp minus(stats, other),
    do: Map.new(stats, fn {key, value} -> {key, max(value - other[key], 0)} end)

  defp print(label, stats, per) do
    IO.puts(
      "#{String.pad_trailing(label, 16)} #{round(stats.send_cnt / per)} messages, " <>
        "#{round(stats.send_oct / per)} bytes" <> if(per > 1, do: " per value", else: "")
    )
  end
end
