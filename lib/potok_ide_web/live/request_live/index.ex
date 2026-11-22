defmodule PotokIdeWeb.RequestLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Processes
  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupRequests}
  alias PotokIdeWeb.GroupLive.Show.{Components, RequestDialogs}
  alias PotokIdeWeb.ProfileAuth
  @approved_requests_per_page 10
  @created_requests_per_page 10
  @sections ~w(pending processes approved created)

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
            {gettext(
              "Group access requests you can approve, the ones you made, and the forms and decisions of processes that wait for you."
            )}
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
              "pending" => length(@requests) + length(@role_requests),
              "processes" => @waiting_count,
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
          subtitle={
            gettext(
              "Requests to join and for roles in the groups where your current profile decides them."
            )
          }
        >
          <div
            :if={@requests == [] and @role_requests == []}
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
                  {if(request.poll_id, do: gettext("In a vote"), else: gettext("Pending"))}
                </span>
                <span>{gettext("Review this access request for the selected group.")}</span>
              </div>
              <.request_details
                id={"approval-request-#{request.id}"}
                note={request.note}
                keys={request.role_keys}
                roles={manifest_roles(request.group)}
              />

              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="text-sm text-base-content/70">
                  {gettext("Requested on")}
                  <Components.local_time
                    id={"request-inserted-at-#{request.id}"}
                    datetime={request.inserted_at}
                    class="ml-1 text-xs font-thin italic"
                  />
                </div>

                <div :if={is_nil(request.poll_id)} class="flex items-center gap-2">
                  <.button
                    id={"request-decide-#{request.id}"}
                    type="button"
                    phx-click="request_decision_open"
                    phx-value-kind="join"
                    phx-value-id={request.id}
                    variant="primary"
                    size="sm"
                  >
                    {gettext("Decide")}
                  </.button>
                  <.button
                    :if={request.role_keys == []}
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
                    :if={request.role_keys == []}
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

          <div :if={@role_requests != []} id="role-requests-to-decide" class="mt-3 space-y-3">
            <div
              :for={request <- @role_requests}
              id={"approval-role-request-#{request.id}"}
              class="space-y-3 rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
            >
              <Components.group_identity
                group={request.group}
                current_profile={@current_profile}
                avatar_size="size-12"
                text_class="text-sm"
              />
              <Components.profile_identity
                profile={request.profile}
                avatar_size="size-10"
                text_class="text-sm"
                title={gettext("Asks for roles")}
                current_profile={@current_profile}
                direct_group_link={true}
              />
              <.request_details
                id={"approval-role-request-#{request.id}"}
                note={request.note}
                keys={request.role_keys}
                roles={manifest_roles(request.group)}
              />
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="text-sm text-base-content/70">
                  {gettext("Requested on")}
                  <Components.local_time
                    id={"role-request-updated-at-#{request.id}"}
                    datetime={request.updated_at}
                    class="ml-1 text-xs font-thin italic"
                  />
                </div>
                <.button
                  id={"role-request-decide-#{request.id}"}
                  type="button"
                  phx-click="request_decision_open"
                  phx-value-kind="roles"
                  phx-value-id={request.id}
                  variant="primary"
                  size="sm"
                >
                  {gettext("Decide")}
                </.button>
              </div>
            </div>
          </div>
        </Components.settings_card>

        <%!-- What the processes of the profile's groups wait for it to do, by group. --%>
        <Components.settings_card
          id="requests-processes"
          tab_id="requests-tab-processes"
          active={@section == "processes"}
          icon="hero-arrow-path-rounded-square"
          title={gettext("Waiting for you")}
          subtitle={
            gettext(
              "Forms and decisions of the processes in your groups that wait for you, the nearest deadline first."
            )
          }
        >
          <div
            :if={@waiting_groups == []}
            id="requests-processes-empty"
            class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
          >
            {gettext("Nothing waits for you.")}
          </div>

          <div :if={@waiting_groups != []} class="space-y-3">
            <div
              :for={%{group: group, tasks: tasks} <- @waiting_groups}
              id={"waiting-group-#{group.id}"}
              class="space-y-3 rounded-2xl border border-amber-500/30 bg-gradient-to-br from-amber-500/10 to-base-100 p-4"
            >
              <Components.group_identity
                group={group}
                current_profile={@current_profile}
                avatar_size="size-10"
                text_class="text-sm"
              />
              <ul class="space-y-1.5">
                <li :for={task <- tasks} id={"waiting-task-#{task.id}"}>
                  <.link
                    navigate={waiting_path(group, task)}
                    class="group/task flex items-center gap-3 rounded-2xl bg-base-100/85 px-3 py-2.5 shadow-xs transition hover:bg-base-100 hover:shadow-sm active:scale-[0.99]"
                  >
                    <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-xl bg-amber-500/15 text-amber-800 dark:text-amber-200">
                      <.icon
                        name={
                          if(task.form?,
                            do: "hero-clipboard-document-list",
                            else: "hero-hand-raised"
                          )
                        }
                        class="size-5"
                      />
                    </span>
                    <span class="min-w-0 flex-1">
                      <span class="block truncate text-sm font-semibold">{task.label}</span>
                      <span class="block truncate text-xs text-base-content/60">
                        {task.process.name <>
                          " · " <>
                          if(task.form?, do: gettext("form"), else: gettext("decision"))}
                      </span>
                    </span>
                    <span
                      :if={task.deadline_at}
                      class="hidden shrink-0 items-center gap-1 text-xs text-base-content/60 sm:inline-flex"
                    >
                      <.icon name="hero-clock" class="size-3.5" />
                      <Components.local_time
                        id={"waiting-task-#{task.id}-deadline"}
                        datetime={task.deadline_at}
                      />
                    </span>
                    <.icon
                      name="hero-chevron-right"
                      class="size-4 shrink-0 text-base-content/40 transition-transform group-hover/task:translate-x-0.5"
                    />
                  </.link>
                </li>
              </ul>
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
            <.my_waiting
              join={@my_join_requests}
              roles={@my_role_requests}
              current_profile={@current_profile}
            />
            <.my_decisions decisions={@my_decisions} current_profile={@current_profile} />

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
      <RequestDialogs.decide_dialog state={@decision_dialog} current_profile={@current_profile} />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :note, :string, default: nil
  attr :keys, :list, required: true
  attr :roles, :list, required: true

  # What a request asks for and why.
  defp request_details(assigns) do
    ~H"""
    <div :if={@note || @keys != []} class="space-y-1.5">
      <RequestDialogs.role_chips id={"#{@id}-roles"} keys={@keys} roles={@roles} />
      <p
        :if={@note}
        id={"#{@id}-note"}
        class="line-clamp-4 rounded-xl bg-base-200/50 px-3 py-2 text-sm whitespace-pre-line"
        phx-no-format
      >{@note}</p>
    </div>
    """
  end

  attr :join, :list, required: true
  attr :roles, :list, required: true
  attr :current_profile, :map, required: true

  # What the profile asked for and still waits for, with a way to take it back
  # while nobody votes on it.
  defp my_waiting(assigns) do
    ~H"""
    <div :if={@join != [] or @roles != []} id="my-waiting-requests" class="space-y-3">
      <h3 class="text-sm font-semibold">{gettext("Still waiting")}</h3>
      <div
        :for={request <- @join}
        id={"my-join-request-#{request.id}"}
        class="space-y-2 rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
      >
        <Components.group_identity
          group={request.group}
          current_profile={@current_profile}
          avatar_size="size-10"
          text_class="text-sm"
        />
        <p class="text-sm text-base-content/70">
          {if(request.poll_id,
            do: gettext("The group votes on admitting you."),
            else: gettext("You asked to join.")
          )}
        </p>
        <.request_details
          id={"my-join-request-#{request.id}"}
          note={request.note}
          keys={request.role_keys}
          roles={manifest_roles(request.group)}
        />
        <.button
          :if={is_nil(request.poll_id)}
          id={"my-join-request-#{request.id}-withdraw"}
          type="button"
          phx-click="request_withdraw"
          phx-value-kind="join"
          phx-value-group={request.group_id}
          data-confirm={gettext("Take back your request to join?")}
          size="sm"
        >
          {gettext("Take it back")}
        </.button>
      </div>
      <div
        :for={request <- @roles}
        id={"my-role-request-#{request.id}"}
        class="space-y-2 rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
      >
        <Components.group_identity
          group={request.group}
          current_profile={@current_profile}
          avatar_size="size-10"
          text_class="text-sm"
        />
        <p class="text-sm text-base-content/70">{gettext("You asked for roles.")}</p>
        <.request_details
          id={"my-role-request-#{request.id}"}
          note={request.note}
          keys={request.role_keys}
          roles={manifest_roles(request.group)}
        />
        <.button
          id={"my-role-request-#{request.id}-withdraw"}
          type="button"
          phx-click="request_withdraw"
          phx-value-kind="roles"
          phx-value-group={request.group_id}
          data-confirm={gettext("Take back your request for roles?")}
          size="sm"
        >
          {gettext("Take it back")}
        </.button>
      </div>
    </div>
    """
  end

  attr :decisions, :list, required: true
  attr :current_profile, :map, required: true

  # What became of the profile's requests, with who decided and why.
  defp my_decisions(assigns) do
    ~H"""
    <div :if={@decisions != []} id="my-request-decisions" class="space-y-3">
      <h3 class="text-sm font-semibold">{gettext("Decisions on your requests")}</h3>
      <div
        :for={decision <- @decisions}
        id={"my-request-decision-#{decision.id}"}
        class="space-y-2 rounded-2xl border border-base-300/70 bg-base-100/80 p-4"
      >
        <Components.group_identity
          group={decision.group}
          current_profile={@current_profile}
          avatar_size="size-10"
          text_class="text-sm"
        />
        <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
          <span class="font-semibold">{subject_label(decision)}</span>
          <span class={[
            "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold",
            decision_class(decision)
          ]}>
            {decision_label(decision)}
          </span>
          <Components.local_time
            id={"my-request-decision-at-#{decision.id}"}
            datetime={decision.inserted_at}
            class="text-xs font-thin italic text-base-content/65"
          />
        </p>
        <Components.profile_identity
          :if={decision.decider}
          profile={decision.decider}
          avatar_size="size-8"
          text_class="text-sm"
          title={gettext("Decided by")}
          current_profile={@current_profile}
          direct_group_link={true}
        />
        <p
          :if={decision.reason}
          id={"my-request-decision-#{decision.id}-reason"}
          class="rounded-xl bg-base-200/50 px-3 py-2 text-sm"
        >
          „{decision.reason}“
        </p>
      </div>
    </div>
    """
  end

  defp subject_label(%{role_key: nil}), do: gettext("Admission")

  defp subject_label(%{role_key: key, group: group}) do
    case Enum.find(manifest_roles(group), &(&1.key == key)) do
      nil -> gettext("A role since deleted")
      role -> PotokIdeWeb.GroupLive.Show.RolesTab.role_label(role)
    end
  end

  defp decision_label(%{decision: :granted, role_key: nil}), do: gettext("Admitted")
  defp decision_label(%{decision: :granted}), do: gettext("Given")
  defp decision_label(%{decision: :declined}), do: gettext("Refused")
  defp decision_label(%{decision: :voted, poll: %{closed_at: nil}}), do: gettext("In a vote")

  defp decision_label(%{decision: :voted, poll: %{effect_status: :applied}}),
    do: gettext("Carried by the vote")

  defp decision_label(%{decision: :voted, poll: %{}}), do: gettext("Not carried by the vote")
  defp decision_label(%{decision: :voted}), do: gettext("Put to a vote")

  defp decision_class(%{decision: :declined}), do: "bg-error/10 text-error"

  defp decision_class(%{decision: :voted, poll: %{closed_at: closed_at, effect_status: status}})
       when not is_nil(closed_at) and status != :applied,
       do: "bg-error/10 text-error"

  defp decision_class(%{decision: :voted, poll: %{closed_at: nil}}),
    do: "bg-primary/10 text-primary"

  defp decision_class(_decision),
    do: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"

  # The roles a request names, as the group's statute has them now.
  defp manifest_roles(group) do
    case Access.effective_manifest(group) do
      nil -> []
      manifest -> Enum.reject(manifest.roles, &(&1.key == "everyone"))
    end
  end

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> assign(:requests_search_query, "")
      |> assign(:section, if(params["section"] in @sections, do: params["section"], else: nil))
      |> assign(:waiting_groups, [])
      |> assign(:waiting_count, 0)
      |> assign(:approved_requests_pagination, default_approved_requests_pagination())
      |> stream(:approved_requests, [], reset: true)
      |> assign(:created_requests_pagination, default_created_requests_pagination())
      |> stream(:created_requests, [], reset: true)
      |> assign(:decision_dialog, nil)
      |> ProfileAuth.sync_profile_subscription()

    socket = assign_requests(socket, socket.assigns.current_profile)

    # The hand counts what waits in processes too: with nothing to approve,
    # the page opens on that.
    section =
      socket.assigns.section ||
        if(
          socket.assigns.requests == [] and socket.assigns.role_requests == [] and
            socket.assigns.waiting_count > 0,
          do: "processes",
          else: "pending"
        )

    {:ok, socket |> assign(:section, section) |> refresh_waiting(socket.assigns.current_profile)}
  end

  @impl true
  def handle_event("set_section", %{"section" => section}, socket)
      when section in @sections do
    socket = assign(socket, :section, section)
    profile = socket.assigns.current_profile

    {:noreply,
     case section do
       "pending" -> socket
       "processes" -> refresh_waiting(socket, profile)
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

  def handle_event("request_decision_open", %{"kind" => kind, "id" => id}, socket) do
    profile = socket.assigns.current_profile

    found =
      with {id, ""} <- Integer.parse(id) do
        case kind do
          "roles" -> Enum.find(socket.assigns.role_requests, &(&1.id == id))
          _join -> Enum.find(socket.assigns.requests, &(&1.id == id))
        end
      end

    with %{group: group} = request <- found,
         state when not is_nil(state) <-
           RequestDialogs.decide_state(group, Access.for_profile(profile, group), request) do
      {:noreply, assign(socket, :decision_dialog, state)}
    else
      _none -> {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
  end

  def handle_event("request_decision_close", _params, socket),
    do: {:noreply, assign(socket, :decision_dialog, nil)}

  def handle_event("request_decide", %{"decision" => params}, socket) do
    %{current_profile: profile, decision_dialog: state} = socket.assigns

    case state && RequestDialogs.decide(profile, Social.get_group!(state.group_id), state, params) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:decision_dialog, nil)
         |> put_flash(:info, message)
         |> assign_requests(profile)}

      {:error, message} ->
        {:noreply, assign(socket, :decision_dialog, %{state | error: message})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("request_withdraw", %{"kind" => kind, "group" => group_id}, socket) do
    profile = socket.assigns.current_profile

    with {group_id, ""} <- Integer.parse(group_id),
         group when not is_nil(group) <- PotokIde.Repo.get(Social.Group, group_id),
         :ok <-
           GroupRequests.withdraw(profile, group, if(kind == "roles", do: :roles, else: :join)) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Your request is taken back."))
       |> assign_requests(profile)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, RequestDialogs.error_message(reason))}

      _none ->
        {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
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

  # What waits for the profile in some group's processes changed.
  def handle_info({:profile_waiting_updated, _profile_id}, socket),
    do: {:noreply, refresh_waiting(socket, socket.assigns.current_profile)}

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

  # A message no clause above knows (one that ProfileAuth passes on, or one a
  # newer server sends during a deploy) is left alone, not a crash.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_requests(socket, nil) do
    socket
    |> assign(:requests, [])
    |> assign(:role_requests, [])
    |> assign(:my_join_requests, [])
    |> assign(:my_role_requests, [])
    |> assign(:my_decisions, [])
    |> assign(waiting_groups: [], waiting_count: 0)
    |> assign(:approved_requests_pagination, default_approved_requests_pagination())
    |> stream(:approved_requests, [], reset: true)
    |> assign(:created_requests_pagination, default_created_requests_pagination())
    |> stream(:created_requests, [], reset: true)
  end

  defp assign_requests(socket, profile) do
    socket
    |> assign(:requests, Social.list_pending_group_join_requests_for_approver(profile))
    |> assign(:role_requests, GroupRequests.roles_requests_for_decider(profile))
    |> assign(:my_join_requests, GroupRequests.join_requests_of(profile))
    |> assign(:my_role_requests, GroupRequests.roles_requests_of(profile))
    |> assign(:my_decisions, GroupRequests.decisions_of(profile, 20))
    |> refresh_waiting(profile)
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

  # What waits for the profile in its groups' processes: the count always,
  # for the tab, and the list while the tab is on screen.
  defp refresh_waiting(socket, nil), do: assign(socket, waiting_groups: [], waiting_count: 0)

  defp refresh_waiting(socket, profile) do
    if socket.assigns.section == "processes" do
      groups = Processes.waiting_across(profile)
      count = groups |> Enum.map(&length(&1.tasks)) |> Enum.sum()
      assign(socket, waiting_groups: groups, waiting_count: count)
    else
      assign(socket, waiting_groups: [], waiting_count: Processes.waiting_total(profile))
    end
  end

  # A form opens in its group's page at once; a decision waits on its tab.
  defp waiting_path(group, %{form?: true, id: id}),
    do: ~p"/groups/#{group.id}/processes?#{[form: id]}"

  defp waiting_path(group, _decision), do: ~p"/groups/#{group.id}/processes"

  # The tabs, in order: `{key, panel id, label, danger?}`.
  defp sections do
    [
      {"pending", "requests-pending", pgettext("requests tab", "To approve"), false},
      {"processes", "requests-processes", pgettext("requests tab", "Processes"), false},
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
