defmodule PotokIdeWeb.InvitationLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.GroupLive.Show.Components
  @invitations_per_page 20
  @sent_invitations_per_page 20

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :invitation_search_form,
        to_form(%{"q" => assigns.invitations_search_query}, as: :invitation_search)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative h-[calc(100dvh-4rem)] overflow-y-auto px-4 py-4">
        <.header>
          {gettext("Invitations")}
          <:subtitle>
            {gettext("Received and sent group invitations for your current profile.")}
          </:subtitle>
        </.header>

        <.form
          :if={
            @invitations_pagination.total_count > 0 or
              @sent_invitations_pagination.total_count > 0 or @invitations_search_query != ""
          }
          for={@invitation_search_form}
          id="invitation-search-form"
          phx-change="search_invitations"
          class="mb-3 flex flex-row justify-end sticky right-4 top-1 z-45"
        >
          <div class="relative w-fit">
            <button
              :if={@invitations_search_query != ""}
              id="invitation-search-reset"
              type="button"
              phx-click="clear_invitations_search"
              aria-label={gettext("Clear search")}
              class="absolute left-2 pt-[0.7rem] text-base-content/60 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <.input
              field={@invitation_search_form[:q]}
              id="invitation-search-input"
              type="text"
              placeholder={gettext("Search by group or profile")}
              phx-debounce="300"
              autocomplete="off"
              class="bg-base-100/85 h-10 w-12 rounded-full border border-gray-500/50 px-6 pr-10 text-sm transition-all duration-300 ease-in-out focus:w-64 focus:outline-none"
            />
            <div class="absolute right-0 top-0 mr-4 mt-4">
              <svg class="h-4 w-4 fill-current" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
                <path d="M12.9 14.32a8 8 0 1 1 1.41-1.41l5.35 5.33-1.42 1.42-5.33-5.34zM8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12z">
                </path>
              </svg>
            </div>
          </div>
        </.form>

        <div class="space-y-6">
          <div class="card rounded-3xl border border-base-300/70 bg-base-100/70 shadow-sm">
            <div class="card-body gap-4">
              <button
                id="invitations-toggle"
                type="button"
                phx-click="toggle_invitations"
                class="flex w-full items-center justify-between gap-3 text-left"
                aria-expanded={to_string(@invitations_expanded?)}
              >
                <div>
                  <h3 class="text-base font-semibold text-base-content">
                    {gettext("Invitations for me")}
                  </h3>
                  <p class="text-sm text-base-content/70">
                    {gettext("Invitations addressed to your current profile.")}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <span class="rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-sky-700">
                    {@invitations_pagination.total_count}
                  </span>
                  <.icon
                    name="hero-chevron-down"
                    class={[
                      "size-5 transition-transform",
                      @invitations_expanded? && "rotate-180"
                    ]}
                  />
                </div>
              </button>

              <div :if={@invitations_expanded?} class="space-y-4">
                <div
                  :if={@invitations_pagination.total_count == 0}
                  class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
                >
                  {if String.trim(@invitations_search_query) == "",
                    do: gettext("No pending invitations."),
                    else: gettext("No invitations match your search.")}
                </div>

                <div :if={@invitations_pagination.total_count > 0} class="space-y-4">
                  <div id="invitations" phx-update="stream" class="space-y-4">
                    <div
                      :for={{dom_id, inv} <- @streams.invitations}
                      id={dom_id}
                      class="card rounded-2xl border border-base-300/70 bg-base-100/80"
                    >
                      <div class="card-body relative mb-0 p-3">
                        <Components.group_identity
                          group={inv.group}
                          current_profile={@current_profile}
                          avatar_size="size-12"
                          text_class="text-sm"
                          unread_count={Map.get(@group_unread_counts, inv.group.id, 0)}
                          highlight_query={@invitations_search_query}
                        />

                        <div class="text-sm text-base-content/70">
                          {gettext("Invited by:")}
                          <Components.highlighted_text
                            text={inv.inviter.username}
                            query={@invitations_search_query}
                            class="font-semibold"
                          />
                          <Components.local_time
                            id={"invitation-inserted-at-#{inv.id}"}
                            datetime={inv.inserted_at}
                            class="text-xs font-thin italic"
                          />
                        </div>

                        <div :if={is_nil(inv.accepted_at)} class="mt-2 flex flex-wrap gap-2">
                          <.button
                            id={"invitation-accept-#{inv.id}"}
                            phx-click="accept"
                            phx-value-id={inv.id}
                            variant="primary"
                          >
                            {gettext("Accept")}
                          </.button>
                        </div>
                        <div :if={!is_nil(inv.accepted_at)} class="mt-1 text-sm text-green-600">
                          {gettext("Accepted on")}
                          <Components.local_time
                            id={"invitation-accepted-at-#{inv.id}"}
                            datetime={inv.accepted_at}
                            class="ml-1"
                          />
                        </div>
                        <.button
                          id={"invitation-delete-#{inv.id}"}
                          phx-click="delete_invitation"
                          phx-value-id={inv.id}
                          data-confirm={gettext("Are you sure you want to delete this invitation?")}
                          class="absolute right-0 inline-flex items-center rounded-full p-1 px-2 text-base-content/55 transition-colors hover:bg-base-300 hover:text-error"
                        >
                          <.icon name="hero-trash" class="size-4" />
                        </.button>
                      </div>
                    </div>
                  </div>

                  <button
                    :if={@invitations_pagination.has_more?}
                    id="invitations-load-more"
                    type="button"
                    phx-click="load_more_invitations"
                    class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
                  >
                    {gettext("Load more invitations")}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <div class="card rounded-3xl border border-base-300/70 bg-base-100/70 shadow-sm">
            <div class="card-body gap-4">
              <button
                id="sent-invitations-toggle"
                type="button"
                phx-click="toggle_sent_invitations"
                class="flex w-full items-center justify-between gap-3 text-left"
                aria-expanded={to_string(@sent_invitations_expanded?)}
              >
                <div>
                  <h3 class="text-base font-semibold text-base-content">
                    {gettext("Invitations sent by me")}
                  </h3>
                  <p class="text-sm text-base-content/70">
                    {gettext("Invitations your current profile has sent to other profiles.")}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <span class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-emerald-700">
                    {@sent_invitations_pagination.total_count}
                  </span>
                  <.icon
                    name="hero-chevron-down"
                    class={[
                      "size-5 transition-transform",
                      @sent_invitations_expanded? && "rotate-180"
                    ]}
                  />
                </div>
              </button>

              <div :if={@sent_invitations_expanded?} class="space-y-4">
                <div
                  :if={@sent_invitations_pagination.total_count == 0}
                  class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
                >
                  {if String.trim(@invitations_search_query) == "",
                    do: gettext("No invitations sent by this profile."),
                    else: gettext("No sent invitations match your search.")}
                </div>

                <div :if={@sent_invitations_pagination.total_count > 0} class="space-y-4">
                  <div id="sent-invitations" phx-update="stream" class="space-y-4">
                    <div
                      :for={{dom_id, inv} <- @streams.sent_invitations}
                      id={dom_id}
                      class="card rounded-2xl border border-base-300/70 bg-base-100/80"
                    >
                      <div class="card-body p-3">
                        <Components.group_identity
                          group={inv.group}
                          current_profile={@current_profile}
                          avatar_size="size-12"
                          text_class="text-sm"
                          unread_count={Map.get(@group_unread_counts, inv.group.id, 0)}
                          highlight_query={@invitations_search_query}
                        />

                        <div class="text-sm text-base-content/70">
                          {gettext("Invited:")}
                          <Components.highlighted_text
                            text={inv.invitee.username}
                            query={@invitations_search_query}
                            class="font-semibold"
                          />
                        </div>

                        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
                          <span class={[
                            "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em]",
                            if(is_nil(inv.accepted_at),
                              do: "bg-amber-500/10 text-amber-700",
                              else: "bg-emerald-500/10 text-emerald-700"
                            )
                          ]}>
                            {if is_nil(inv.accepted_at),
                              do: gettext("Pending"),
                              else: gettext("Accepted")}
                          </span>
                          <span>
                            {if is_nil(inv.accepted_at),
                              do: gettext("Sent on"),
                              else: gettext("Accepted on")}
                          </span>
                          <Components.local_time
                            id={"sent-invitation-timestamp-#{inv.id}"}
                            datetime={
                              if(is_nil(inv.accepted_at),
                                do: inv.inserted_at,
                                else: inv.accepted_at
                              )
                            }
                            class="text-xs font-thin italic"
                          />
                        </div>
                      </div>
                    </div>
                  </div>

                  <button
                    :if={@sent_invitations_pagination.has_more?}
                    id="sent-invitations-load-more"
                    type="button"
                    phx-click="load_more_sent_invitations"
                    class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
                  >
                    {gettext("Load more sent invitations")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- <div><.link navigate={~p"/groups"} class="link">{gettext("Back to /")}</.link></div> --%>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> assign(:invitations_expanded?, true)
      |> assign(:invitations_pagination, default_invitations_pagination())
      |> assign(:sent_invitations_expanded?, true)
      |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
      |> assign(:invitations_search_query, "")
      |> assign(:visible_invitations, [])
      |> assign(:visible_sent_invitations, [])
      |> stream(:invitations, [], reset: true)
      |> stream(:sent_invitations, [], reset: true)
      |> ProfileAuth.sync_profile_subscription()

    {:ok,
     socket
     |> assign_invitations(socket.assigns.current_profile)}
  end

  @impl true
  def handle_event(
        "load_more_invitations",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_invitations", _params, socket) do
    if socket.assigns.invitations_pagination.has_more? do
      pagination =
        socket.assigns.invitations_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      invitations_page =
        invitations_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.invitations_search_query
        )

      {:noreply,
       socket
       |> assign(:invitations_pagination, pagination_metadata(invitations_page))
       |> assign_visible_invitations(invitations_page.entries)
       |> stream(:invitations, invitations_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_invitations", _params, socket) do
    expanded? = not socket.assigns.invitations_expanded?

    socket = assign(socket, :invitations_expanded?, expanded?)

    {:noreply,
     if(expanded?,
       do: refresh_invitations(socket, socket.assigns.current_profile),
       else: socket
     )}
  end

  def handle_event(
        "load_more_sent_invitations",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_sent_invitations", _params, socket) do
    if socket.assigns.sent_invitations_pagination.has_more? do
      pagination =
        socket.assigns.sent_invitations_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      invitations_page =
        sent_invitations_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.invitations_search_query
        )

      {:noreply,
       socket
       |> assign(:sent_invitations_pagination, pagination_metadata(invitations_page))
       |> assign_visible_sent_invitations(invitations_page.entries)
       |> stream(:sent_invitations, invitations_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_sent_invitations", _params, socket) do
    expanded? = not socket.assigns.sent_invitations_expanded?

    socket = assign(socket, :sent_invitations_expanded?, expanded?)

    {:noreply,
     if(expanded?,
       do: refresh_sent_invitations(socket, socket.assigns.current_profile),
       else: socket
     )}
  end

  @impl true
  def handle_event("search_invitations", %{"invitation_search" => %{"q" => query}}, socket) do
    next_query = normalize_invitations_search_query(query)

    if next_query == socket.assigns.invitations_search_query do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:invitations_search_query, next_query)
       |> assign(:invitations_pagination, default_invitations_pagination())
       |> assign_invitations(socket.assigns.current_profile)}
    end
  end

  def handle_event("search_invitations", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_invitations_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:invitations_search_query, "")
     |> assign(:invitations_pagination, default_invitations_pagination())
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
  def handle_event("delete_invitation", %{"id" => id}, socket) do
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} = invitation <- Social.get_group_invitation_for_invitee(invitee, invitation_id),
         {:ok, _invitation} <- Social.delete_group_invitation(invitation, invitee) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Invitation deleted."))
       |> assign_invitations(invitee)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Invitation not found."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete invitation."))}
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
    |> assign(:invitations_pagination, default_invitations_pagination())
    |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
    |> assign_visible_invitations([])
    |> assign_visible_sent_invitations([])
    |> stream(:invitations, [], reset: true)
    |> stream(:sent_invitations, [], reset: true)
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
  end

  defp assign_invitations(socket, profile) do
    socket
    |> assign(:invitations_pagination, default_invitations_pagination())
    |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
    |> refresh_invitations(profile)
    |> refresh_sent_invitations(profile)
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
  end

  defp refresh_invitations(socket, profile) do
    pagination = socket.assigns.invitations_pagination
    search = socket.assigns.invitations_search_query
    total_count = Social.count_group_invitations_for_invitee(profile, search: search)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    invitations_page = invitations_page(profile, pagination, search, total_count)

    socket
    |> assign(:invitations_pagination, pagination_metadata(invitations_page))
    |> assign_visible_invitations(invitations_page.entries)
    |> stream(:invitations, invitations_page.entries, reset: true)
  end

  defp refresh_sent_invitations(socket, profile) do
    pagination = socket.assigns.sent_invitations_pagination
    search = socket.assigns.invitations_search_query
    total_count = Social.count_group_invitations_for_inviter(profile, search: search)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    invitations_page = sent_invitations_page(profile, pagination, search, total_count)

    socket
    |> assign(:sent_invitations_pagination, pagination_metadata(invitations_page))
    |> assign_visible_sent_invitations(invitations_page.entries)
    |> stream(:sent_invitations, invitations_page.entries, reset: true)
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
    groups =
      socket.assigns.visible_invitations
      |> Kernel.++(socket.assigns.visible_sent_invitations)
      |> Enum.map(& &1.group)
      |> Enum.uniq_by(& &1.id)

    assign(
      socket,
      :group_unread_counts,
      Social.list_group_unread_counts(
        socket.assigns.current_profile,
        groups
      )
    )
  end

  defp assign_visible_invitations(socket, invitations) do
    socket
    |> assign(:visible_invitations, invitations)
    |> assign_group_unread_counts()
  end

  defp assign_visible_sent_invitations(socket, invitations) do
    socket
    |> assign(:visible_sent_invitations, invitations)
    |> assign_group_unread_counts()
  end

  defp invitations_page(%{} = profile, pagination, search_query, total_count \\ nil) do
    search = normalize_invitations_search_query(search_query)

    total_count =
      total_count || Social.count_group_invitations_for_invitee(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_pending_invitations(profile,
        search: search,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  defp sent_invitations_page(%{} = profile, pagination, search_query, total_count \\ nil) do
    search = normalize_invitations_search_query(search_query)

    total_count =
      total_count || Social.count_group_invitations_for_inviter(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_group_invitations_for_inviter(profile,
        search: search,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  defp default_invitations_pagination do
    %{
      page: 1,
      per_page: @invitations_per_page,
      loaded_count: 0,
      total_count: 0,
      has_more?: false
    }
  end

  defp default_sent_invitations_pagination do
    %{
      page: 1,
      per_page: @sent_invitations_per_page,
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

  defp normalize_invitations_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_invitations_search_query(_), do: ""
end
