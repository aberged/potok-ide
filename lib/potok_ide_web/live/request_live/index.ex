defmodule PotokIdeWeb.RequestLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.ProfileAuth
  @approved_requests_per_page 10
  @created_requests_per_page 10

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

        <div class="mt-6 card rounded-3xl border border-base-300/70 bg-base-100/70 shadow-sm">
          <div class="card-body gap-4">
            <button
              id="approved-requests-toggle"
              type="button"
              phx-click="toggle_approved_requests"
              class="flex w-full items-center justify-between gap-3 text-left"
              aria-expanded={to_string(@approved_requests_expanded?)}
            >
              <div>
                <h3 class="text-base font-semibold text-base-content">
                  {gettext("Approved requests")}
                </h3>
                <p class="text-sm text-base-content/70">
                  {gettext("History of access requests you approved as the group creator.")}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <span class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-emerald-700">
                  {@approved_requests_pagination.total_count}
                </span>
                <.icon
                  name="hero-chevron-down"
                  class={[
                    "size-5 transition-transform",
                    @approved_requests_expanded? && "rotate-180"
                  ]}
                />
              </div>
            </button>

            <div :if={@approved_requests_expanded?} class="space-y-3">
              <div
                :if={@approved_requests_pagination.total_count == 0}
                class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
              >
                {gettext("No approved requests yet.")}
              </div>

              <div
                :if={@approved_requests_pagination.total_count > 0}
                id="approved-requests"
                phx-update="stream"
                class="space-y-3"
              >
                <div
                  :for={{dom_id, approval} <- @streams.approved_requests}
                  id={dom_id}
                  class="rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
                >
                  <div class="space-y-3">
                    <Components.group_identity
                      group={approval.group}
                      current_profile={@current_profile}
                      avatar_size="size-10"
                      text_class="text-sm"
                    />

                    <Components.profile_identity
                      profile={approval.requester}
                      avatar_size="size-9"
                      text_class="text-sm"
                      title={gettext("Requester")}
                      current_profile={@current_profile}
                      direct_group_link={true}
                    />

                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
                      <span class="inline-flex items-center rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-emerald-700">
                        {gettext("Approved")}
                      </span>
                      <span>{gettext("Approved on")}</span>
                      <Components.local_time
                        id={"request-approved-at-#{approval.id}"}
                        datetime={approval.approved_at}
                        class="text-xs font-thin italic"
                      />
                    </div>
                  </div>
                </div>
              </div>

              <button
                :if={@approved_requests_pagination.has_more?}
                id="approved-requests-load-more"
                type="button"
                phx-click="load_more_approved_requests"
                class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
              >
                {gettext("Load more approved requests")}
              </button>
            </div>
          </div>
        </div>

        <div class="mt-6 card rounded-3xl border border-base-300/70 bg-base-100/70 shadow-sm">
          <div class="card-body gap-4">
            <button
              id="created-requests-toggle"
              type="button"
              phx-click="toggle_created_requests"
              class="flex w-full items-center justify-between gap-3 text-left"
              aria-expanded={to_string(@created_requests_expanded?)}
            >
              <div>
                <h3 class="text-base font-semibold text-base-content">
                  {gettext("Requests created by me")}
                </h3>
                <p class="text-sm text-base-content/70">
                  {gettext(
                    "History of access requests your current profile created and that were approved."
                  )}
                </p>
              </div>
              <div class="flex items-center gap-2">
                <span class="rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-sky-700">
                  {@created_requests_pagination.total_count}
                </span>
                <.icon
                  name="hero-chevron-down"
                  class={[
                    "size-5 transition-transform",
                    @created_requests_expanded? && "rotate-180"
                  ]}
                />
              </div>
            </button>

            <div :if={@created_requests_expanded?} class="space-y-3">
              <div
                :if={@created_requests_pagination.total_count == 0}
                class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
              >
                {gettext("No approved requests created by this profile yet.")}
              </div>

              <div
                :if={@created_requests_pagination.total_count > 0}
                id="created-requests"
                phx-update="stream"
                class="space-y-3"
              >
                <div
                  :for={{dom_id, request} <- @streams.created_requests}
                  id={dom_id}
                  class="rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
                >
                  <div class="space-y-3">
                    <Components.group_identity
                      group={request.group}
                      current_profile={@current_profile}
                      avatar_size="size-10"
                      text_class="text-sm"
                    />

                    <Components.profile_identity
                      :if={request.approver}
                      profile={request.approver}
                      avatar_size="size-9"
                      text_class="text-sm"
                      title={gettext("Approved by")}
                      current_profile={@current_profile}
                      direct_group_link={true}
                    />

                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
                      <span class={[
                        "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em]",
                        if(request.status == :approved,
                          do: "bg-sky-500/10 text-sky-700",
                          else: "bg-amber-500/10 text-amber-700"
                        )
                      ]}>
                        {if(request.status == :approved,
                          do: gettext("Approved"),
                          else: gettext("Pending"))}
                      </span>
                      <span>
                        {if(request.status == :approved,
                          do: gettext("Approved on"),
                          else: gettext("Requested on"))}
                      </span>
                      <Components.local_time
                        id={"created-request-timestamp-#{request.id}"}
                        datetime={if(request.status == :approved,
                          do: request.approved_at,
                          else: request.requested_at)}
                        class="text-xs font-thin italic"
                      />
                    </div>
                  </div>
                </div>
              </div>

              <button
                :if={@created_requests_pagination.has_more?}
                id="created-requests-load-more"
                type="button"
                phx-click="load_more_created_requests"
                class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
              >
                {gettext("Load more created requests")}
              </button>
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
      |> assign(:approved_requests_expanded?, false)
      |> assign(:approved_requests_pagination, default_approved_requests_pagination())
      |> stream(:approved_requests, [], reset: true)
      |> assign(:created_requests_expanded?, false)
      |> assign(:created_requests_pagination, default_created_requests_pagination())
      |> stream(:created_requests, [], reset: true)
      |> ProfileAuth.sync_profile_subscription()

    {:ok, assign_requests(socket, socket.assigns.current_profile)}
  end

  @impl true
  def handle_event("toggle_approved_requests", _params, socket) do
    expanded? = not socket.assigns.approved_requests_expanded?

    {:noreply,
     socket
     |> assign(:approved_requests_expanded?, expanded?)
     |> refresh_approved_requests(socket.assigns.current_profile)}
  end

  def handle_event(
        "load_more_approved_requests",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_approved_requests", _params, socket) do
    if socket.assigns.approved_requests_pagination.has_more? do
      pagination =
        socket.assigns.approved_requests_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      approved_page = approved_requests_page(socket.assigns.current_profile, pagination)

      {:noreply,
       socket
       |> assign(:approved_requests_pagination, pagination_metadata(approved_page))
       |> stream(:approved_requests, approved_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_created_requests", _params, socket) do
    expanded? = not socket.assigns.created_requests_expanded?

    {:noreply,
     socket
     |> assign(:created_requests_expanded?, expanded?)
     |> refresh_created_requests(socket.assigns.current_profile)}
  end

  def handle_event(
        "load_more_created_requests",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_created_requests", _params, socket) do
    if socket.assigns.created_requests_pagination.has_more? do
      pagination =
        socket.assigns.created_requests_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      created_page = created_requests_page(socket.assigns.current_profile, pagination)

      {:noreply,
       socket
       |> assign(:created_requests_pagination, pagination_metadata(created_page))
       |> stream(:created_requests, created_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
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

  defp assign_requests(socket, nil) do
    socket
    |> assign(:requests, [])
    |> assign(:approved_requests_pagination, default_approved_requests_pagination())
    |> stream(:approved_requests, [], reset: true)
    |> assign(:created_requests_pagination, default_created_requests_pagination())
    |> stream(:created_requests, [], reset: true)
  end

  defp assign_requests(socket, profile) do
    socket
    |> assign(:requests, Social.list_pending_group_join_requests_for_approver(profile))
    |> refresh_approved_requests(profile)
    |> refresh_created_requests(profile)
  end

  defp refresh_approved_requests(socket, nil) do
    socket
    |> assign(:approved_requests_pagination, default_approved_requests_pagination())
    |> stream(:approved_requests, [], reset: true)
  end

  defp refresh_approved_requests(socket, profile) do
    pagination = socket.assigns.approved_requests_pagination
    total_count = Social.count_approved_group_join_requests_for_approver(profile)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    if socket.assigns.approved_requests_expanded? do
      approved_page = approved_requests_page(profile, pagination, total_count)

      socket
      |> assign(:approved_requests_pagination, pagination_metadata(approved_page))
      |> stream(:approved_requests, approved_page.entries, reset: true)
    else
      assign(socket, :approved_requests_pagination, pagination)
    end
  end

  defp refresh_created_requests(socket, nil) do
    socket
    |> assign(:created_requests_pagination, default_created_requests_pagination())
    |> stream(:created_requests, [], reset: true)
  end

  defp refresh_created_requests(socket, profile) do
    pagination = socket.assigns.created_requests_pagination
    total_count = Social.count_approved_group_join_requests_for_requester(profile)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    if socket.assigns.created_requests_expanded? do
      created_page = created_requests_page(profile, pagination, total_count)

      socket
      |> assign(:created_requests_pagination, pagination_metadata(created_page))
      |> stream(:created_requests, created_page.entries, reset: true)
    else
      assign(socket, :created_requests_pagination, pagination)
    end
  end

  defp approved_requests_page(%{} = profile, pagination, total_count \\ nil) do
    total_count = total_count || Social.count_approved_group_join_requests_for_approver(profile)
    limit = pagination_limit(pagination)

    entries =
      Social.list_approved_group_join_requests_for_approver(profile,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  defp default_approved_requests_pagination do
    %{
      page: 1,
      per_page: @approved_requests_per_page,
      loaded_count: 0,
      total_count: 0,
      has_more?: false
    }
  end

  defp created_requests_page(%{} = profile, pagination, total_count \\ nil) do
    total_count = total_count || Social.count_approved_group_join_requests_for_requester(profile)
    limit = pagination_limit(pagination)

    entries =
      Social.list_approved_group_join_requests_for_requester(profile,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  defp default_created_requests_pagination do
    %{
      page: 1,
      per_page: @created_requests_per_page,
      loaded_count: 0,
      total_count: 0,
      has_more?: false
    }
  end

  defp pagination_limit(%{page: page, per_page: per_page}), do: page * per_page

  defp pagination_result(pagination, entries, total_count) do
    loaded_count = length(entries)

    pagination
    |> Map.put(:loaded_count, loaded_count)
    |> Map.put(:total_count, total_count)
    |> Map.put(:has_more?, loaded_count < total_count)
    |> Map.put(:entries, entries)
  end

  defp pagination_metadata(%{entries: _entries} = pagination),
    do: Map.delete(pagination, :entries)

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
