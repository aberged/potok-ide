defmodule PotokIdeWeb.ProfileLive.Direct do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.{Discovery, Profile, ProfileFacts}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_profile={@current_profile}
      current_locale={@current_locale}
      available_locales={@available_locales}
      pending_invitations_count={@pending_invitations_count}
      pending_group_join_requests_count={@pending_group_join_requests_count}
      root_group_unread_count={@root_group_unread_count}
      unread_notices_count={@unread_notices_count}
    >
      <div class="flex min-h-0 flex-1 items-center justify-center px-4">
        <div class="text-sm text-base-content/70">{gettext("Opening direct group...")}</div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    current_profile = socket.assigns.current_profile

    socket =
      case findable(socket, id) do
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

            {:error, reason} ->
              socket
              |> put_flash(:error, PotokIdeWeb.ProfileCard.direct_error(reason))
              |> push_navigate(to: ~p"/profiles")
          end
      end

    {:noreply, socket}
  end

  # A link carries only an id, so a stranger gets through only to a profile
  # open to everyone or one it talks to already (`Discovery`); any other is
  # not found.
  defp findable(socket, id) do
    %{current_scope: %{account: account}, current_profile: viewer} = socket.assigns

    with %Profile{} = target <- Social.get_profile(id),
         facts = ProfileFacts.load(account, viewer, target),
         true <- facts.holder? or Discovery.may_find?(facts, target, :id) do
      target
    else
      _hidden_or_none -> nil
    end
  end
end
