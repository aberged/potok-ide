defmodule PotokIdeWeb.RequestLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.ProfileAuth
  @approved_requests_per_page 10
  @created_requests_per_page 10
  @sections ~w(pending approved created)

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :request_search_form,
        to_form(%{"q" => assigns.requests_search_query}, as: :request_search)
      )

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
      full_width
    >
      <.page_container id="requests-page">
        <.page_header id="requests-header" icon="hero-hand-raised">
          {gettext("Requests")}
          <:subtitle>
            {gettext("Group access requests you can approve, and the ones you made.")}
          </:subtitle>
        </.page_header>

        <Components.settings_tabs
          id="requests-sections"
          tabs={sections()}
          current={@section}
          event="set_section"
          tab_id_prefix="requests-tab"
          counts={
            %{
              "pending" => length(@requests),
              "approved" => @approved_requests_pagination.total_count,
              "created" => @created_requests_pagination.total_count
            }
          }
        />

        <%!-- One search for both histories; it does not filter the pending
               requests, so their tab leaves it out. --%>
        <.form
          :if={
            @section != "pending" and
              (@approved_requests_pagination.total_count > 0 or
                 @created_requests_pagination.total_count > 0 or @requests_search_query != "")
          }
          for={@request_search_form}
          id="request-search-form"
          phx-change="search_requests"
          class="mb-3 flex flex-row justify-end"
        >
          <div class="relative w-fit">
            <button
              :if={@requests_search_query != ""}
              id="request-search-reset"
              type="button"
              phx-click="clear_requests_search"
              aria-label={gettext("Clear search")}
              class="absolute left-2 pt-[0.7rem] text-base-content/65 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <.input
              field={@request_search_form[:q]}
              id="request-search-input"
              type="text"
              placeholder={gettext("Search by group or profile")}
              phx-debounce="300"
              autocomplete="off"
              class="bg-base-100/85 h-10 w-12 rounded-full border border-gray-500/50 px-6 pr-10 text-sm transition-all duration-300 ease-in-out focus:w-64 focus:outline-none"
            />
            <div class="absolute right-0 top-0 mr-4 mt-3 text-base-content/70">
              <.icon name="hero-magnifying-glass" class="size-4" />
            </div>
          </div>
        </.form>

        <Components.settings_card
          id="requests-pending"
          tab_id="requests-tab-pending"
          active={@section == "pending"}
          icon="hero-clock"
          title={gettext("Requests to approve")}
          subtitle={gettext("Pending group access requests that your current profile can approve.")}
        >
          <div
            :if={@requests == []}
            class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
          >
            {gettext("No pending approval requests.")}
          </div>

          <div :if={@requests != []} class="space-y-3">
            <div
              :for={request <- @requests}
              id={"approval-request-#{request.id}"}
              class="space-y-3 rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
            >
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
                <span class="inline-flex items-center rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-sky-700 dark:text-sky-300">
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
                  <.button
                    id={"request-accept-#{request.id}"}
                    type="button"
                    phx-click="accept"
                    phx-value-id={request.id}
                    variant="success"
                    size="sm"
                  >
                    {gettext("Accept")}
                  </.button>
                  <.button
                    id={"request-reject-#{request.id}"}
                    type="button"
                    phx-click="reject"
                    phx-value-id={request.id}
                    size="sm"
                  >
                    {gettext("Reject")}
                  </.button>
                </div>
              </div>
            </div>
          </div>
        </Components.settings_card>

        <%!-- A history card off screen holds no list: picking its tab loads it. --%>
        <Components.settings_card
          id="requests-approved"
          tab_id="requests-tab-approved"
          active={@section == "approved"}
          icon="hero-check-badge"
          title={gettext("Approved requests")}
          subtitle={gettext("History of access requests you approved.")}
        >
          <div :if={@section == "approved"} class="space-y-3">
            <div
              :if={@approved_requests_pagination.total_count == 0}
              class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
            >
              {if String.trim(@requests_search_query) == "",
                do: gettext("No approved requests yet."),
                else: gettext("No approved requests match your search.")}
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
                    <span class="inline-flex items-center rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-emerald-700 dark:text-emerald-300">
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

            <.button
              :if={@approved_requests_pagination.has_more?}
              id="approved-requests-load-more"
              type="button"
              phx-click="load_more_approved_requests"
              size="sm"
            >
              {gettext("Load more approved requests")}
            </.button>
          </div>
        </Components.settings_card>

        <Components.settings_card
          id="requests-created"
          tab_id="requests-tab-created"
          active={@section == "created"}
          icon="hero-paper-airplane"
          title={gettext("Requests created by me")}
          subtitle={
            gettext("History of access requests your current profile created and that were approved.")
          }
        >
          <div :if={@section == "created"} class="space-y-3">
            <div
              :if={@created_requests_pagination.total_count == 0}
              class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
            >
              {if String.trim(@requests_search_query) == "",
                do: gettext("No approved requests created by this profile yet."),
                else: gettext("No created requests match your search.")}
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
                        do: "bg-sky-500/10 text-sky-700 dark:text-sky-300",
                        else: "bg-amber-500/10 text-amber-800 dark:text-amber-200"
                      )
                    ]}>
                      {if(request.status == :approved,
                        do: gettext("Approved"),
                        else: gettext("Pending")
                      )}
                    </span>
                    <span>
                      {if(request.status == :approved,
                        do: gettext("Approved on"),
                        else: gettext("Requested on")
                      )}
                    </span>
                    <Components.local_time
                      id={"created-request-timestamp-#{request.id}"}
                      datetime={
                        if(request.status == :approved,
                          do: request.approved_at,
                          else: request.requested_at
                        )
                      }
                      class="text-xs font-thin italic"
                    />
                  </div>
                </div>
              </div>
            </div>

            <.button
              :if={@created_requests_pagination.has_more?}
              id="created-requests-load-more"
              type="button"
              phx-click="load_more_created_requests"
              size="sm"
            >
              {gettext("Load more created requests")}
            </.button>
          </div>
        </Components.settings_card>
      </.page_container>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> assign(:requests_search_query, "")
      |> assign(:section, "pending")
      |> assign(:approved_requests_pagination, default_approved_requests_pagination())
      |> stream(:approved_requests, [], reset: true)
      |> assign(:created_requests_pagination, default_created_requests_pagination())
      |> stream(:created_requests, [], reset: true)
      |> ProfileAuth.sync_profile_subscription()

    {:ok, assign_requests(socket, socket.assigns.current_profile)}
  end

  @impl true
  def handle_event("set_section", %{"section" => section}, socket)
      when section in @sections do
    socket = assign(socket, :section, section)
    profile = socket.assigns.current_profile

    {:noreply,
     case section do
       "pending" -> socket
       "approved" -> refresh_approved_requests(socket, profile)
       "created" -> refresh_created_requests(socket, profile)
     end}
  end

  def handle_event("set_section", _params, socket), do: {:noreply, socket}

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

      approved_page =
        approved_requests_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.requests_search_query
        )

      {:noreply,
       socket
       |> assign(:approved_requests_pagination, pagination_metadata(approved_page))
       |> stream(:approved_requests, approved_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_requests", %{"request_search" => %{"q" => query}}, socket) do
    next_query = normalize_requests_search_query(query)

    if next_query == socket.assigns.requests_search_query do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:requests_search_query, next_query)
       |> assign(:approved_requests_pagination, default_approved_requests_pagination())
       |> assign(:created_requests_pagination, default_created_requests_pagination())
       |> assign_requests(socket.assigns.current_profile)}
    end
  end

  def handle_event("search_requests", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_requests_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:requests_search_query, "")
     |> assign(:approved_requests_pagination, default_approved_requests_pagination())
     |> assign(:created_requests_pagination, default_created_requests_pagination())
     |> assign_requests(socket.assigns.current_profile)}
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

      created_page =
        created_requests_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.requests_search_query
        )

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

    total_count =
      Social.count_approved_group_join_requests_for_approver(profile,
        search: socket.assigns.requests_search_query
      )

    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    # The tab off screen only needs its count; picking it loads the list.
    if socket.assigns.section == "approved" do
      approved_page =
        approved_requests_page(
          profile,
          pagination,
          socket.assigns.requests_search_query,
          total_count
        )

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

    total_count =
      Social.count_approved_group_join_requests_for_requester(profile,
        search: socket.assigns.requests_search_query
      )

    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    if socket.assigns.section == "created" do
      created_page =
        created_requests_page(
          profile,
          pagination,
          socket.assigns.requests_search_query,
          total_count
        )

      socket
      |> assign(:created_requests_pagination, pagination_metadata(created_page))
      |> stream(:created_requests, created_page.entries, reset: true)
    else
      assign(socket, :created_requests_pagination, pagination)
    end
  end

  # The tabs, in order: `{key, panel id, label, danger?}`.
  defp sections do
    [
      {"pending", "requests-pending", pgettext("requests tab", "To approve"), false},
      {"approved", "requests-approved", pgettext("requests tab", "Approved"), false},
      {"created", "requests-created", pgettext("requests tab", "My requests"), false}
    ]
  end

  defp approved_requests_page(%{} = profile, pagination, search, total_count \\ nil) do
    total_count =
      total_count ||
        Social.count_approved_group_join_requests_for_approver(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_approved_group_join_requests_for_approver(profile,
        limit: limit,
        offset: 0,
        search: search
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

  defp created_requests_page(%{} = profile, pagination, search, total_count \\ nil) do
    total_count =
      total_count ||
        Social.count_approved_group_join_requests_for_requester(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_approved_group_join_requests_for_requester(profile,
        limit: limit,
        offset: 0,
        search: search
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

  defp normalize_requests_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_requests_search_query(_), do: ""

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

              {:error, :not_permitted} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   gettext("Your roles in this group do not allow managing requests.")
                 )}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}
            end
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
  end
end
