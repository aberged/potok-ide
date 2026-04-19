defmodule PotokIdeWeb.RequestLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.ProfileAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="h-[calc(100dvh-4rem)] overflow-y-auto px-4 py-4">
        <.header>
          {gettext("Requests")}
          <:subtitle>
            {gettext("Pending group access requests that your current profile can approve.")}
          </:subtitle>
        </.header>

        <div :if={@requests == []} class="text-base-content/70">
          {gettext("No pending approval requests.")}
        </div>

        <div
          :for={request <- @requests}
          id={"approval-request-#{request.id}"}
          class="card rounded-3xl border border-base-300/70 bg-base-100/80 shadow-sm"
        >
          <div class="card-body gap-3">
            <Components.group_identity
              group={request.group}
              current_profile={@current_profile}
              avatar_size="size-12"
              text_class="text-sm"
            />
            <Components.profile_identity
              profile={request.requester}
              avatar_size="size-10"
              text_class="text-sm"
              title={gettext("Requester")}
              current_profile={@current_profile}
              direct_group_link={true}
            />
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
              <span class="inline-flex items-center rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-sky-700">
                {gettext("Pending")}
              </span>
              <span>{gettext("Review this access request for the selected group.")}</span>
            </div>

            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="text-sm text-base-content/70">
                {gettext("Requested on")}
                <Components.local_time
                  id={"request-inserted-at-#{request.id}"}
                  datetime={request.inserted_at}
                  class="ml-1 text-xs font-thin italic"
                />
              </div>

              <div class="flex items-center gap-2">
                <button
                  id={"request-accept-#{request.id}"}
                  type="button"
                  phx-click="accept"
                  phx-value-id={request.id}
                  class="btn btn-sm rounded-full border border-emerald-500/40 bg-emerald-500/10 text-emerald-700 hover:border-emerald-500/60 hover:bg-emerald-500/15"
                >
                  {gettext("Accept")}
                </button>
                <button
                  id={"request-reject-#{request.id}"}
                  type="button"
                  phx-click="reject"
                  phx-value-id={request.id}
                  class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
                >
                  {gettext("Reject")}
                </button>
              </div>
            </div>
          </div>
        </div>
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

    {:ok, assign_requests(socket, socket.assigns.current_profile)}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    handle_request_action(
      socket,
      id,
      &Social.accept_group_join_request/3,
      gettext("Access request accepted.")
    )
  end

  def handle_event("reject", %{"id" => id}, socket) do
    handle_request_action(
      socket,
      id,
      &Social.reject_group_join_request/3,
      gettext("Access request rejected.")
    )
  end

  @impl true
  def handle_info(
        {:profile_group_join_requests_updated, _profile_id},
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:profile_group_join_requests_updated, profile_id}, socket)
      when socket.assigns.current_profile.id == profile_id do
    {:noreply, assign_requests(socket, socket.assigns.current_profile)}
  end

  def handle_info({:profile_group_join_requests_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_group_join_requests_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_invitations_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

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

        {:noreply, assign_requests(socket, current_profile)}
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

  defp assign_requests(socket, nil), do: assign(socket, :requests, [])

  defp assign_requests(socket, profile) do
    assign(socket, :requests, Social.list_pending_group_join_requests_for_approver(profile))
  end

  defp handle_request_action(socket, id, action, success_message)
       when is_function(action, 3) do
    current_profile = socket.assigns.current_profile

    case Integer.parse(id) do
      {request_id, ""} ->
        case Enum.find(socket.assigns.requests, &(&1.id == request_id)) do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("Access request not found."))}

          request ->
            case action.(current_profile, request.group, request.id) do
              {:ok, _result} ->
                {:noreply,
                 socket
                 |> put_flash(:info, success_message)
                 |> assign_requests(current_profile)}

              {:error, :request_not_found} ->
                {:noreply, put_flash(socket, :error, gettext("Access request not found."))}

              {:error, :not_group_creator} ->
                {:noreply,
                 put_flash(socket, :error, gettext("Only the group creator can manage requests."))}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}
            end
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
  end
end
