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
      if (connected?(socket) and current_scope) && current_scope.account do
        Social.subscribe_account(current_scope.account)

        attach_hook(socket, :sync_current_profile, :handle_info, fn
          {:account_profiles_updated, account_id}, socket ->
            if socket.assigns.current_scope.account.id == account_id do
              account = Accounts.get_account!(account_id)
              current_profile = Social.get_account_current_profile(account)

              socket =
                socket
                |> Phoenix.Component.assign(:current_scope, %{
                  socket.assigns.current_scope
                  | account: account
                })
                |> Phoenix.Component.assign(:current_profile, current_profile)
                |> push_current_profile_updated(current_profile)

              {:cont, socket}
            else
              {:cont, socket}
            end

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
    if connected?(socket) do
      current_profile = socket.assigns[:current_profile]

      if previous_profile &&
           (is_nil(current_profile) or previous_profile.id != current_profile.id) do
        Social.unsubscribe_profile(previous_profile)
      end

      if current_profile &&
           (is_nil(previous_profile) or previous_profile.id != current_profile.id) do
        Social.subscribe_profile(current_profile)
      end
    end

    socket
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

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil
end
