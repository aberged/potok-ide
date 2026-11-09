# What one `group_updated` on the root group costs while users are online:
# a new direct chat broadcasts it (Social.get_or_create_direct_group), and so
# does a top-level group created, edited or deleted. Every open root page then
# reloads. Run during a load run:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/probe_root_reload.exs")'
#
# Prints the BEAM's CPU time over 5 s with nothing extra, then over the 5 s
# after each of three new direct chats, and how many root pages were open.
defmodule LoadTest.ProbeRootReload do
  import Ecto.Query
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Profile

  @window_ms 5_000

  def run do
    root = Social.get_root_group!()
    root_pages = count_root_pages(root.id)
    baseline = cpu_ms(fn -> :ok end)
    IO.puts("root pages open: #{root_pages}; baseline CPU in #{@window_ms} ms: #{baseline} ms")

    for i <- 1..3 do
      [a, b] = Repo.all(from p in Profile, order_by: fragment("random()"), limit: 2)

      used =
        cpu_ms(fn ->
          {:ok, _group} = Social.get_or_create_direct_group(a, b)
        end)

      IO.puts("new direct chat #{i}: CPU in the next #{@window_ms} ms: #{used} ms (#{used - baseline} ms over baseline)")
      Process.sleep(5_000)
    end
  end

  # BEAM CPU time (all schedulers) spent while `fun` runs and the window after it.
  defp cpu_ms(fun) do
    {before, _} = :erlang.statistics(:runtime)
    fun.()
    Process.sleep(@window_ms)
    {after_ms, _} = :erlang.statistics(:runtime)
    after_ms - before
  end

  # Pages subscribed to the root group's topic (Social's `groups:<id>`): the
  # root pages. Reading the registry copies nothing out of the LiveViews.
  defp count_root_pages(root_id) do
    PotokIde.PubSub |> Registry.lookup("groups:#{root_id}") |> length()
  end
end

LoadTest.ProbeRootReload.run()
