defmodule PotokIde.PresenceTest do
  use ExUnit.Case, async: true

  alias PotokIde.Presence

  test "tells the watchers of a key when it comes online and when its last presence leaves" do
    topic = "presence-test:#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, "7"))
    refute Presence.online?(topic, 7)

    {:ok, _ref} = Presence.track(self(), topic, "7", %{})
    assert_receive {:presence_changed, ^topic, "7", true}, 1_000
    assert Presence.online?(topic, 7)

    other_tab = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, _ref} = Presence.track(other_tab, topic, "7", %{})
    assert_receive {:presence_changed, ^topic, "7", true}, 1_000

    # Still open in the other tab.
    :ok = Presence.untrack(self(), topic, "7")
    assert_receive {:presence_changed, ^topic, "7", true}, 1_000
    assert Presence.online?(topic, 7)

    monitor = Process.monitor(other_tab)
    send(other_tab, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^other_tab, :normal}
    assert_receive {:presence_changed, ^topic, "7", false}, 1_000
    refute Presence.online?(topic, 7)
  end

  test "does not tell the watchers of other keys" do
    topic = "presence-test:#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, "8"))

    {:ok, _ref} = Presence.track(self(), topic, "9", %{})

    refute_receive {:presence_changed, _topic, _key, _online?}, 200
  end
end
