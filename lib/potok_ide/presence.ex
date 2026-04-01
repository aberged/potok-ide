defmodule PotokIde.Presence do
  use Phoenix.Presence,
    otp_app: :potok_ide,
    pubsub_server: PotokIde.PubSub

  def init(_opts), do: {:ok, %{}}

  def handle_metas(topic, _diff, _presences, state) do
    Phoenix.PubSub.local_broadcast(PotokIde.PubSub, topic, {:presence_updated, topic})
    {:ok, state}
  end
end
