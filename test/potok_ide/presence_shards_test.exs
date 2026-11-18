defmodule PotokIde.PresenceShardsTest do
  @moduledoc """
  The presence tracker in several shards (`:pool_size`): every shard marks
  its own topics online in the one table (`PotokIde.Presence.Online`), and a
  shard that stops takes its marks with it.
  """

  # A test stops a shard, which other tests' presences live in.
  use ExUnit.Case, async: false

  alias PotokIde.Presence

  defp topic(n), do: "presence-shards:#{System.unique_integer([:positive])}:#{n}"

  defp shard_for(topic) do
    pool_size = Application.get_env(:potok_ide, Presence)[:pool_size]
    Process.whereis(Phoenix.Tracker.Shard.name_for_topic(Presence, topic, pool_size))
  end

  # The owner of the table hears of a stopped shard on its own; a few round
  # trips let it.
  defp settled?(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        _ = :sys.get_state(PotokIde.Presence.Online)
        settled?(fun, attempts - 1)
    end
  end

  test "runs in several shards" do
    assert Application.get_env(:potok_ide, Presence)[:pool_size] > 1
  end

  test "topics in every shard mark their keys online, and offline when they go" do
    topics = for n <- 1..12, do: topic(n)
    assert topics |> Enum.map(&shard_for/1) |> Enum.uniq() |> length() > 1

    for topic <- topics do
      :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, "7"))
      {:ok, _ref} = Presence.track(self(), topic, "7", %{})
      assert_receive {:presence_changed, ^topic, "7", true}, 1_000
    end

    assert Enum.all?(topics, &Presence.online?(&1, 7))

    for topic <- topics do
      :ok = Presence.untrack(self(), topic, "7")
      assert_receive {:presence_changed, ^topic, "7", false}, 1_000
    end

    refute Enum.any?(topics, &Presence.online?(&1, 7))
  end

  test "a shard that stops takes its keys with it" do
    topic = topic(0)
    :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, "8"))
    tab = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, _ref} = Presence.track(tab, topic, "8", %{})
    assert_receive {:presence_changed, ^topic, "8", true}, 1_000

    shard = shard_for(topic)
    ref = Process.monitor(shard)
    Process.exit(shard, :kill)
    assert_receive {:DOWN, ^ref, :process, ^shard, :killed}

    assert settled?(fn -> not Presence.online?(topic, 8) end)
    send(tab, :stop)
  end
end
