defmodule PotokIdeWeb.InvitationLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.ProfileAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          {gettext("Invitations")}
          <:subtitle>{gettext("Pending group invitations for your current profile.")}</:subtitle>
        </.header>

        <div :if={@invitations == []} class="text-base-content/70">
          {gettext("No pending invitations.")}
        </div>

        <div :for={inv <- @invitations} class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title">
              <.link navigate={~p"/groups/#{inv.group.id}"} class="link link-hover">
                {inv.group.name}
              </.link>
            </h3>

            <div class="text-sm text-base-content/70">
              {gettext("Invited by:")} <span class="font-semibold">{inv.inviter.username}</span>
            </div>

            <div class="mt-2">
              <.button phx-click="accept" phx-value-id={inv.id} variant="primary">
                {gettext("Accept")}
              </.button>
            </div>
          </div>
        </div>

        <div><.link navigate={~p"/groups"} class="link">{gettext("Back to Root Group")}</.link></div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> ProfileAuth.sync_profile_subscription()

    {:ok,
     assign(socket, :invitations, Social.list_pending_invitations(socket.assigns.current_profile))}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} = invitation <- Social.get_pending_invitation_for_invitee(invitee, invitation_id),
         {:ok, _invitation} <- Social.accept_group_invitation(invitation, invitee) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Invitation accepted."))
       |> assign(:invitations, Social.list_pending_invitations(invitee))}
    else
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("Invitation not found (or already accepted)."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not accept invitation."))}
    end
  end

  @impl true
  def handle_info(
        {:profile_invitations_updated, _profile_id},
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:profile_invitations_updated, profile_id}, socket)
      when socket.assigns.current_profile.id == profile_id do
    {:noreply,
     assign(socket, :invitations, Social.list_pending_invitations(socket.assigns.current_profile))}
  end

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id and
             is_nil(socket.assigns.current_profile) do
    {:noreply, push_navigate(socket, to: ~p"/profiles")}
  end

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]

    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        socket =
          socket
          |> put_private(:previous_current_profile, current_profile)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        {:noreply, assign(socket, :invitations, Social.list_pending_invitations(current_profile))}
      end,
      fn socket ->
        socket =
          socket
          |> put_private(:previous_current_profile, nil)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}
end
