defmodule PotokIdeWeb.PushClear do
  @moduledoc """
  Tells a page to clear a conversation's notifications from its device, as
  messaging apps do once it is read (`assets/js/notification_tray.js`).

  The group page sends it when it marks the chat read or shows the notices.
  Every other page of the profile sends it on
  `{:group_unread_counts_updated, profile_id, group_id}`
  (`PotokIdeWeb.ProfileAuth`), which another page of the profile broadcasts
  when it reads the chat or writes in it. So a phone with Potok open clears
  what was read on the computer; a device without Potok open keeps its
  notifications, as a browser may show no push without a notification.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  @chat_kinds ~w(message mention reply reaction)

  @doc "Clears the notifications of `group_id`'s chat: messages, mentions, replies, reactions."
  def chat(socket, group_id) when is_integer(group_id),
    do: push_event(socket, "push:clear", %{group_id: group_id, kinds: @chat_kinds})

  def chat(socket, _group_id), do: socket

  @doc "Clears the notifications of `group_id`'s notices."
  def notices(socket, group_id) when is_integer(group_id),
    do: push_event(socket, "push:clear", %{group_id: group_id, kinds: ["notice"]})

  def notices(socket, _group_id), do: socket
end
