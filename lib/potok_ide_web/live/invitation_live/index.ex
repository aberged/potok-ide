defmodule PotokIdeWeb.InvitationLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.GroupLive.Show.Components

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="h-[calc(100dvh-4rem)] overflow-y-auto px-4 py-4">
        <.header>
          {gettext("Invitations")}
          <:subtitle>{gettext("Pending group invitations for your current profile.")}</:subtitle>
        </.header>

        <div :if={@invitations == []} class="text-base-content/70">
          {gettext("No pending invitations.")}
        </div>

        <div :for={inv <- @invitations} class="card">
          <div class="card-body">
            <Components.group_identity
              group={inv.group}
              avatar_size="size-12"
              text_class="text-sm"
              unread_count={Map.get(@group_unread_counts, inv.group.id, 0)}
            />

            <div class="text-sm text-base-content/70">
              {gettext("Invited by:")}
              <span class="font-semibold">{inv.inviter.username}</span>
              <Components.local_time
                id={"invitation-inserted-at-#{inv.id}"}
                datetime={inv.inserted_at}
                class="text-xs font-thin italic"
              />
            </div>

            <div :if={is_nil(inv.accepted_at)} class="mt-2">
              <.button phx-click="accept" phx-value-id={inv.id} variant="primary">
                {gettext("Accept")}
              </.button>
            </div>
            <div :if={!is_nil(inv.accepted_at)} class="text-sm text-green-600 mt-1">
              {gettext("Accepted on")}
              <Components.local_time
                id={"invitation-accepted-at-#{inv.id}"}
                datetime={inv.accepted_at}
                class="ml-1"
              />
            </div>
          </div>
        </div>

        <div><.link navigate={~p"/groups"} class="link">{gettext("Back to /")}</.link></div>
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
     socket
     |> assign_invitations(socket.assigns.current_profile)}
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
       |> assign_invitations(invitee)}
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
    {:noreply, assign_invitations(socket, socket.assigns.current_profile)}
  end

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_invitations_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:profile_group_join_requests_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_group_join_requests_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:group_unread_counts_updated, profile_id, _group_id}, socket)
      when not is_nil(socket.assigns.current_profile) and
             socket.assigns.current_profile.id == profile_id do
    {:noreply,
     socket
     |> assign(
       :root_group_unread_count,
       Social.count_group_unread_values(socket.assigns.current_profile, Social.get_root_group!())
     )
     |> maybe_push_root_group_unread_count()
     |> assign_group_unread_counts()}
  end

  def handle_info({:group_unread_counts_updated, _profile_id, _group_id}, socket),
    do: {:noreply, socket}

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

        {:noreply, assign_invitations(socket, current_profile)}
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

  defp assign_invitations(socket, nil) do
    socket
    |> assign(:invitations, [])
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
    |> assign(:group_unread_counts, %{})
  end

  defp assign_invitations(socket, profile) do
    invitations = Social.list_pending_invitations(profile)

    socket
    |> assign(:invitations, invitations)
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
    |> assign(
      :group_unread_counts,
      Social.list_group_unread_counts(profile, Enum.map(invitations, & &1.group))
    )
  end

  defp assign_root_group_unread_count(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :root_group_unread_count, 0)
  end

  defp assign_root_group_unread_count(socket) do
    assign(
      socket,
      :root_group_unread_count,
      Social.count_group_unread_values(socket.assigns.current_profile, Social.get_root_group!())
    )
  end

  defp maybe_push_root_group_unread_count(socket) do
    if connected?(socket) do
      push_event(socket, "root_group_unread_count_updated", %{
        count: socket.assigns.root_group_unread_count
      })
    else
      socket
    end
  end

  defp assign_group_unread_counts(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :group_unread_counts, %{})
  end

  defp assign_group_unread_counts(socket) do
    assign(
      socket,
      :group_unread_counts,
      Social.list_group_unread_counts(
        socket.assigns.current_profile,
        Enum.map(socket.assigns.invitations, & &1.group)
      )
    )
  end
end
