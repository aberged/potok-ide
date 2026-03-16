defmodule PotokIdeWeb.GroupLive.Root do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social

  @impl true
  def mount(_params, _session, socket) do
    root = Social.get_root_group!()
    {:ok, push_navigate(socket, to: ~p"/groups/#{root.id}")}
  end
end
