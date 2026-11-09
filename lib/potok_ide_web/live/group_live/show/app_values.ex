defmodule PotokIdeWeb.GroupLive.Show.AppValues do
  @moduledoc """
  Hands an app's frame what changed in its collections
  (`PotokIde.Social.AppData`), as far as this page's viewer may see it.

  Only the frame of the app the value belongs to gets it, and only while it is
  on screen. A value goes to its author, the app's editors and the roles that
  read the collection, by the rule it was written under, so the page asks the
  database nothing. Someone else's anonymous value comes without its author.
  A new config comes as its revision only: a form can be big and an editor
  saves it every few seconds, so the app reads it again when it needs it.
  """

  alias PotokIde.Social.ValueRules
  alias PotokIdeWeb.GroupLive.Show
  alias PotokIdeWeb.GroupLive.Show.AppHost

  def announce(socket, event, payload) do
    with true <- Show.description_visible?(socket.assigns),
         true <- own_app?(socket.assigns, payload.alt_id),
         %{} = message <- message(event, payload, socket.assigns) do
      AppHost.push(socket, "app_value", message)
    else
      _not_for_this_frame -> socket
    end
  end

  defp own_app?(%{active_alt_description: alt}, alt_id), do: ((alt && alt.id) || nil) == alt_id

  defp message(:config, payload, _assigns),
    do: %{event: "config", collection: "config", id: payload.id, revision: payload.revision}

  defp message(:cleared, payload, _assigns),
    do: %{event: "cleared", collection: payload.collection}

  defp message(:regraded, payload, _assigns),
    do: %{event: "regraded", collection: payload.collection}

  defp message(:deleted, payload, assigns) do
    if sees?(assigns, payload.creator_id, payload.read),
      do: %{event: "deleted", collection: payload.collection, id: payload.id}
  end

  defp message(event, %{value: value, read: read}, assigns) when event in [:created, :updated] do
    if sees?(assigns, value.creator_id, read) do
      %{
        event: Atom.to_string(event),
        collection: value.collection,
        value: present(value, read, assigns)
      }
    end
  end

  defp message(_event, _payload, _assigns), do: nil

  defp sees?(%{current_profile: profile} = assigns, creator_id, read),
    do: own?(profile, creator_id) or full_reader?(assigns.access, read)

  defp own?(nil, _creator_id), do: false
  defp own?(profile, creator_id), do: profile.id == creator_id

  defp full_reader?(access, read),
    do:
      ValueRules.manage?(access) or
        (access.member? and Enum.any?(read, &(&1 in access.role_keys)))

  # An author reads their own score back with the list call, as what they may
  # see of it depends on the config of the moment.
  defp present(value, read, %{current_profile: profile, access: access}) do
    own? = own?(profile, value.creator_id)
    payload = Show.value_payload(value)

    payload =
      if value.anonymous and not own?,
        do: %{payload | creator_id: nil, creator_username: nil},
        else: payload

    if full_reader?(access, read), do: payload, else: %{payload | managed: nil}
  end
end
