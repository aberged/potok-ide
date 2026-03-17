defmodule PotokIdeWeb.InvitationLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social

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
end
