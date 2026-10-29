defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.{Components, RolesTab}

  attr :members, :any, required: true, doc: "stream of `%{id, profile, role_keys}`"
  attr :pagination, :map, required: true
  attr :current_profile, :map, required: true
  attr :group, :map, required: true
  attr :access, Access, required: true
  attr :join_requests, :list, default: []
  attr :pending_join_requests_count, :integer, default: 0

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
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain pt-4 pb-4">
        <h3 :if={!@group.is_direct} class="card-title mb-2">{gettext("Members")}</h3>

        <div class=" flex flex-row">
          <.icon :if={@group.is_direct} name="hero-user" />
          <.icon :if={@group.is_direct} name="hero-user" />
        </div>

        <div
          :if={Access.can?(@access, :manage_join_requests) && !@group.is_direct}
          id="group-join-requests-panel"
          class="mb-5 rounded-3xl border border-base-300/70 bg-base-50/70 p-4 shadow-sm"
        >
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h4 class="text-sm font-semibold text-base-950">{gettext("Access requests")}</h4>

              <p class="text-xs text-base-900/70">
                {gettext("Profiles waiting for approval to join this public group.")}
              </p>
            </div>

            <span
              id="group-join-requests-count"
              class="inline-flex min-w-8 items-center justify-center rounded-full bg-amber-500 px-2 py-1 text-xs font-semibold text-base-950"
            >
              {@pending_join_requests_count}
            </span>
          </div>

          <div
            :if={@join_requests == []}
            id="group-join-requests-empty"
            class="rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3 text-sm text-base-950/70"
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
                  <div class="mt-2 text-xs text-base-950/65">
                    <Components.local_time
                      id={"group-join-request-inserted-at-#{request.id}"}
                      datetime={request.inserted_at}
                    />
                  </div>
                </div>

                <div class="flex shrink-0 items-center gap-2">
                  <button
                    id={"group-accept-join-request-#{request.id}"}
                    type="button"
                    phx-click="accept_join_request"
                    phx-value-id={request.id}
                    class="btn btn-sm rounded-full border border-emerald-500/40 bg-emerald-500/10 text-emerald-700 hover:border-emerald-500/60 hover:bg-emerald-500/15"
                  >
                    {gettext("Accept")}
                  </button>
                  <button
                    id={"group-reject-join-request-#{request.id}"}
                    type="button"
                    phx-click="reject_join_request"
                    phx-value-id={request.id}
                    class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
                  >
                    {gettext("Reject")}
                  </button>
                </div>
              </div>
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
            :for={{dom_id, %{profile: member, role_keys: role_keys}} <- @members}
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
                <div
                  :if={!@group.is_direct and member_roles(@assignable_roles, role_keys) != []}
                  id={"member-#{member.id}-roles"}
                  class="flex flex-wrap items-center gap-1"
                >
                  <span
                    :for={role <- member_roles(@assignable_roles, role_keys)}
                    id={"member-#{member.id}-role-badge-#{role.key}"}
                    class={[
                      "inline-flex h-6 items-center gap-1 rounded-full px-2 text-[11px] font-semibold",
                      if(role.key == GroupRole.admin_key(),
                        do: "bg-amber-500/15 text-amber-700",
                        else: "bg-primary/10 text-primary"
                      )
                    ]}
                  >
                    <.icon name={RolesTab.role_icon(role)} class="size-3" />
                    {RolesTab.role_label(role)}
                  </span>
                </div>
              </div>
              <button
                :if={@manage_roles?}
                id={"member-#{member.id}-roles-toggle"}
                type="button"
                phx-click={JS.toggle_class("hidden flex", to: "#member-#{member.id}-role-editor")}
                aria-controls={"member-#{member.id}-role-editor"}
                aria-label={gettext("Roles of %{username}", username: member.username)}
                title={gettext("Roles")}
                class="inline-flex shrink-0 items-center rounded-full p-1.5 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
              >
                <.icon name="hero-tag" class="size-4" />
              </button>
              <button
                :if={
                  @can_remove? && member.id != @current_profile.id && !@group.is_direct &&
                    (@access.admin? or GroupRole.admin_key() not in role_keys)
                }
                id={"group-remove-member-#{member.id}"}
                type="button"
                phx-click="remove_member"
                phx-value-id={member.id}
                data-confirm={
                  gettext("Remove %{username} from this group?", username: member.username)
                }
                aria-label={gettext("Remove %{username}", username: member.username)}
                class="btn btn-ghost btn-xs rounded-full border border-error/30 bg-error/5 text-error transition-colors hover:border-error/50 hover:bg-error/10"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <%!-- Toggled on the client; stays open while the member is re-streamed. --%>
            <div
              :if={@manage_roles?}
              id={"member-#{member.id}-role-editor"}
              class="hidden flex-wrap items-center gap-1.5 border-t border-base-300/60 px-1 pt-2 pb-1 mt-1"
            >
              <button
                :for={role <- @assignable_roles}
                id={"member-#{member.id}-role-#{role.key}"}
                type="button"
                phx-click="toggle_member_role"
                phx-value-profile-id={member.id}
                phx-value-key={role.key}
                aria-pressed={to_string(role.key in role_keys)}
                class={[
                  "inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs font-semibold shadow-xs transition duration-150 ease-out hover:-translate-y-px active:scale-95",
                  if(role.key in role_keys,
                    do: "border-primary/50 bg-primary/10 text-primary",
                    else:
                      "border-base-300 bg-base-100 text-base-content/65 hover:border-base-content/25 hover:bg-base-200"
                  )
                ]}
              >
                <.icon
                  name={if(role.key in role_keys, do: "hero-check", else: "hero-plus")}
                  class="size-3.5"
                />
                {RolesTab.role_label(role)}
              </button>
            </div>
          </li>
        </ul>

        <div :if={@pagination.has_more?} class="mt-4 flex justify-center">
          <button
            id="group-members-load-more"
            type="button"
            phx-click="load_more_members"
            class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 px-4"
          >
            {gettext("Load more members")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Assigned roles in the manifest's display order; keys of roles missing
  # from the effective manifest are left out.
  defp member_roles(assignable_roles, role_keys) do
    Enum.filter(assignable_roles, &(&1.key in role_keys))
  end
end
