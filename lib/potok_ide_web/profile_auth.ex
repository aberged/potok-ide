defmodule PotokIdeWeb.ProfileAuth do
  @moduledoc "LiveView helpers for loading and requiring the current Profile."

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.LiveView

  alias PotokIde.Accounts
  alias PotokIde.Social

  def on_mount(:mount_current_profile, _params, _session, socket) do
    current_scope = socket.assigns[:current_scope]

    socket =
      Phoenix.Component.assign_new(socket, :current_profile, fn ->
        case current_scope do
          %{account: account} when not is_nil(account) ->
            Social.get_account_current_profile(account)

          _ ->
            nil
        end
      end)

    socket =
      Phoenix.Component.assign_new(socket, :pending_invitations_count, fn ->
        pending_invitations_count(socket.assigns[:current_profile])
      end)

    socket =
      Phoenix.Component.assign_new(socket, :root_group_unread_count, fn ->
        root_group_unread_count(socket.assigns[:current_profile])
      end)

    socket = sync_profile_subscription(socket)

    socket =
      if (connected?(socket) and current_scope) && current_scope.account do
        Social.subscribe_account(current_scope.account)

        attach_hook(socket, :sync_current_profile, :handle_info, fn
          {:account_profiles_updated, account_id}, socket ->
            if socket.assigns.current_scope.account.id == account_id do
              previous_profile = socket.assigns.current_profile
              account = Accounts.get_account!(account_id)
              current_profile = Social.get_account_current_profile(account)

              socket =
                socket
                |> Phoenix.Component.assign(:current_scope, %{
                  socket.assigns.current_scope
                  | account: account
                })
                |> Phoenix.Component.assign(:current_profile, current_profile)
                |> Phoenix.Component.assign(
                  :pending_invitations_count,
                  pending_invitations_count(current_profile)
                )
                |> Phoenix.Component.assign(
                  :root_group_unread_count,
                  root_group_unread_count(current_profile)
                )
                |> sync_profile_subscription(previous_profile)
                |> push_current_profile_updated(current_profile)
                |> push_root_group_unread_count_updated(root_group_unread_count(current_profile))
                |> push_pending_invitations_count_updated(
                  pending_invitations_count(current_profile)
                )

              {:cont, socket}
            else
              {:cont, socket}
            end

          {:profile_invitations_updated, profile_id},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            count = pending_invitations_count(current_profile)

            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_invitations_count, count)
             |> push_pending_invitations_count_updated(count)}

          {:pending_invitations_count_updated, profile_id, count},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_invitations_count, count)
             |> push_pending_invitations_count_updated(count)}

          {:group_unread_counts_updated, profile_id, _group_id},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            count = root_group_unread_count(current_profile)

            {:cont,
             socket
             |> Phoenix.Component.assign(:root_group_unread_count, count)
             |> push_root_group_unread_count_updated(count)}

          _message, socket ->
            {:cont, socket}
        end)
      else
        socket
      end

    {:cont, socket}
  end

  def on_mount(:require_profile, _params, _session, socket) do
    if socket.assigns[:current_profile] do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Please select or create a profile first."))
       |> redirect(to: "/profiles")}
    end
  end

  def handle_current_profile_change(socket, on_present, on_missing)
      when is_function(on_present, 2) and is_function(on_missing, 1) do
    case socket.assigns.current_profile do
      nil -> on_missing.(socket)
      current_profile -> on_present.(socket, current_profile)
    end
  end

  def sync_profile_subscription(socket, previous_profile \\ nil) do
    current_profile = socket.assigns[:current_profile]
    subscribed_profile_id = socket.private[:subscribed_profile_id]

    socket =
      if connected?(socket) do
        if is_integer(subscribed_profile_id) and
             (is_nil(current_profile) or subscribed_profile_id != current_profile.id) do
          profile_to_unsubscribe = previous_profile || %{id: subscribed_profile_id}
          Social.unsubscribe_profile(profile_to_unsubscribe)
        end

        if current_profile && current_profile.id != subscribed_profile_id do
          Social.subscribe_profile(current_profile)
        end

        socket
      else
        socket
      end

    put_private(socket, :subscribed_profile_id, current_profile && current_profile.id)
  end

  defp push_current_profile_updated(socket, nil) do
    push_event(socket, "current_profile_updated", %{username: nil, profile_picture_url: nil})
  end

  defp push_current_profile_updated(socket, profile) do
    push_event(socket, "current_profile_updated", %{
      username: profile.username,
      profile_picture_url: profile_picture_url(profile)
    })
  end

  defp push_pending_invitations_count_updated(socket, count) do
    push_event(socket, "pending_invitations_count_updated", %{count: count})
  end

  defp push_root_group_unread_count_updated(socket, count) do
    push_event(socket, "root_group_unread_count_updated", %{count: count})
  end

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil

  defp pending_invitations_count(nil), do: 0
  defp pending_invitations_count(profile), do: Social.count_pending_invitations(profile)

  defp root_group_unread_count(nil), do: 0

  defp root_group_unread_count(profile) do
    Social.count_group_unread_values(profile, Social.get_root_group!())
  end
end
