defmodule PotokIdeWeb.ProfileAuth do
  @moduledoc "LiveView helpers for loading and requiring the current Profile."

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias PotokIde.Social

  def on_mount(:mount_current_profile, _params, _session, socket) do
    current_scope = socket.assigns[:current_scope]

    current_profile =
      case current_scope do
        %{account: account} when not is_nil(account) ->
          Social.get_account_current_profile(account)

        _ ->
          nil
      end

    {:cont, assign(socket, :current_profile, current_profile)}
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
end
