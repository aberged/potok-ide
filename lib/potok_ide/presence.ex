defmodule PotokIde.Presence do
  @moduledoc """
  Tracks which profiles have a group page open.

  Viewers do not subscribe to a group's whole presence topic: in a busy group
  every join would reach every viewer, and each of them would re-read the
  whole list. `handle_metas/4` keeps a set of the online `{topic, key}` pairs
  instead (`PotokIde.Presence.Online`) and tells only those watching that one
  profile, on `key_topic/2`, when it comes online or goes offline.

  The tracker runs in `:pool_size` shards (config), each with the topics that
  hash to it, so one busy shard does not hold up every page's join. Every
  node of a cluster must run the same number.
  """

  use Phoenix.Presence,
    otp_app: :potok_ide,
    pubsub_server: PotokIde.PubSub

  alias PotokIde.Presence.Online

  def init(_opts), do: {:ok, %{}}

  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    for key <- Enum.uniq(Map.keys(joins) ++ Map.keys(leaves)) do
      online? = Map.has_key?(presences, key)

      Online.put(topic, key, online?)

      Phoenix.PubSub.local_broadcast(
        PotokIde.PubSub,
        key_topic(topic, key),
        {:presence_changed, topic, key, online?}
      )
    end

    {:ok, state}
  end

  @doc "Whether `key` has at least one presence in `topic`."
  def online?(topic, key), do: Online.member?(topic, to_string(key))

  @doc "The topic on which `{:presence_changed, topic, key, online?}` is sent for one key."
  def key_topic(topic, key), do: "#{topic}:#{key}"
end
