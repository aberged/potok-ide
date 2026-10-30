defmodule PotokIde.Presence do
  @moduledoc """
  Tracks which profiles have a group page open.

  Viewers do not subscribe to a group's whole presence topic: in a busy group
  every join would reach every viewer, and each of them would re-read the
  whole list. `handle_metas/4` keeps a set of the online `{topic, key}` pairs
  instead and tells only those watching that one profile, on `key_topic/2`,
  when it comes online or goes offline.
  """

  use Phoenix.Presence,
    otp_app: :potok_ide,
    pubsub_server: PotokIde.PubSub

  @online __MODULE__.Online

  def init(_opts) do
    # Owned by the tracker process that calls handle_metas/4, so it goes away
    # together with the presences it mirrors.
    :ets.new(@online, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    for key <- Enum.uniq(Map.keys(joins) ++ Map.keys(leaves)) do
      online? = Map.has_key?(presences, key)

      if online?,
        do: :ets.insert(@online, {{topic, key}}),
        else: :ets.delete(@online, {topic, key})

      Phoenix.PubSub.local_broadcast(
        PotokIde.PubSub,
        key_topic(topic, key),
        {:presence_changed, topic, key, online?}
      )
    end

    {:ok, state}
  end

  @doc "Whether `key` has at least one presence in `topic`."
  def online?(topic, key) do
    :ets.member(@online, {topic, to_string(key)})
  rescue
    ArgumentError -> false
  end

  @doc "The topic on which `{:presence_changed, topic, key, online?}` is sent for one key."
  def key_topic(topic, key), do: "#{topic}:#{key}"
end
