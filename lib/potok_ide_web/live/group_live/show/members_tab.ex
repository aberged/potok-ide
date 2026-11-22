defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIde.Polls.Effects
  alias PotokIde.Social.{Access, GroupRequests, GroupRole}

  alias PotokIdeWeb.GroupLive.Show.{
    ChoiceMenus,
    Components,
    ProcessesTab,
    RequestDialogs,
    RolesTab
  }

  alias PotokIdeWeb.TagComponents

  attr :members, :any, required: true, doc: "stream of `%{id, profile, role_keys}`"

  attr :processes, :list,
    default: [],
    doc: "the processes of the group's apps: `%{id, process, profile, role_keys, warning}`"

  attr :pagination, :map, required: true

  attr :role_filter, :string,
    default: nil,
    doc: "the key of the role the list is narrowed to (`?role=`), nil for every member"

  attr :current_profile, :map, required: true
  attr :group, :map, required: true
  attr :access, Access, required: true
  attr :join_requests, :list, default: []
  attr :role_requests, :list, default: [], doc: "members' requests for roles, with their profiles"
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
      |> assign(:elects?, assigns.group.elects_admins)
      # Admin comes only by a decision where the group elects its admins.
      |> assign(
        :locked_keys,
        if(assigns.group.elects_admins, do: [GroupRole.admin_key()], else: [])
      )
      |> assign(
        :call_election?,
        assigns.group.elects_admins and
          Effects.may_propose?(assigns.access, assigns.group, :elect)
      )
      # A member may ask for a role the statute lets be asked for.
      |> assign(
        :can_ask_roles?,
        assigns.access.member? and GroupRequests.group_allowed?(assigns.group) and
          GroupRequests.requestable_roles(assigns.access, assigns.group) != []
      )
      |> assign(:request_roles, RequestDialogs.manifest_roles(assigns.access))
      |> assign(:role_choices, role_choices(roles))
      |> assign(:filter_role, Enum.find(roles, &(&1.key == assigns.role_filter)))

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
          <:actions :if={Access.can?(@access, :invite_members) or @call_election? or @can_ask_roles?}>
            <.button
              :if={@can_ask_roles?}
              id="group-members-ask-roles"
              type="button"
              phx-click="request_dialog_open"
              phx-value-kind="roles"
              variant="soft"
              size="sm"
            >
              <.icon name="hero-hand-raised" class="size-4" />
              {gettext("Ask for roles")}
            </.button>
            <.button
              :if={@call_election?}
              id="group-members-call-election"
              type="button"
              phx-click="poll_form_open"
              phx-value-preset="election"
              variant="soft"
              size="sm"
            >
              <.icon name="hero-scale" class="size-4" />
              {gettext("Call an election")}
            </.button>
            <.button
              :if={Access.can?(@access, :invite_members)}
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
              <h4 class="text-sm font-semibold text-base-content">{gettext("Requests")}</h4>

              <p class="text-xs text-base-content/70">
                {gettext(
                  "Who asks to join or for roles. The statute says how each role is had, and the group's settings how it admits."
                )}
              </p>
            </div>

            <.count_badge
              id="group-join-requests-count"
              count={@pending_join_requests_count}
              tone={:attention}
            />
          </div>

          <div
            :if={@join_requests == [] and @role_requests == []}
            id="group-join-requests-empty"
            class="rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3 text-sm text-base-content/70"
          >
            {gettext("No pending requests.")}
          </div>

          <ul :if={@join_requests != []} id="group-join-requests-list" class="space-y-3">
            <li :for={request <- @join_requests} id={"group-join-request-#{request.id}"}>
              <div class="rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 flex-1">
                    <Components.profile_identity
                      profile={request.requester}
                      current_profile={@current_profile}
                      direct_group_link={true}
                    />
                    <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/65">
                      <span>{gettext("asks to join")}</span>
                      <Components.local_time
                        id={"group-join-request-inserted-at-#{request.id}"}
                        datetime={request.inserted_at}
                      />
                    </div>
                  </div>
                </div>
                <.request_details
                  id={"group-join-request-#{request.id}"}
                  note={request.note}
                  keys={request.role_keys}
                  roles={@request_roles}
                />
                <div class="mt-3 flex flex-wrap items-center justify-end gap-2">
                  <span
                    :if={request.poll_id}
                    id={"group-join-request-#{request.id}-voting"}
                    class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2.5 py-1 text-xs font-semibold text-primary"
                  >
                    <.icon name="hero-scale" class="size-3.5" />
                    {gettext("In a vote")}
                  </span>
                  <.button
                    :if={is_nil(request.poll_id)}
                    id={"group-decide-join-request-#{request.id}"}
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
                    :if={is_nil(request.poll_id) and request.role_keys == []}
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
                    :if={is_nil(request.poll_id) and request.role_keys == []}
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

          <ul
            :if={@role_requests != []}
            id="group-role-requests-list"
            class={["space-y-3", @join_requests != [] && "mt-3"]}
          >
            <li :for={request <- @role_requests} id={"group-role-request-#{request.id}"}>
              <div class="rounded-2xl border border-dashed border-primary/30 bg-base-100/50 px-4 py-3">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0 flex-1">
                    <Components.profile_identity
                      profile={request.profile}
                      current_profile={@current_profile}
                      direct_group_link={true}
                    />
                    <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/65">
                      <span>{gettext("asks for roles")}</span>
                      <Components.local_time
                        id={"group-role-request-inserted-at-#{request.id}"}
                        datetime={request.updated_at}
                      />
                    </div>
                  </div>
                  <.button
                    id={"group-decide-role-request-#{request.id}"}
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
                <.request_details
                  id={"group-role-request-#{request.id}"}
                  note={request.note}
                  keys={request.role_keys}
                  roles={@request_roles}
                />
              </div>
            </li>
          </ul>
        </div>

        <p
          :if={@elects?}
          id="group-members-elected"
          class="mb-4 flex items-start gap-2 rounded-2xl border border-primary/25 bg-primary/5 px-4 py-3 text-sm"
        >
          <.icon name="hero-scale" class="mt-0.5 size-4 shrink-0 text-primary" />
          <span>
            {gettext(
              "This group elects its admins. Admin comes and goes only by a decision of a poll, and the admins it had before the first election stay for the time being."
            )}
          </span>
        </p>

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

        <div
          :if={!@group.is_direct}
          id="group-members-filters"
          class="mb-3 flex items-center justify-between gap-2"
        >
          <p id="group-members-count" class="px-1 text-sm text-base-content/65">
            <%= if @filter_role do %>
              {ngettext(
                "%{count} member holds the role %{role}",
                "%{count} members hold the role %{role}",
                @pagination.total_count,
                role: RolesTab.role_label(@filter_role)
              )}
            <% else %>
              {ngettext("%{count} member", "%{count} members", @pagination.total_count)}
            <% end %>
          </p>
          <ChoiceMenus.choice_toggle
            id="group-members-role"
            choices={@role_choices}
            selected={@role_filter}
            idle_label={gettext("Role")}
            title={gettext("Show the members who hold one role")}
            label={gettext("Role of members")}
          />
        </div>

        <ul id="group-members-list" class="space-y-2" phx-update="stream">
          <li
            :if={@pagination.loaded_count == 0}
            id="group-members-empty"
            class="text-base-content/70"
          >
            {if @filter_role,
              do: gettext("Nobody holds this role."),
              else: gettext("No members.")}
          </li>

          <li
            :for={
              {dom_id,
               %{
                 profile: member,
                 role_keys: role_keys,
                 inherited?: inherited?,
                 inherited_role_keys: inherited_role_keys,
                 decided: decided
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
                  group_id={@group.id}
                  roles={member_roles(@assignable_roles, role_keys)}
                  decided={decided}
                  interim_keys={interim_keys(@elects?, role_keys, inherited_role_keys, decided)}
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
                    !inherited? && (@access.admin? or GroupRole.admin_key() not in role_keys) &&
                    !(@elects? and GroupRole.admin_key() in role_keys)
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
              locked_keys={@locked_keys}
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

        <ChoiceMenus.choice_menu
          :if={!@group.is_direct}
          id="group-members-role"
          choices={@role_choices}
          selected={@role_filter}
          event="filter_members_role"
          param="role"
          label={gettext("Role of members")}
        />

        <section :if={@processes != []} id="group-processes" class="mt-8">
          <div class="mb-3 flex items-start justify-between gap-3 px-1">
            <div>
              <h4 class="flex items-center gap-1.5 text-sm font-semibold text-base-content">
                <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/60" />
                {gettext("Processes")}
              </h4>
              <p class="text-xs text-base-content/70">
                {gettext(
                  "They act for the group's apps and are not counted among the members. An app's rules start and stop them, or its editors on the Processes tab."
                )}
              </p>
            </div>
            <.button
              id="group-processes-link"
              type="button"
              phx-click="switch_tab"
              phx-value-tab="processes"
              variant="soft"
              size="sm"
            >
              {gettext("How they are doing")}
              <.icon name="hero-arrow-right" class="size-3.5" />
            </.button>
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
                    permissions: ProcessesTab.missing_permissions(entry.warning["missing"])
                  )}
                </p>
                <p :if={entry.warning["owner_left"]} id={"process-#{entry.id}-owner-left"}>
                  <.icon name="hero-user-minus" class="mr-1 size-3.5 align-[-2px]" />
                  {if(entry.process.drawn,
                    do:
                      gettext(
                        "Its owner no longer edits the app. Whoever saves the drawing next takes it over."
                      ),
                    else:
                      gettext(
                        "Its owner no longer edits the app. Whoever saves its rules next takes it over."
                      )
                  )}
                </p>
              </div>

              <.role_editor
                :if={@manage_roles?}
                id={"process-#{entry.id}"}
                profile_id={entry.id}
                roles={@assignable_roles}
                role_keys={entry.role_keys}
                locked_keys={@locked_keys}
              />
            </li>
          </ul>
        </section>
      </Components.tab_body>
    </div>
    """
  end

  # Every member first, then each role of the manifest in force but Everyone,
  # which every member holds.
  defp role_choices(roles) do
    [%{key: "", icon: "hero-user-group", title: gettext("All members")}] ++
      for role <- roles, role.key != GroupRole.everyone_key() do
        %{key: role.key, icon: RolesTab.role_icon(role), title: RolesTab.role_label(role)}
      end
  end

  attr :id, :string, required: true, doc: "the prefix of the ids, such as `member-12`"
  attr :roles, :list, required: true, doc: "the assigned roles to show"
  attr :group_id, :integer, default: nil
  attr :decided, :map, default: %{}, doc: "`%{role_key => poll_id}`: roles a decision gave"
  attr :interim_keys, :list, default: [], doc: "roles held until the first election"

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
        <.link
          :if={@decided[role.key] && @group_id}
          id={"#{@id}-role-decided-#{role.key}"}
          patch={~p"/groups/#{@group_id}/polls?#{[poll: @decided[role.key]]}"}
          title={gettext("Given by a decision of a poll")}
          class="-mr-1 inline-flex items-center gap-0.5 rounded-full bg-base-100/70 px-1.5 font-semibold underline-offset-2 hover:underline"
        >
          <.icon name="hero-scale" class="size-3" />
          {gettext("elected")}
        </.link>
        <span
          :if={role.key in @interim_keys}
          id={"#{@id}-role-interim-#{role.key}"}
          title={gettext("Until the group's first election")}
          class="-mr-1 rounded-full bg-base-100/70 px-1.5"
        >
          {gettext("for now")}
        </span>
      </span>
    </div>
    """
  end

  # Admin held of one's own, by no decision, in a group that elects its admins.
  defp interim_keys(true, role_keys, inherited_role_keys, decided) do
    key = GroupRole.admin_key()

    if key in role_keys and key not in inherited_role_keys and not Map.has_key?(decided, key),
      do: [key],
      else: []
  end

  defp interim_keys(false, _role_keys, _inherited_role_keys, _decided), do: []

  attr :id, :string, required: true, doc: "the prefix of the ids, such as `member-12`"
  attr :profile_id, :integer, required: true
  attr :roles, :list, required: true, doc: "the roles that may be assigned"
  attr :role_keys, :list, required: true
  attr :inherited_role_keys, :list, default: []
  attr :locked_keys, :list, default: [], doc: "roles only a decision changes"

  defp role_editor(assigns) do
    assigns = assign(assigns, :fixed_keys, assigns.inherited_role_keys ++ assigns.locked_keys)

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
        disabled={role.key in @fixed_keys}
        title={role_toggle_title(role.key, @inherited_role_keys, @locked_keys)}
        class={[
          "inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs font-semibold shadow-xs transition duration-150 ease-out",
          role_toggle_class(role.key, @role_keys, @fixed_keys)
        ]}
      >
        <.icon
          name={role_toggle_icon(role.key, @role_keys, @fixed_keys)}
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

    collection =
      if process.collection,
        do: [gettext("collection %{collection}", collection: process.collection)],
        else: []

    Enum.join(app ++ collection ++ [owner], " · ")
  end

  defp role_toggle_title(key, inherited_role_keys, locked_keys) do
    cond do
      key in inherited_role_keys -> gettext("Inherited from the parent group")
      key in locked_keys -> gettext("Elected: only a decision of a poll changes it")
      true -> nil
    end
  end

  # A role held through the parent is locked: it is changed there. So is
  # Admin where the group elects it.
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

  attr :id, :string, required: true
  attr :note, :string, default: nil
  attr :keys, :list, required: true
  attr :roles, :list, required: true

  # What a request asks for and why, under who asked.
  defp request_details(assigns) do
    ~H"""
    <div :if={@note || @keys != []} class="mt-2 space-y-1.5">
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
end
