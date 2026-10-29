defmodule PotokIdeWeb.GroupLive.Show.RolesTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :access, Access, required: true
  attr :manifest_owner, :map, default: nil, doc: "the group whose manifest this group uses"
  attr :new_role_form, :any, required: true
  attr :role_member_counts, :map, default: %{}
  attr :members_count, :integer, default: 0

  def panel(assigns) do
    manifest = assigns.access.manifest
    own? = Access.own_manifest?(assigns.group, manifest)
    roles = if manifest, do: manifest.roles, else: []

    rename_forms =
      Map.new(roles, fn role ->
        {role.key,
         to_form(%{"key" => role.key, "name" => role.name}, as: :role, id: "role-#{role.key}")}
      end)

    assigns =
      assigns
      |> assign(:roles, roles)
      |> assign(:rename_forms, rename_forms)
      |> assign(:own?, own?)
      |> assign(:editable?, own? and assigns.access.admin? and not assigns.group.is_root)
      |> assign(:permissions, GroupRole.permissions())

    ~H"""
    <div id="group-panel-roles" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.group_path group={@group} current_profile={@current_profile} class="shadow-md" />

      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain pt-4 pb-6">
        <div class="mb-4 px-1">
          <h3 class="card-title">{gettext("Roles")}</h3>
          <p class="mt-1 text-sm text-base-content/65">
            {gettext(
              "Roles allow or deny what members can do in this group. A denial wins over an allowance, and every member has the everyone role."
            )}
          </p>
        </div>

        <div
          id="group-manifest-source"
          class="mb-5 flex flex-wrap items-center gap-3 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
        >
          <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
            <.icon
              name={if(@own?, do: "hero-document-text", else: "hero-arrow-down-on-square")}
              class="size-5"
            />
          </span>
          <div class="min-w-0 flex-1">
            <%= cond do %>
              <% @group.is_root -> %>
                <p class="text-sm font-semibold">{gettext("Default manifest")}</p>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Groups without their own manifest use these roles. They cannot be changed."
                  )}
                </p>
              <% @own? -> %>
                <p class="text-sm font-semibold">{gettext("This group has its own manifest")}</p>
                <p class="text-xs text-base-content/60">
                  {gettext("Sub-groups without their own manifest use these roles too.")}
                </p>
              <% true -> %>
                <p class="text-sm font-semibold">
                  {gettext("Inherited from")}
                  <.link
                    :if={@manifest_owner}
                    id="group-manifest-owner-link"
                    navigate={~p"/groups/#{@manifest_owner.id}/roles"}
                    class="link link-primary"
                  >
                    {manifest_owner_name(@manifest_owner)}
                  </.link>
                </p>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Roles are assigned in each group separately. Create an own manifest to change the roles themselves."
                  )}
                </p>
            <% end %>
          </div>
          <button
            :if={@access.admin? and !@own? and !@group.is_direct}
            id="create-own-manifest-button"
            type="button"
            phx-click="create_own_manifest"
            class="btn btn-sm rounded-full border border-primary/40 bg-primary/10 text-primary transition hover:-translate-y-px hover:bg-primary/15 active:scale-95"
          >
            <.icon name="hero-document-duplicate" class="size-4" />
            {gettext("Create own manifest")}
          </button>
          <button
            :if={@editable?}
            id="revert-manifest-button"
            type="button"
            phx-click="revert_manifest"
            data-confirm={
              gettext(
                "Use the parent group's roles again? Roles that only exist in this manifest are removed from members."
              )
            }
            class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 transition hover:-translate-y-px active:scale-95"
          >
            <.icon name="hero-arrow-uturn-up" class="size-4" />
            {gettext("Inherit again")}
          </button>
        </div>

        <.form
          :if={@editable?}
          for={@new_role_form}
          id="new-role-form"
          phx-change="validate_role"
          phx-submit="create_role"
          class="mb-5 flex items-start gap-2 rounded-3xl border border-dashed border-base-300 bg-base-100/50 p-3"
        >
          <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
            <.input
              field={@new_role_form[:name]}
              id="new-role-name"
              placeholder={gettext("New role, e.g. moderators")}
              aria-label={gettext("Role name")}
              autocomplete="off"
            />
          </div>
          <.button id="new-role-submit" class="btn btn-primary rounded-full">
            <.icon name="hero-plus" class="size-4" />
            {gettext("Add role")}
          </.button>
        </.form>

        <ul id="group-roles-list" class="space-y-4">
          <li
            :for={role <- @roles}
            id={"role-#{role.key}"}
            class="rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <div class="flex flex-wrap items-center gap-3">
              <span class={[
                "inline-flex size-9 shrink-0 items-center justify-center rounded-full",
                role_badge_class(role)
              ]}>
                <.icon name={role_icon(role)} class="size-4" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="flex flex-wrap items-baseline gap-x-2 font-semibold">
                  <span id={"role-#{role.key}-label"}>{role_label(role)}</span>
                  <span class="text-xs font-normal text-base-content/50">@{role.name}</span>
                </p>
                <p class="text-xs text-base-content/60">{role_summary(role)}</p>
              </div>
              <span
                :if={!@group.is_root}
                id={"role-#{role.key}-count"}
                class="inline-flex h-7 items-center gap-1 rounded-full border border-base-300 bg-base-100 px-2.5 text-xs font-semibold text-base-content/70 tabular-nums"
              >
                <.icon name="hero-user" class="size-3.5" />
                {role_count(role, @role_member_counts, @members_count)}
              </span>
              <button
                :if={@editable? and !GroupRole.builtin?(role)}
                id={"role-#{role.key}-rename"}
                type="button"
                phx-click={
                  JS.toggle_class("hidden flex", to: "#role-#{role.key}-form")
                  |> JS.focus(to: "#role-#{role.key}-name")
                }
                aria-label={gettext("Rename role")}
                title={gettext("Rename role")}
                class="inline-flex items-center rounded-full p-1.5 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
              <button
                :if={@editable? and !GroupRole.builtin?(role)}
                id={"role-#{role.key}-delete"}
                type="button"
                phx-click="delete_role"
                phx-value-key={role.key}
                data-confirm={
                  gettext(
                    "Delete the role %{name}? Members lose it in every group using this manifest.",
                    name: role.name
                  )
                }
                aria-label={gettext("Delete role")}
                title={gettext("Delete role")}
                class="inline-flex items-center rounded-full p-1.5 text-base-content/55 transition-colors hover:bg-error/10 hover:text-error"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>

            <.form
              :if={@editable? and !GroupRole.builtin?(role)}
              for={@rename_forms[role.key]}
              id={"role-#{role.key}-form"}
              phx-submit="rename_role"
              class="mt-3 hidden items-start gap-2"
            >
              <.input field={@rename_forms[role.key][:key]} type="hidden" />
              <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
                <.input
                  field={@rename_forms[role.key][:name]}
                  id={"role-#{role.key}-name"}
                  aria-label={gettext("Role name")}
                  autocomplete="off"
                />
              </div>
              <.button class="btn btn-primary rounded-full">{gettext("Save")}</.button>
            </.form>

            <div
              :if={role.key != GroupRole.admin_key()}
              id={"role-#{role.key}-permissions"}
              class="mt-4 divide-y divide-base-300/60 overflow-hidden rounded-2xl border border-base-300/60"
            >
              <div
                :for={permission <- @permissions}
                id={"role-#{role.key}-#{permission}"}
                class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 bg-base-100/60 px-3 py-2.5"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium">{permission_label(permission)}</p>
                  <p class="text-xs text-base-content/55">{permission_description(permission)}</p>
                </div>
                <.permission_control
                  role={role}
                  permission={permission}
                  state={permission_state(role, permission)}
                  editable={@editable?}
                />
              </div>
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :role, GroupRole, required: true
  attr :permission, :atom, required: true
  attr :state, :atom, required: true
  attr :editable, :boolean, required: true

  defp permission_control(%{editable: false} = assigns) do
    ~H"""
    <span
      id={"role-#{@role.key}-#{@permission}-state"}
      data-state={@state}
      class={[
        "inline-flex h-7 items-center gap-1 rounded-full border px-2.5 text-xs font-semibold",
        state_class(@state, true)
      ]}
    >
      <.icon name={state_icon(@state)} class="size-3.5" />
      {state_label(@state)}
    </span>
    """
  end

  defp permission_control(assigns) do
    # "everyone" can only allow: a denial there would just block every role.
    assigns =
      assign(
        assigns,
        :states,
        if(assigns.role.key == GroupRole.everyone_key(),
          do: [:allow, :neutral],
          else: [:allow, :neutral, :deny]
        )
      )

    ~H"""
    <div
      role="radiogroup"
      aria-label={permission_label(@permission)}
      class="inline-flex shrink-0 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/60 p-0.5"
    >
      <button
        :for={state <- @states}
        id={"role-#{@role.key}-#{@permission}-#{state}"}
        type="button"
        role="radio"
        aria-checked={to_string(state == @state)}
        phx-click="set_role_permission"
        phx-value-key={@role.key}
        phx-value-permission={@permission}
        phx-value-state={state}
        title={state_label(state)}
        class={[
          "inline-flex h-7 items-center gap-1 rounded-full px-2.5 text-xs font-semibold transition duration-150 ease-out active:scale-95",
          if(state == @state,
            do: ["shadow-sm", state_class(state, true)],
            else:
              "border border-transparent text-base-content/55 hover:bg-base-100 hover:text-base-content"
          )
        ]}
      >
        <.icon name={state_icon(state)} class="size-3.5" />
        <span class="hidden sm:inline">{state_label(state)}</span>
      </button>
    </div>
    """
  end

  defp permission_state(%GroupRole{} = role, permission) do
    cond do
      permission in role.denied -> :deny
      permission in role.allowed -> :allow
      true -> :neutral
    end
  end

  defp state_class(:allow, _active?),
    do: "border border-emerald-500/40 bg-emerald-500/10 text-emerald-700"

  defp state_class(:deny, _active?), do: "border border-error/40 bg-error/10 text-error"

  defp state_class(:neutral, _active?),
    do: "border border-base-300 bg-base-100 text-base-content/70"

  defp state_icon(:allow), do: "hero-check"
  defp state_icon(:deny), do: "hero-no-symbol"
  defp state_icon(:neutral), do: "hero-minus"

  defp state_label(:allow), do: gettext("Allow")
  defp state_label(:deny), do: gettext("Deny")
  defp state_label(:neutral), do: gettext("Not set")

  defp role_count(%GroupRole{key: "everyone"}, _counts, members_count), do: members_count
  defp role_count(%GroupRole{key: key}, counts, _members_count), do: Map.get(counts, key, 0)

  defp manifest_owner_name(%{is_root: true}), do: gettext("the default manifest")
  defp manifest_owner_name(%{name: name}), do: name

  defp role_summary(%GroupRole{key: "admin"}),
    do: gettext("Has every permission, manages roles and assigns them to members.")

  defp role_summary(%GroupRole{key: "everyone"}), do: gettext("Every member of the group.")
  defp role_summary(%GroupRole{}), do: gettext("Assigned to members by an admin.")

  defp role_badge_class(%GroupRole{key: "admin"}), do: "bg-amber-500/15 text-amber-700"
  defp role_badge_class(%GroupRole{key: "everyone"}), do: "bg-base-300/70 text-base-content/70"
  defp role_badge_class(%GroupRole{}), do: "bg-primary/10 text-primary"

  @doc "Icon of a role, shared with the members tab."
  def role_icon(%GroupRole{key: "admin"}), do: "hero-shield-check"
  def role_icon(%GroupRole{key: "everyone"}), do: "hero-users"
  def role_icon(%GroupRole{}), do: "hero-tag"

  @doc "Display name of a role; built-in roles are translated."
  def role_label(%GroupRole{key: "admin"}), do: gettext("Admin")
  def role_label(%GroupRole{key: "everyone"}), do: gettext("Everyone")
  def role_label(%GroupRole{name: name}), do: name

  def permission_label(:post_values), do: gettext("Post values")
  def permission_label(:react), do: gettext("React")
  def permission_label(:open_threads), do: gettext("Open threads")
  def permission_label(:create_subgroups), do: gettext("Create sub-groups")
  def permission_label(:invite_members), do: gettext("Invite members")
  def permission_label(:mention_roles), do: gettext("Mention roles")
  def permission_label(:manage_join_requests), do: gettext("Manage access requests")
  def permission_label(:remove_members), do: gettext("Remove members")
  def permission_label(:delete_values), do: gettext("Delete values")
  def permission_label(:edit_group), do: gettext("Edit group")

  defp permission_description(:post_values), do: gettext("Write values and replies in the chat.")
  defp permission_description(:react), do: gettext("Add emoji reactions to values.")
  defp permission_description(:open_threads), do: gettext("Start a thread from a value.")
  defp permission_description(:create_subgroups), do: gettext("Create groups inside this group.")
  defp permission_description(:invite_members), do: gettext("Invite profiles to this group.")

  defp permission_description(:mention_roles),
    do: gettext("Mention roles and @everyone to notify their members.")

  defp permission_description(:manage_join_requests),
    do: gettext("Accept or reject requests to join.")

  defp permission_description(:remove_members), do: gettext("Remove members who are not admins.")
  defp permission_description(:delete_values), do: gettext("Delete values written by others.")

  defp permission_description(:edit_group),
    do: gettext("Change the group's settings, description and app data.")
end
