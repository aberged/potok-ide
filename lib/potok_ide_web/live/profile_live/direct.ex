defmodule PotokIdeWeb.ProfileLive.Direct do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100dvh-4rem)] items-center justify-center px-4">
        <div class="text-sm text-base-content/70">{gettext("Opening direct group...")}</div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    current_profile = socket.assigns.current_profile

    socket =
      case Social.get_profile(id) do
        nil ->
          socket
          |> put_flash(:error, gettext("Profile not found."))
          |> push_navigate(to: ~p"/profiles")

        %{id: profile_id} when profile_id == current_profile.id ->
          socket
          |> put_flash(:error, gettext("Choose another profile to open a direct group."))
          |> push_navigate(to: ~p"/profiles")

        target_profile ->
          case Social.get_or_create_direct_group(current_profile, target_profile) do
            {:ok, group} ->
              push_navigate(socket, to: ~p"/groups/#{group.id}/values")

            {:error, _reason} ->
              socket
              |> put_flash(:error, gettext("Unable to open a direct group right now."))
              |> push_navigate(to: ~p"/profiles")
          end
      end

    {:noreply, socket}
  end
end
