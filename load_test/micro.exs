# One-off costs on an idle app, over `rpc` (see README.md): how long one link
# card and one password check take on this container's CPU. PNG avatars are
# timed with curl from the host; peak memory comes from `memwatch.sh`.
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/micro.exs")'
defmodule LoadTest.Micro do
  import Ecto.Query
  alias PotokIde.{LinkCards, Repo}
  alias PotokIde.Social.Group

  def run do
    public =
      Repo.all(
        from g in Group,
          where: g.is_public and not g.is_direct and is_nil(g.parent_value_id),
          order_by: g.id,
          limit: 3
      )

    for group <- public do
      card = LinkCards.group_card(group)
      {us, result} = :timer.tc(fn -> LinkCards.image(card) end)
      IO.puts("card group=#{group.id} ms=#{div(us, 1000)} result=#{inspect(elem(result, 0))}")
    end

    IO.puts("public_group_ids=#{Enum.map_join(public, ",", & &1.id)}")
    hash = Pbkdf2.hash_pwd_salt("load test password")

    for _ <- 1..3 do
      {us, true} = :timer.tc(fn -> Pbkdf2.verify_pass("load test password", hash) end)
      IO.puts("pbkdf2_verify ms=#{div(us, 1000)}")
    end
  end
end

LoadTest.Micro.run()
