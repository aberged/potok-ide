defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.{Components, RolesTab}
  alias PotokIdeWeb.TagComponents

  attr :members, :any, required: true, doc: "stream of `%{id, profile, role_keys}`"

  attr :processes, :list,
    default: [],
    doc:
      "the processes of the group's apps: `%{id, process, profile, role_keys, warning, counts, failed}`"

  attr :pagination, :map, required: true
  attr :current_profile, :map, required: true
  attr :group, :map, required: true
  attr :access, Access, required: true
  attr :join_requests, :list, default: []
  attr :pending_join_requests_count, :integer, default: 0
  attr :blocks, :list, default: [], doc: "the group's blocks, for those who may lift them"

  def panel(assigns) do
    roles = if assigns.access.manifest, do: assigns.access.manifest.roles, else: []

    assigns =
      assigns
      |> assign(:roles, roles)
      # "everyone" is implicit, so it is neither shown on members nor assignable.
      |> assign(:assignable_roles, Enum.reject(roles, &(&1.key == GroupRole.everyone_key())))
      |> assign(:manage_roles?, assigns.access.admin? and not assigns.group.is_direct)
      |> assign(:can_remove?, Access.can?(assigns.access, :remove_members))

    ~H"""
    <div id="group-panel-members" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.tab_body>
        <.page_header
          :if={!@group.is_direct}
          id="group-members-header"
          icon="hero-user-group"
          compact
        >
          {gettext("Members")}
          <:subtitle>{gettext("Who is in the group, with their roles.")}</:subtitle>
          <:actions :if={Access.can?(@access, :invite_members)}>
            <.button
              id="group-members-invite"
              type="button"
              phx-click="switch_tab"
              phx-value-tab="invite_profile"
              variant="soft"
              size="sm"
            >
              <.icon name="hero-user-plus" class="size-4" />
              {gettext("Invite")}
            </.button>
          </:actions>
        </.page_header>

        <div
          :if={Access.can?(@access, :manage_join_requests) && !@group.is_direct}
          id="group-join-requests-panel"
          class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
        >
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h4 class="text-sm font-semibold text-base-content">{gettext("Access requests")}</h4>

              <p class="text-xs text-base-content/70">
                {gettext("Profiles waiting for approval to join this public group.")}
              </p>
            </div>

            <.count_badge
              id="group-join-requests-count"
              count={@pending_join_requests_count}
              tone={:attention}
            />
          </div>

          <div
            :if={@join_requests == []}
            id="group-join-requests-empty"
            class="rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3 text-sm text-base-content/70"
          >
            {gettext("No pending access requests.")}
          </div>

          <ul :if={@join_requests != []} id="group-join-requests-list" class="space-y-3">
            <li :for={request <- @join_requests} id={"group-join-request-#{request.id}"}>
              <div class="flex items-start justify-between gap-3 rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3">
                <div class="min-w-0 flex-1">
                  <Components.profile_identity
                    profile={request.requester}
                    current_profile={@current_profile}
                    direct_group_link={true}
                  />
                  <div class="mt-2 text-xs text-base-content/65">
                    <Components.local_time
                      id={"group-join-request-inserted-at-#{request.id}"}
                      datetime={request.inserted_at}
                    />
                  </div>
                </div>

                <div class="flex shrink-0 items-center gap-2">
                  <.button
                    id={"group-accept-join-request-#{request.id}"}
                    type="button"
                    phx-click="accept_join_request"
                    phx-value-id={request.id}
                    variant="success"
                    size="sm"
                  >
                    {gettext("Accept")}
                  </.button>
                  <.button
                    id={"group-reject-join-request-#{request.id}"}
                    type="button"
                    phx-click="reject_join_request"
                    phx-value-id={request.id}
                    size="sm"
                  >
                    {gettext("Reject")}
                  </.button>
                </div>
              </div>
            </li>
          </ul>
        </div>

        <div
          :if={@blocks != []}
          id="group-blocks-panel"
          class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
        >
          <div class="mb-3">
            <h4 class="text-sm font-semibold text-base-content">{gettext("Blocked")}</h4>

            <p class="text-xs text-base-content/70">
              {gettext("They cannot write or react here, ask to join or be invited.")}
            </p>
          </div>

          <ul id="group-blocks-list" class="space-y-3">
            <li
              :for={block <- @blocks}
              id={"group-block-#{block.profile_id}"}
              class="flex items-center justify-between gap-3 rounded-2xl border border-base-300/70 bg-base-100/50 px-4 py-3"
            >
              <div class="min-w-0 flex-1">
                <Components.profile_identity
                  profile={block.profile}
                  current_profile={@current_profile}
                  direct_group_link={true}
                />
              </div>

              <.button
                :if={@can_remove?}
                id={"group-unblock-#{block.profile_id}"}
                type="button"
                phx-click="unblock_profile"
                phx-value-id={block.profile_id}
                size="sm"
              >
                {gettext("Unblock")}
              </.button>
            </li>
          </ul>
        </div>

        <ul id="group-members-list" class="space-y-2" phx-update="stream">
          <li
            :if={@pagination.loaded_count == 0}
            id="group-members-empty"
            class="text-base-content/70"
          >
            {gettext("No members.")}
          </li>

          <li
            :for={
              {dom_id,
               %{
                 profile: member,
                 role_keys: role_keys,
                 inherited?: inherited?,
                 inherited_role_keys: inherited_role_keys
               }} <- @members
            }
            id={dom_id}
            class="rounded-2xl border border-base-300/60 bg-base-100/70 px-2 py-1 shadow-sm"
          >
            <div class="flex items-center justify-between gap-3">
              <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1">
                <Components.profile_identity
                  profile={member}
                  me={member.id == @current_profile.id}
                  presence_profile_id={member.id}
                  presence_badge_id={"group-member-presence-#{member.id}"}
                  current_profile={@current_profile}
                  direct_group_link={true}
                />
                <span
                  :if={inherited?}
                  id={"member-#{member.id}-inherited"}
                  title={gettext("Member of the parent group")}
                  class="inline-flex h-6 items-center gap-1 rounded-full bg-base-200 px-2 text-[11px] font-semibold text-base-content/65"
                >
                  <.icon name="hero-arrow-turn-down-right" class="size-3" />
                  {gettext("Inherited")}
                </span>
                <.role_badges
                  :if={!@group.is_direct}
                  id={"member-#{member.id}"}
                  roles={member_roles(@assignable_roles, role_keys)}
                />
                <TagComponents.tag_chips id={"member-#{member.id}-tag-list"} tags={member.tags} />
              </div>
              <TagComponents.tag_button
                id={"member-tags-#{member.id}"}
                kind={:profile}
                item_id={member.id}
                class="shrink-0 p-2"
              />
              <.icon_button
                :if={@manage_roles?}
                id={"member-#{member.id}-roles-toggle"}
                type="button"
                phx-click={JS.toggle_class("hidden flex", to: "#member-#{member.id}-role-editor")}
                aria-controls={"member-#{member.id}-role-editor"}
                icon="hero-shield-check"
                label={gettext("Roles of %{username}", username: member.username)}
              />
              <.icon_button
                :if={
                  @can_remove? && member.id != @current_profile.id && !@group.is_direct &&
                    !inherited? && (@access.admin? or GroupRole.admin_key() not in role_keys)
                }
                id={"group-remove-member-#{member.id}"}
                type="button"
                phx-click="remove_member"
                phx-value-id={member.id}
                data-confirm={
                  gettext("Remove %{username} from this group?", username: member.username)
                }
                icon="hero-x-mark"
                label={gettext("Remove %{username}", username: member.username)}
                variant="danger"
              />
            </div>
            <%!-- Toggled on the client; stays open while the member is re-streamed. --%>
            <.role_editor
              :if={@manage_roles?}
              id={"member-#{member.id}"}
              profile_id={member.id}
              roles={@assignable_roles}
              role_keys={role_keys}
              inherited_role_keys={inherited_role_keys}
            />
          </li>
        </ul>

        <div :if={@pagination.has_more?} class="mt-4 flex justify-center">
          <.button
            id="group-members-load-more"
            type="button"
            phx-click="load_more_members"
            size="sm"
          >
            {gettext("Load more members")}
          </.button>
        </div>

        <section :if={@processes != []} id="group-processes" class="mt-8">
          <div class="mb-3 px-1">
            <h4 class="flex items-center gap-1.5 text-sm font-semibold text-base-content">
              <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/60" />
              {gettext("Processes")}
            </h4>
            <p class="text-xs text-base-content/70">
              {gettext(
                "They act for the group's apps and are not counted among the members. An app's rules start and stop them."
              )}
            </p>
          </div>

          <ul id="group-processes-list" class="space-y-2">
            <li
              :for={entry <- @processes}
              id={"group-process-#{entry.id}"}
              class="rounded-2xl border border-dashed border-base-300 bg-base-100/50 px-2 py-1"
            >
              <div class="flex items-center justify-between gap-3">
                <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1">
                  <Components.profile_identity
                    profile={entry.profile}
                    subtitle={process_subtitle(entry.process)}
                    current_profile={@current_profile}
                  />
                  <.role_badges
                    id={"process-#{entry.id}"}
                    roles={member_roles(@assignable_roles, entry.role_keys)}
                  />
                </div>
                <.icon_button
                  :if={@manage_roles?}
                  id={"process-#{entry.id}-roles-toggle"}
                  type="button"
                  phx-click={JS.toggle_class("hidden flex", to: "#process-#{entry.id}-role-editor")}
                  aria-controls={"process-#{entry.id}-role-editor"}
                  icon="hero-shield-check"
                  label={gettext("Roles of %{username}", username: entry.process.name)}
                />
              </div>

              <div
                :if={entry.warning}
                id={"process-#{entry.id}-warning"}
                class="mx-1 mt-1 mb-1.5 space-y-0.5 rounded-xl bg-amber-500/10 px-3 py-2 text-xs text-amber-900 dark:text-amber-100"
              >
                <p :if={entry.warning["missing"] != []} id={"process-#{entry.id}-missing"}>
                  <.icon name="hero-exclamation-triangle" class="mr-1 size-3.5 align-[-2px]" />
                  {gettext("It may not: %{permissions}.",
                    permissions: missing_permissions(entry.warning["missing"])
                  )}
                </p>
                <p :if={entry.warning["owner_left"]} id={"process-#{entry.id}-owner-left"}>
                  <.icon name="hero-user-minus" class="mr-1 size-3.5 align-[-2px]" />
                  {gettext(
                    "Its owner no longer edits the app. Whoever saves its rules next takes it over."
                  )}
                </p>
              </div>

              <div
                :if={entry.counts != %{}}
                id={"process-#{entry.id}-counts"}
                class="mx-1 mb-1.5 flex flex-wrap gap-1.5"
              >
                <span
                  :for={{status, label} <- count_labels(entry.counts)}
                  id={"process-#{entry.id}-count-#{status}"}
                  class={[
                    "inline-flex h-6 items-center rounded-full px-2 text-[11px] font-semibold",
                    count_class(status)
                  ]}
                >
                  {label}
                </span>
              </div>

              <ul
                :if={entry.failed != []}
                id={"process-#{entry.id}-failed"}
                class="mx-1 mb-1.5 space-y-1"
              >
                <li
                  :for={instance <- entry.failed}
                  id={"process-instance-#{instance.id}"}
                  class="flex items-center justify-between gap-2 rounded-xl bg-error/10 px-3 py-1.5 text-xs text-base-content"
                >
                  <span class="min-w-0">
                    <span class="font-semibold">
                      {gettext("Stopped at %{element}",
                        element: instance.error["element"] || instance.element
                      )}
                    </span>
                    <span class="text-base-content/70">
                      · {failure_reason(instance.error["reason"])}
                    </span>
                  </span>
                  <.button
                    id={"process-instance-#{instance.id}-retry"}
                    type="button"
                    phx-click="retry_process_instance"
                    phx-value-id={instance.id}
                    size="sm"
                  >
                    {gettext("Take up again")}
                  </.button>
                </li>
              </ul>

              <.role_editor
                :if={@manage_roles?}
                id={"process-#{entry.id}"}
                profile_id={entry.id}
                roles={@assignable_roles}
                role_keys={entry.role_keys}
              />
            </li>
          </ul>
        </section>
      </Components.tab_body>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the prefix of the ids, such as `member-12`"
  attr :roles, :list, required: true, doc: "the assigned roles to show"

  defp role_badges(assigns) do
    ~H"""
    <div :if={@roles != []} id={"#{@id}-roles"} class="flex flex-wrap items-center gap-1">
      <span
        :for={role <- @roles}
        id={"#{@id}-role-badge-#{role.key}"}
        class={[
          "inline-flex h-6 items-center gap-1 rounded-full px-2 text-[11px] font-semibold",
          if(role.key == GroupRole.admin_key(),
            do: "bg-amber-500/15 text-amber-800 dark:text-amber-200",
            else: "bg-primary/10 text-primary"
          )
        ]}
      >
        <.icon name={RolesTab.role_icon(role)} class="size-3" />
        {RolesTab.role_label(role)}
      </span>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the prefix of the ids, such as `member-12`"
  attr :profile_id, :integer, required: true
  attr :roles, :list, required: true, doc: "the roles that may be assigned"
  attr :role_keys, :list, required: true
  attr :inherited_role_keys, :list, default: []

  defp role_editor(assigns) do
    ~H"""
    <div
      id={"#{@id}-role-editor"}
      class="hidden flex-wrap items-center gap-1.5 border-t border-base-300/60 px-1 pt-2 pb-1 mt-1"
    >
      <button
        :for={role <- @roles}
        id={"#{@id}-role-#{role.key}"}
        type="button"
        phx-click="toggle_member_role"
        phx-value-profile-id={@profile_id}
        phx-value-key={role.key}
        aria-pressed={to_string(role.key in @role_keys)}
        disabled={role.key in @inherited_role_keys}
        title={if(role.key in @inherited_role_keys, do: gettext("Inherited from the parent group"))}
        class={[
          "inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs font-semibold shadow-xs transition duration-150 ease-out",
          role_toggle_class(role.key, @role_keys, @inherited_role_keys)
        ]}
      >
        <.icon
          name={role_toggle_icon(role.key, @role_keys, @inherited_role_keys)}
          class="size-3.5"
        />
        {RolesTab.role_label(role)}
      </button>
    </div>
    """
  end

  # Which collection of which app, and who owns the process.
  defp process_subtitle(process) do
    owner =
      case process.owner_profile do
        %{username: username} -> gettext("owner %{username}", username: username)
        nil -> gettext("no owner")
      end

    app =
      case process.alt_description do
        %{name: name} -> [name]
        nil -> []
      end

    Enum.join(
      app ++ [gettext("collection %{collection}", collection: process.collection), owner],
      " · "
    )
  end

  # How many instances are in each state, those under way first.
  defp count_labels(counts) do
    for status <- [:running, :waiting, :failed, :done, :cancelled],
        n = Map.get(counts, status, 0),
        n > 0,
        do: {status, count_label(status, n)}
  end

  defp count_label(:running, n), do: gettext("Running: %{count}", count: n)
  defp count_label(:waiting, n), do: gettext("Waiting: %{count}", count: n)
  defp count_label(:failed, n), do: gettext("Failed: %{count}", count: n)
  defp count_label(:done, n), do: gettext("Done: %{count}", count: n)
  defp count_label(:cancelled, n), do: gettext("Cancelled: %{count}", count: n)

  defp count_class(:running), do: "bg-primary/10 text-primary"
  defp count_class(:waiting), do: "bg-amber-500/15 text-amber-800 dark:text-amber-200"
  defp count_class(:failed), do: "bg-error/10 text-error"
  defp count_class(:done), do: "bg-success/10 text-success"
  defp count_class(:cancelled), do: "bg-base-200 text-base-content/65"

  # Why an instance stopped (`Processes.Engine`), in words.
  defp failure_reason("not_permitted"), do: gettext("the process lacks a permission")

  defp failure_reason("not_a_member_of_group"),
    do: gettext("the process is not a member of that group")

  defp failure_reason("not_process_group"),
    do: gettext("the process may not write in that group")

  defp failure_reason("no_admin"), do: gettext("nobody to run the sub-group")
  defp failure_reason("no_subgroup"), do: gettext("its sub-group is gone")
  defp failure_reason("empty_text"), do: gettext("the text came out empty")
  defp failure_reason("invalid_push"), do: gettext("the push text does not fit")
  defp failure_reason("process_inactive"), do: gettext("the process was stopped")
  defp failure_reason("loop"), do: gettext("it went round without waiting")
  defp failure_reason("too_many_steps"), do: gettext("it took too many steps")
  defp failure_reason("crash"), do: gettext("an unexpected error")
  defp failure_reason(_reason), do: gettext("an error")

  defp missing_permissions(missing) do
    Enum.map_join(missing, ", ", &RolesTab.permission_label(String.to_existing_atom(&1)))
  end

  # A role held through the parent is locked: it is changed there.
  defp role_toggle_class(key, role_keys, inherited_role_keys) do
    cond do
      key in inherited_role_keys ->
        "cursor-not-allowed border-primary/25 bg-primary/5 text-primary/70"

      key in role_keys ->
        "border-primary/50 bg-primary/10 text-primary hover:-translate-y-px active:scale-95"

      true ->
        "border-base-300 bg-base-100 text-base-content/65 hover:-translate-y-px hover:border-base-content/25 hover:bg-base-200 active:scale-95"
    end
  end

  defp role_toggle_icon(key, role_keys, inherited_role_keys) do
    cond do
      key in inherited_role_keys -> "hero-lock-closed"
      key in role_keys -> "hero-check"
      true -> "hero-plus"
    end
  end

  # Assigned roles in the manifest's display order; keys of roles missing
  # from the effective manifest are left out.
  defp member_roles(assignable_roles, role_keys) do
    Enum.filter(assignable_roles, &(&1.key in role_keys))
  end
end
