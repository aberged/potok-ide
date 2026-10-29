defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAccountInvitation, GroupInvitation, Value}

  alias PotokIdeWeb.GroupLive.Show.{
    Components,
    CreateGroupTab,
    EditGroupTab,
    GroupDescriptionTab,
    InviteProfileTab,
    MembersTab,
    SubGroupsTab,
    ValuesTab
  }

  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.GroupLive.Show.{AppApi, Components}

  @children_page_size 20
  @members_page_size 20
  @values_page_size 20

  # Bursts of `group_updated` / unread broadcasts are coalesced into one
  # reload. 0 (the test config) applies them inline.
  @refresh_debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)

  @impl true
  def render(assigns) do
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
    >
      <%!-- Online indicators are toggled by this rule set instead of re-rendering streamed items. --%>
      <style id="group-presence-style">
        <%= Components.presence_css(@online_profile_ids) %>
      </style>

      <div class="relative z-50 shrink-0 justify-center rounded-4xl border border-base-300/70 bg-base-100/70 px-4 py-3 shadow-lg shadow-primary/5 backdrop-blur">
        <div class="flex items-center gap-3">
          <div :if={!@group.is_root and @group.parent_id} class="pt-1">
            <.link
              navigate={~p"/groups/#{@group.parent_id}/sub_groups"}
              class="link text-xl no-underline"
            >
              {"❮"}
            </.link>
          </div>

          <div class="min-w-0 flex-1">
            <div :if={!@group.is_root} class="flex items-center gap-3">
              <Components.group_identity
                group={@group}
                current_profile={@current_profile}
                avatar_size="size-10"
                text_class="text-md"
                pending_join_requests_count={
                  if(@group.creator_id == @current_profile.id,
                    do: @pending_join_requests_count,
                    else: 0
                  )
                }
                unread_count={Map.get(@group_unread_counts, @group.id, 0)}
              />
            </div>

            <div
              :if={@group.is_root}
              id="group-sub-groups-kind-tabs"
              class="relative flex w-fit items-center gap-2 p-1 border rounded-full bg-base-100 border-base-300"
            >
              <button
                id="group-sub-groups-kind-direct"
                type="button"
                phx-click="switch_sub_groups_kind"
                phx-value-kind="direct"
                class={[
                  "relative btn btn-sm rounded-full",
                  if(@sub_groups_kind == "direct",
                    do: "btn-primary text-white",
                    else: "btn-ghost border border-base-300"
                  )
                ]}
              >
                <.icon name="hero-users" class="size-4" />
                <span
                  :if={@direct_sub_groups_unread_count > 0}
                  id="group-sub-groups-kind-direct-unread-badge"
                  class="absolute -top-[.2rem] left-[1.2rem] ml-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
                >
                  {unread_badge_label(@direct_sub_groups_unread_count)}
                </span>
              </button>
              <button
                id="group-sub-groups-kind-other"
                type="button"
                phx-click="switch_sub_groups_kind"
                phx-value-kind="other"
                class={[
                  "relative btn btn-sm rounded-full",
                  if(@sub_groups_kind == "other",
                    do: "btn-primary text-white",
                    else: "btn-ghost border border-base-300"
                  )
                ]}
              >
                <.icon name="hero-user-group" class="size-4" />
                <span
                  :if={@other_sub_groups_unread_count > 0}
                  id="group-sub-groups-kind-other-unread-badge"
                  class="absolute -top-[.2rem] -right-[.1rem] ml-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
                >
                  {unread_badge_label(@other_sub_groups_unread_count)}
                </span>
              </button>
            </div>
          </div>

          <div
            :if={!@group.is_root and !@is_member}
            id="group-join-request-callout"
            class="flex shrink-0 items-center"
          >
            <button
              :if={is_nil(@pending_join_request)}
              id="group-request-access"
              type="button"
              phx-click="request_join"
              class="btn rounded-full border border-sky-500/40 bg-sky-500/10 text-sky-700 hover:border-sky-500/60 hover:bg-sky-500/15"
            >
              {gettext("Request access")}
            </button>
            <div
              :if={!is_nil(@pending_join_request)}
              id="group-request-access-pending"
              class="inline-flex items-center rounded-full bg-sky-900 px-3 py-2 text-sm font-medium text-sky-50"
            >
              {gettext("Access request pending")}
            </div>
          </div>

          <button
            :if={!@group.is_root and @is_member}
            id="group-values-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="values"
            aria-label={gettext("Open values tab")}
            class="relative cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-chat-bubble-oval-left-ellipsis"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
            <span
              :if={@current_group_unread_count > 0}
              id="group-values-unread-badge"
              class="absolute -right-1 -top-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
            >
              {unread_badge_label(@current_group_unread_count)}
            </span>
          </button>
          <button
            :if={(!@group.is_root and @is_member) or @group.is_public}
            id="group-subgroups-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="sub_groups"
            aria-label={gettext("Open sub-groups tab")}
            class="relative cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-folder-open"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
            <span
              :if={@sub_groups_unread_count > 0}
              id="group-sub-groups-unread-badge"
              class="absolute -right-1 -top-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
            >
              {unread_badge_label(@sub_groups_unread_count)}
            </span>
          </button>
          <button
            :if={@group.parent_id != nil && @is_member && !@group.is_direct}
            id="group-invite-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="invite_profile"
            aria-label={gettext("Open invite profile tab")}
            class="cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-user-plus"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
          </button>
          <button
            :if={@group.parent_id == nil && @is_member}
            id="group-invite-account"
            type="button"
            phx-click="invite_account"
            aria-label={gettext("Open invite account tab")}
            class="cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-user-plus"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
          </button>
          <div class="relative">
            <button
              :if={@group.parent_id != nil && @is_member}
              id="group-members-summary"
              type="button"
              phx-click="switch_tab"
              phx-value-tab="members"
              aria-label={gettext("Open members tab")}
              class="avatar-group relative -space-x-6 cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
            >
              <div :for={m <- @first3_members} class="">
                <Components.profile_identity
                  profile={m}
                  avatar_size="size-6"
                  text_class="hidden"
                  sharing_badge_text_class="hidden"
                />
              </div>

              <div :if={@members_count > 3} class="avatar avatar-placeholder border-3">
                <div class="bg-neutral text-neutral-content size-5 text-xs">
                  <span>+{@members_count - length(@first3_members)}</span>
                </div>
              </div>
            </button>
            <span
              :if={@pending_join_requests_count > 0 and @group.creator_id == @current_profile.id}
              id="group-join-requests-badge"
              class="absolute -right-1 -top-2 inline-flex min-w-5 items-center justify-center rounded-full bg-amber-500 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-amber-950 shadow-sm"
            >
              {unread_badge_label(@pending_join_requests_count)}
            </span>
          </div>

          <Layouts.drop_down_menu id="group-actions-menu" icon="hero-ellipsis-horizontal">
            <div class="flex min-w-56 flex-col gap-2 z-100">
              <Components.group_tab_button
                :if={!@group.is_root}
                id="group-tab-group-home"
                tab="group_home"
                active_tab={@active_tab}
                label={@group.name}
                icon="hero-home"
              />
              <Components.group_tab_button
                :if={@group.parent_id != nil and @is_member}
                id="group-tab-values"
                tab="values"
                active_tab={@active_tab}
                label={gettext("Values")}
                icon="hero-chat-bubble-oval-left-ellipsis"
              />
              <Components.group_tab_button
                :if={@group.is_root or @is_member or @group.is_public}
                id="group-tab-sub-groups"
                tab="sub_groups"
                active_tab={@active_tab}
                label={gettext("Sub-groups")}
                icon="hero-folder-open"
              />
              <Components.group_tab_button
                :if={@group.parent_id != nil && @is_member}
                id="group-tab-members"
                tab="members"
                active_tab={@active_tab}
                label={members_tab_label(@pending_join_requests_count, @group, @current_profile)}
                icon="hero-user-group"
              />
              <Components.group_tab_button
                :if={@is_member}
                id="group-tab-create-sub-group"
                tab="create_group"
                active_tab={@active_tab}
                label={gettext("Create sub-group")}
                icon="hero-folder-plus"
              />
              <Components.group_tab_button
                :if={@is_member && @group.parent_id != nil && !@group.is_direct}
                id="group-tab-invite-profile"
                tab="invite_profile"
                active_tab={@active_tab}
                label={gettext("Invite profile")}
                icon="hero-user-plus"
              />
              <div class="flex flex-row justify-end gap-2">
                <Components.group_tab_button
                  :if={can_edit_group?(@current_profile, @group) and !@group.is_root}
                  id="group-tab-edit-group"
                  tab="edit_group"
                  active_tab={@active_tab}
                  label=""
                  icon="hero-cog-6-tooth"
                />
              </div>
            </div>
          </Layouts.drop_down_menu>
        </div>
      </div>

      <div class="flex min-h-0 flex-1 flex-col overflow-clip">
        <div class="flex min-h-0 flex-1 flex-col gap-2">
          <SubGroupsTab.panel
            :if={@active_tab == "sub_groups" or (@group.parent_id == nil and @active_tab == "values")}
            group={@group}
            current_profile={@current_profile}
            children={@streams.children}
            pagination={@children_pagination}
            pending_join_request_counts={@child_pending_join_request_counts}
            unread_counts={@group_unread_counts}
            is_member={@is_member}
            sub_groups_kind={@sub_groups_kind}
            direct_sub_groups_unread_count={@direct_sub_groups_unread_count}
            other_sub_groups_unread_count={@other_sub_groups_unread_count}
            children_search_query={@children_search_query}
          />
          <MembersTab.panel
            :if={@active_tab == "members"}
            members={@streams.members}
            pagination={@members_pagination}
            current_profile={@current_profile}
            group={@group}
            join_requests={@pending_join_requests}
            pending_join_requests_count={@pending_join_requests_count}
          />
          <ValuesTab.panel
            :if={@active_tab == "values" and @group.parent_id != nil and @is_member}
            values={@streams.values}
            has_more={@values_has_more?}
            group={@group}
            current_profile={@current_profile}
            editing_value_id={@editing_value && @editing_value.id}
            editing_value={@editing_value}
            edit_value_form={@edit_value_form}
            new_value_form={@new_value_form}
            is_member={@is_member}
          />
          <GroupDescriptionTab.panel
            :if={
              @active_tab == "group_home" or
                (@active_tab == "values" and @group.parent_id != nil and !@is_member)
            }
            group={@group}
            current_profile={@current_profile}
            is_member={@is_member}
            pending_join_request={@pending_join_request}
          />
          <CreateGroupTab.panel
            :if={@is_member and @active_tab == "create_group"}
            new_group_form={@new_group_form}
            format_options={@format_options}
            home_page_options={@home_page_options}
            value_parent_options={@value_parent_options}
            group={@group}
            current_profile={@current_profile}
          />
          <EditGroupTab.panel
            :if={can_edit_group?(@current_profile, @group) and @active_tab == "edit_group"}
            edit_group_form={@edit_group_form}
            description_details_open={@description_details_open}
            format_options={@format_options}
            home_page_options={@home_page_options}
            group={@group}
            current_profile={@current_profile}
          />
          <InviteProfileTab.panel
            :if={@is_member and @active_tab == "invite_profile"}
            invite_form={@invite_form}
            invite_form_version={@invite_form_version}
            invite_profile_suggestions={@invite_profile_suggestions}
            group={@group}
            current_profile={@current_profile}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(id)

    is_member = Social.member_of_group?(current_profile, group)
    active_tab = normalize_active_tab(Map.get(params, "tab"), group, is_member, current_profile)

    if can_view_group?(group, is_member) do
      if connected?(socket) do
        Social.subscribe_group(group)
        Social.subscribe_group_presence(group)
      end

      {:ok,
       socket
       |> stream_configure(:children, dom_id: &"child-group-#{&1.id}")
       |> stream_configure(:members, dom_id: &"member-#{&1.id}")
       |> stream_configure(:values, dom_id: &"value-#{&1.id}")
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> assign(:members_pagination, default_pagination(@members_page_size))
       |> assign(:values_has_more?, false)
       |> assign(:oldest_value_id, nil)
       |> assign(:newest_value_id, nil)
       |> assign(:loaded_value_ids, MapSet.new())
       |> assign(:loaded_children, [])
       |> assign(:pending_refresh, MapSet.new())
       |> assign(:app_api_bucket, AppApi.new_bucket())
       |> assign(:child_pending_join_request_counts, %{})
       |> assign(:group_unread_counts, %{})
       |> assign(:current_group_unread_count, 0)
       |> assign(:sub_groups_unread_count, 0)
       |> assign(:direct_sub_groups_unread_count, 0)
       |> assign(:other_sub_groups_unread_count, 0)
       |> assign(:children_search_query, "")
       |> assign(
         :sub_groups_kind,
         normalize_sub_groups_kind(Map.get(params, "sub_groups_kind"), group)
       )
       |> assign(:members_count, 0)
       |> assign(:first3_members, [])
       |> assign(:online_profile_ids, MapSet.new())
       |> assign(:presence_profile_id, nil)
       |> assign(:is_member, is_member)
       |> assign(:group, group)
       |> assign(:active_tab, active_tab)
       |> assign(:editing_value, nil)
       |> assign(:edit_value_form, nil)
       |> assign(:format_options, [{gettext("Markdown"), :markdown}, {gettext("HTML"), :html}])
       |> assign(:home_page_options, home_page_options())
       |> assign(:value_parent_options, [])
       |> assign(:new_value_form, empty_new_value_form())
       |> assign(:new_group_form, empty_new_group_form())
       |> assign(:edit_group_form, edit_group_form(group, active_tab))
       |> assign(:description_details_open, true)
       |> assign(:invite_form, empty_invite_form())
       |> assign(:invite_form_version, 0)
       |> assign(:invite_profile_suggestions, [])
       |> assign(:pending_join_request, nil)
       |> assign(:pending_join_requests, [])
       |> assign(:pending_join_requests_count, 0)
       |> load_group_data(group, active_tab)
       |> sync_group_presence()}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    active_tab =
      normalize_active_tab(
        Map.get(params, "tab"),
        socket.assigns.group,
        socket.assigns.is_member,
        socket.assigns.current_profile
      )

    sub_groups_kind =
      normalize_sub_groups_kind(Map.get(params, "sub_groups_kind"), socket.assigns.group)

    if active_tab == socket.assigns.active_tab and
         sub_groups_kind == socket.assigns.sub_groups_kind do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:active_tab, active_tab)
       |> assign(:sub_groups_kind, sub_groups_kind)
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> maybe_reload_edit_group_form(active_tab)
       |> load_group_data(socket.assigns.group, active_tab)}
    end
  end

  @impl true
  def handle_event("validate_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("group_id", group.id)

    changeset =
      %Value{}
      |> Value.changeset_for_update(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_value_form, to_form(changeset))}
  end

  def handle_event("create_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a group member to post values."))}
    else
      # The chat composer only posts chat values; app data goes through `app_api`.
      attrs =
        attrs
        |> Map.drop(["is_data", "data"])
        |> normalize_select_nil("parent_id")

      case Social.create_value(current_profile, group, attrs) do
        {:ok, value} ->
          socket =
            socket
            |> assign(:active_tab, "values")
            |> assign(:new_value_form, empty_new_value_form())
            |> push_event("value_composer_reset", %{})
            |> apply_value_created(value)

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create value."))}
      end
    end
  end

  # Single entry point for the sandboxed app frame (see `AppApi`). The client
  # hook only forwards whitelisted methods; the server checks them again.
  def handle_event("app_api", %{"method" => method} = params, socket) when is_binary(method) do
    {reply, socket} = AppApi.call(method, Map.get(params, "params") || %{}, socket)
    {:reply, reply, socket}
  end

  def handle_event("app_api", _params, socket) do
    {:reply, %{ok: false, error: "unknown_method"}, socket}
  end

  def handle_event("start_edit_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile
    previous_editing_value = socket.assigns.editing_value

    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value when value.creator_id != current_profile.id ->
        {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

      value ->
        # Re-insert both items so their edit buttons reflect the new editing state.
        {:noreply,
         socket
         |> assign(:editing_value, value)
         |> assign(:edit_value_form, to_form(Value.changeset(value, %{})))
         |> restream_value(previous_editing_value)
         |> restream_value(value)}
    end
  end

  def handle_event("validate_edit_value", %{"value" => attrs}, socket) do
    case socket.assigns.editing_value do
      nil ->
        {:noreply, socket}

      value ->
        changeset =
          value
          |> Value.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :edit_value_form, to_form(changeset))}
    end
  end

  def handle_event("save_edit_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile

    case socket.assigns.editing_value do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.update_value(current_profile, value, attrs) do
          {:ok, updated_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value updated."))
             |> assign(:editing_value, nil)
             |> assign(:edit_value_form, nil)
             |> apply_value_updated(updated_value)}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket, :edit_value_form, to_form(Map.put(changeset, :action, :validate)))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update value."))}
        end
    end
  end

  def handle_event("cancel_edit_value", _params, socket) do
    {:noreply, clear_edit_value(socket)}
  end

  def handle_event("delete_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile

    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.delete_value(current_profile, value) do
          {:ok, _deleted_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value deleted."))
             |> remove_value(value.id)}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only delete your own values."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete value."))}
        end
    end
  end

  # Sent by the reaction pills (`phx-click`) and by the emoji picker hook.
  def handle_event("toggle_reaction", %{"id" => id, "emoji" => emoji}, socket) do
    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a group member to react."))}
    else
      case loaded_value(socket, id) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Value not found."))}

        value ->
          case Social.toggle_value_reaction(
                 socket.assigns.current_profile,
                 socket.assigns.group,
                 value,
                 emoji
               ) do
            {:ok, updated_value} ->
              {:noreply, apply_value_updated(socket, updated_value)}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, gettext("Could not update reaction."))}
          end
      end
    end
  end

  def handle_event("switch_tab", %{"tab" => "group_home"}, socket) do
    {:noreply,
     redirect(
       socket,
       to:
         group_tab_path(
           socket.assigns.group,
           normalize_active_tab(
             "group_home",
             socket.assigns.group,
             socket.assigns.is_member,
             socket.assigns.current_profile
           ),
           sub_groups_kind: socket.assigns.sub_groups_kind
         )
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         group_tab_path(
           socket.assigns.group,
           normalize_active_tab(
             tab,
             socket.assigns.group,
             socket.assigns.is_member,
             socket.assigns.current_profile
           ),
           sub_groups_kind: socket.assigns.sub_groups_kind
         )
     )}
  end

  def handle_event("load_more_children", _params, socket) do
    {:noreply, load_more_children(socket)}
  end

  def handle_event("search_children", %{"children_search" => %{"q" => query}}, socket) do
    next_query = normalize_children_search_query(query)

    if next_query == socket.assigns.children_search_query do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:children_search_query, next_query)
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> reload_children()}
    end
  end

  def handle_event("search_children", _params, socket), do: {:noreply, socket}

  def handle_event("clear_children_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:children_search_query, "")
     |> assign(:children_pagination, default_pagination(@children_page_size))
     |> reload_children()}
  end

  def handle_event("switch_sub_groups_kind", %{"kind" => kind}, socket) do
    next_kind = normalize_sub_groups_kind(kind, socket.assigns.group)

    if next_kind == socket.assigns.sub_groups_kind do
      {:noreply, socket}
    else
      {:noreply,
       push_patch(socket,
         to:
           group_tab_path(socket.assigns.group, socket.assigns.active_tab,
             sub_groups_kind: next_kind
           )
       )}
    end
  end

  def handle_event("load_more_members", _params, socket) do
    {:noreply, load_more_members(socket)}
  end

  def handle_event("request_join", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Social.request_group_access(current_profile, group) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Access request sent."))
         |> refresh_group_data()}

      {:error, :group_not_public} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only public groups accept access requests."))}

      {:error, :already_a_member} ->
        {:noreply, put_flash(socket, :error, gettext("You are already a group member."))}

      {:error, :already_invited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You already have a pending invitation to this group.")
         )}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Access request already pending."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not send access request."))}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Integer.parse(id) do
      {member_id, ""} ->
        case Social.remove_group_member(current_profile, group, member_id) do
          {:ok, _member} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Member removed."))
             |> refresh_group_data()}

          {:error, :not_group_creator} ->
            {:noreply,
             put_flash(socket, :error, gettext("Only the group creator can remove members."))}

          {:error, :cannot_remove_group_creator} ->
            {:noreply, put_flash(socket, :error, gettext("The group creator cannot be removed."))}

          {:error, :not_a_group_member} ->
            {:noreply, put_flash(socket, :error, gettext("That profile is not a group member."))}

          {:error, :member_not_found} ->
            {:noreply, put_flash(socket, :error, gettext("Profile not found."))}

          {:error, :cannot_remove_root_group_members} ->
            {:noreply,
             put_flash(socket, :error, gettext("Root group members cannot be removed."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove member."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Profile not found."))}
    end
  end

  def handle_event("accept_join_request", %{"id" => id}, socket) do
    handle_join_request_action(
      socket,
      id,
      &Social.accept_group_join_request/3,
      gettext("Access request accepted.")
    )
  end

  def handle_event("reject_join_request", %{"id" => id}, socket) do
    handle_join_request_action(
      socket,
      id,
      &Social.reject_group_join_request/3,
      gettext("Access request rejected.")
    )
  end

  def handle_event("load_more_values", _params, socket) do
    {:noreply, load_more_values(socket)}
  end

  def handle_event("validate_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("parent_id", parent.id)
      |> Map.put_new("is_root", false)

    changeset =
      %Group{}
      |> Group.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_group_form, to_form(changeset))}
  end

  def handle_event("create_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to create sub-groups."))}
    else
      attrs =
        attrs
        |> normalize_select_nil("parent_value_id")
        |> Map.put("is_root", false)

      case Social.create_group(current_profile, parent, attrs) do
        {:ok, child} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Group created."))
           |> push_navigate(to: ~p"/groups/#{child.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_group_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create group."))}
      end
    end
  end

  def handle_event("validate_edit_group", %{"group" => attrs}, socket) do
    if can_edit_group?(socket.assigns.current_profile, socket.assigns.group) do
      changeset =
        socket.assigns.group
        |> Group.update_changeset(attrs)
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, :edit_group_form, to_form(changeset))}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Only the group creator can edit this group."))}
    end
  end

  def handle_event("save_edit_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not can_edit_group?(current_profile, group) do
      {:noreply,
       put_flash(socket, :error, gettext("Only the group creator can edit this group."))}
    else
      case Social.update_group(current_profile, group, attrs) do
        {:ok, updated_group} ->
          {:noreply,
           socket
           |> assign(:group, updated_group)
           |> assign(:edit_group_form, edit_group_form(updated_group, "edit_group"))
           |> put_flash(:info, gettext("Group updated."))
           |> refresh_group_data()}

        {:error, :not_group_creator} ->
          {:noreply,
           put_flash(socket, :error, gettext("Only the group creator can edit this group."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           assign(socket, :edit_group_form, to_form(Map.put(changeset, :action, :validate)))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update group."))}
      end
    end
  end

  def handle_event("delete_group_data_values", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not can_edit_group?(current_profile, group) do
      {:noreply,
       put_flash(socket, :error, gettext("Only the group creator can edit this group."))}
    else
      case Social.delete_group_data_values(current_profile, group) do
        {:ok, 0} ->
          {:noreply, put_flash(socket, :info, gettext("No data values to delete."))}

        {:ok, deleted_count} ->
          {:noreply,
           socket
           |> refresh_group_data()
           |> put_flash(
             :info,
             ngettext(
               "Deleted 1 data value.",
               "Deleted %{count} data values.",
               deleted_count,
               count: deleted_count
             )
           )}

        {:error, :not_group_creator} ->
          {:noreply,
           put_flash(socket, :error, gettext("Only the group creator can edit this group."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete data values."))}
      end
    end
  end

  def handle_event("delete_group", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to delete this group."))}
    else
      case Social.delete_group(current_profile, group) do
        {:ok, _deleted_group} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Group deleted."))
           |> push_navigate(to: delete_group_redirect_path(group.parent_id))}

        {:error, :cannot_delete_root_group} ->
          {:noreply, put_flash(socket, :error, gettext("The root group cannot be deleted."))}

        {:error, :not_a_group_member} ->
          {:noreply,
           put_flash(socket, :error, gettext("You must be a group member to delete this group."))}

        {:error, :group_has_children} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Delete this group's sub-groups before deleting the group.")
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete group."))}
      end
    end
  end

  def handle_event("set_edit_group_description_open", %{"open" => open}, socket) do
    {:noreply, assign(socket, :description_details_open, open == "true")}
  end

  def handle_event(
        "suggest_invite_profiles",
        %{"invite" => %{"identifier" => identifier}},
        socket
      ) do
    identifier = String.trim(identifier || "")

    {:noreply,
     socket
     |> assign(:invite_form, invite_form(identifier))
     |> assign(
       :invite_profile_suggestions,
       invite_profile_suggestions(
         socket.assigns.current_profile,
         socket.assigns.group,
         identifier
       )
     )}
  end

  def handle_event("select_invite_profile", %{"username" => username}, socket) do
    username = String.trim(username || "")

    {:noreply,
     socket
     |> assign(:invite_form, invite_form(username))
     |> assign(:invite_profile_suggestions, [])}
  end

  def handle_event("clear_invite_profile_suggestions", _params, socket) do
    {:noreply, assign(socket, :invite_profile_suggestions, [])}
  end

  def handle_event("invite", %{"invite" => %{"identifier" => identifier}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}
    else
      identifier = String.trim(identifier || "")

      socket =
        socket
        |> assign(:invite_form, invite_form(identifier))
        |> assign(
          :invite_profile_suggestions,
          invite_profile_suggestions(current_profile, group, identifier)
        )

      case invite_group_identifier(current_profile, group, identifier) do
        {:ok, message} ->
          {:noreply,
           socket
           |> assign(:invite_form, empty_invite_form())
           |> assign(:invite_profile_suggestions, [])
           |> update(:invite_form_version, &(&1 + 1))
           |> put_flash(:info, message)}

        {:error, :blank_identifier} ->
          {:noreply, put_flash(socket, :error, gettext("Username or email is required."))}

        {:error, :invalid_email} ->
          {:noreply, put_flash(socket, :error, gettext("Enter a valid email address."))}

        {:error, :profile_not_found} ->
          {:noreply, put_flash(socket, :error, gettext("No profile found with that username."))}

        {:error, :inviter_not_a_member} ->
          {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}

        {:error, :cannot_invite_self} ->
          {:noreply, put_flash(socket, :error, gettext("You cannot invite yourself."))}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("An invitation is already pending."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not send invitation."))}
      end
    end
  end

  def handle_event("invite_account", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/accounts/register")}
  end

  @impl true
  def handle_info({:group_updated, _group_id}, %{assigns: %{current_profile: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:group_updated, group_id}, socket) when socket.assigns.group.id == group_id do
    {:noreply, schedule_refresh(socket, :group)}
  end

  def handle_info({:group_updated, _group_id}, socket), do: {:noreply, socket}

  def handle_info({:group_description_updated, group_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, assign(socket, :group, Social.get_group!(group_id))}
  end

  def handle_info({:group_description_updated, _group_id}, socket), do: {:noreply, socket}

  def handle_info(:flush_refresh, socket) do
    {:noreply, flush_refresh(socket)}
  end

  def handle_info({:value_created, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_created(socket, value)}
  end

  def handle_info({:value_created, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:data_value_created, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, announce_new_data_value(socket, value)}
  end

  def handle_info({:data_value_created, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:value_updated, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_updated(socket, value)}
  end

  def handle_info({:value_updated, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:value_deleted, group_id, value_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_deleted(socket, value_id)}
  end

  def handle_info({:value_deleted, _group_id, _value_id}, socket), do: {:noreply, socket}

  def handle_info({:group_deleted, group_id, parent_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Group deleted."))
     |> push_navigate(to: delete_group_redirect_path(parent_id))}
  end

  def handle_info({:group_deleted, _group_id, _parent_id}, socket), do: {:noreply, socket}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    if topic == Social.group_presence_topic(socket.assigns.group) do
      {:noreply, refresh_group_presence(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:presence_updated, topic}, socket) do
    if topic == Social.group_presence_topic(socket.assigns.group) do
      {:noreply, refresh_group_presence(socket)}
    else
      {:noreply, socket}
    end
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

  def handle_info({:email, _email}, socket), do: {:noreply, socket}

  def handle_info(
        {:group_unread_counts_updated, profile_id, _group_id},
        %{assigns: %{current_profile: %{id: current_profile_id}}} = socket
      )
      when profile_id == current_profile_id do
    {:noreply, schedule_refresh(socket, :unread)}
  end

  def handle_info({:group_unread_counts_updated, _profile_id, _group_id}, socket),
    do: {:noreply, socket}

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        group = Social.get_group!(socket.assigns.group.id)
        is_member = Social.member_of_group?(current_profile, group)

        if can_view_group?(group, is_member) do
          {:noreply,
           socket
           |> assign(:is_member, is_member)
           |> load_group_data(group)
           |> sync_group_presence()}
        else
          {:noreply,
           socket
           |> put_flash(:error, gettext("You do not have access to that group."))
           |> push_navigate(to: ~p"/groups")}
        end
      end,
      fn socket ->
        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  defp load_group_data(socket, group, active_tab \\ nil) do
    active_tab =
      active_tab ||
        normalize_active_tab(
          Map.get(socket.assigns, :active_tab),
          group,
          socket.assigns.is_member,
          socket.assigns.current_profile
        )

    sub_groups_kind =
      socket.assigns
      |> Map.get(:sub_groups_kind, normalize_sub_groups_kind(nil, group))
      |> normalize_sub_groups_kind(group)

    socket
    |> assign(:group, group)
    |> assign(:active_tab, active_tab)
    |> assign(:sub_groups_kind, sub_groups_kind)
    |> load_member_summary(group)
    |> load_join_request_data(group, active_tab)
    |> maybe_load_children(group, active_tab)
    |> assign_child_pending_join_request_counts()
    |> maybe_load_members(group, active_tab)
    |> maybe_load_values(group, active_tab)
    |> maybe_mark_group_values_read(group, active_tab)
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
    |> assign_group_unread_counts()
    |> maybe_load_value_parent_options(group, active_tab)
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group, socket.assigns.active_tab)
  end

  # A value posted in a big group fans out `group_updated` / unread broadcasts
  # to every member; collecting them for a moment turns a burst into one reload.
  defp schedule_refresh(socket, kind) do
    already_scheduled? = MapSet.size(socket.assigns.pending_refresh) > 0
    socket = update(socket, :pending_refresh, &MapSet.put(&1, kind))

    case refresh_debounce_ms() do
      0 ->
        flush_refresh(socket)

      delay ->
        if not already_scheduled?, do: Process.send_after(self(), :flush_refresh, delay)
        socket
    end
  end

  defp refresh_debounce_ms, do: @refresh_debounce_ms

  defp flush_refresh(socket) do
    pending = socket.assigns.pending_refresh
    socket = assign(socket, :pending_refresh, MapSet.new())

    cond do
      MapSet.member?(pending, :group) -> reload_current_group(socket)
      MapSet.member?(pending, :unread) -> refresh_unread_counts(socket)
      true -> socket
    end
  end

  defp reload_current_group(socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(socket.assigns.group.id)
    is_member = Social.member_of_group?(current_profile, group)
    previous_newest_value_id = socket.assigns.newest_value_id

    if can_view_group?(group, is_member) do
      socket
      |> assign(:is_member, is_member)
      |> load_group_data(group)
      |> maybe_scroll_values_to_latest(previous_newest_value_id)
    else
      socket
      |> put_flash(:error, gettext("You do not have access to that group."))
      |> push_navigate(to: ~p"/groups")
    end
  end

  defp refresh_unread_counts(socket) do
    socket
    |> maybe_load_children(socket.assigns.group, socket.assigns.active_tab)
    |> assign_root_group_unread_count()
    |> assign_group_unread_counts()
    |> maybe_push_root_group_unread_count()
  end

  # Online dots are driven by the `#group-presence-style` rule set, so a
  # presence diff only changes that one element instead of streamed items.
  defp refresh_group_presence(socket) do
    assign(
      socket,
      :online_profile_ids,
      Social.list_online_profile_ids_for_group(socket.assigns.group)
    )
  end

  defp sync_group_presence(socket) do
    current_profile = socket.assigns.current_profile
    previous_profile_id = socket.assigns.presence_profile_id
    group = socket.assigns.group

    socket =
      if connected?(socket) do
        if is_integer(previous_profile_id) and
             (is_nil(current_profile) or previous_profile_id != current_profile.id) do
          Social.untrack_group_presence(self(), group, previous_profile_id)
        end

        if current_profile && current_profile.id != previous_profile_id do
          case Social.track_group_presence(self(), group, current_profile) do
            {:ok, _meta} -> :ok
            {:error, _reason} -> :ok
          end
        end

        assign(socket, :online_profile_ids, Social.list_online_profile_ids_for_group(group))
      else
        assign(socket, :online_profile_ids, MapSet.new())
      end

    assign(socket, :presence_profile_id, current_profile && current_profile.id)
  end

  defp maybe_scroll_values_to_latest(socket, previous_newest_value_id) do
    newest_value_id = socket.assigns.newest_value_id

    if needs_values?(socket.assigns.group, socket.assigns.active_tab) and
         is_integer(newest_value_id) and
         (is_nil(previous_newest_value_id) or newest_value_id > previous_newest_value_id) do
      push_event(socket, "scroll_values_to_latest", %{})
    else
      socket
    end
  end

  # Incremental value updates. These are idempotent so the acting LiveView and
  # the PubSub broadcast it also receives can both apply them safely.
  defp apply_value_created(socket, %Value{is_data: true}), do: socket

  defp apply_value_created(socket, %Value{} = value) do
    group = socket.assigns.group
    active_tab = socket.assigns.active_tab

    # Unread badges are refreshed by the `group_unread_counts_updated` broadcast
    # that Social sends to every member right after the value broadcast.
    if needs_values?(group, active_tab) and
         not MapSet.member?(socket.assigns.loaded_value_ids, value.id) do
      socket
      |> update(:loaded_value_ids, &MapSet.put(&1, value.id))
      |> assign(:newest_value_id, max(socket.assigns.newest_value_id || 0, value.id))
      |> assign(:oldest_value_id, socket.assigns.oldest_value_id || value.id)
      |> stream_insert(:values, value)
      |> maybe_mark_group_values_read(group, active_tab)
      |> push_event("scroll_values_to_latest", %{})
    else
      socket
    end
  end

  defp apply_value_updated(socket, %Value{} = value) do
    if MapSet.member?(socket.assigns.loaded_value_ids, value.id) do
      stream_insert(socket, :values, value)
    else
      socket
    end
  end

  defp apply_value_deleted(socket, value_id) do
    socket =
      case socket.assigns.editing_value do
        %Value{id: ^value_id} ->
          socket
          |> assign(:editing_value, nil)
          |> assign(:edit_value_form, nil)

        _ ->
          socket
      end

    if MapSet.member?(socket.assigns.loaded_value_ids, value_id) do
      remove_value(socket, value_id)
    else
      socket
    end
  end

  # Only the app frame listens for data values, so they are pushed only while
  # the group description is on screen.
  defp announce_new_data_value(socket, %Value{} = value) do
    if description_visible?(socket.assigns) do
      push_event(socket, "new_data_value", value_payload(value))
    else
      socket
    end
  end

  defp description_visible?(%{active_tab: active_tab, group: group, is_member: is_member}) do
    active_tab == "group_home" or
      (active_tab == "values" and group.parent_id != nil and not is_member)
  end

  @doc false
  def value_payload(%Value{} = value) do
    %{
      id: value.id,
      content: value.content,
      data: value.data,
      content_format: to_string(value.content_format),
      is_data: value.is_data,
      group_id: value.group_id,
      parent_id: value.parent_id,
      creator_id: value.creator_id,
      creator_username: value_creator_username(value)
    }
  end

  defp value_creator_username(%Value{creator: %{username: username}}), do: username
  defp value_creator_username(_), do: nil

  # Values are only held in the stream; events re-read the row and check it
  # belongs to a value this LiveView has rendered.
  defp loaded_value(socket, id) do
    with {value_id, ""} <- Integer.parse(to_string(id)),
         true <- MapSet.member?(socket.assigns.loaded_value_ids, value_id),
         %Value{} = value <- Social.get_value_for_display(value_id),
         true <- value.group_id == socket.assigns.group.id do
      value
    else
      _ -> nil
    end
  end

  defp clear_edit_value(socket) do
    editing_value = socket.assigns.editing_value

    socket
    |> assign(:editing_value, nil)
    |> assign(:edit_value_form, nil)
    |> restream_value(editing_value)
  end

  defp remove_value(socket, value_id) do
    socket
    |> update(:loaded_value_ids, &MapSet.delete(&1, value_id))
    |> stream_delete_by_dom_id(:values, "value-#{value_id}")
  end

  # Re-reads the row so a stale struct never overwrites newer content.
  defp restream_value(socket, nil), do: socket

  defp restream_value(socket, %Value{id: value_id}) do
    with true <- MapSet.member?(socket.assigns.loaded_value_ids, value_id),
         %Value{} = value <- Social.get_value_for_display(value_id) do
      stream_insert(socket, :values, value)
    else
      _ -> socket
    end
  end

  defp default_pagination(per_page) do
    %{per_page: per_page, loaded_count: 0, total_count: 0, has_more?: false}
  end

  defp empty_new_value_form do
    to_form(Value.changeset(%Value{}, %{}))
  end

  defp empty_new_group_form do
    to_form(
      Group.changeset(%Group{}, %{
        is_public: false,
        description_format: :markdown,
        home_page: :description
      })
    )
  end

  # The picture column is not loaded by regular queries; the edit form is the
  # only place that needs the raw value, so it is fetched just for that tab.
  defp edit_group_form(group, "edit_group"),
    do: to_form(Group.update_changeset(Social.load_picture(group), %{}))

  defp edit_group_form(group, _active_tab), do: to_form(Group.update_changeset(group, %{}))

  defp maybe_reload_edit_group_form(socket, "edit_group") do
    if socket.assigns.active_tab == "edit_group" do
      socket
    else
      assign(socket, :edit_group_form, edit_group_form(socket.assigns.group, "edit_group"))
    end
  end

  defp maybe_reload_edit_group_form(socket, _active_tab), do: socket

  defp empty_invite_form do
    invite_form()
  end

  defp invite_form(identifier \\ "") do
    to_form(%{"identifier" => identifier}, as: "invite")
  end

  defp invite_profile_suggestions(nil, _group, _identifier), do: []

  defp invite_profile_suggestions(_current_profile, _group, identifier)
       when identifier in [nil, ""] do
    []
  end

  defp invite_profile_suggestions(current_profile, group, identifier) do
    normalized_identifier = String.trim(identifier)

    cond do
      normalized_identifier == "" ->
        []

      String.contains?(normalized_identifier, "@") ->
        []

      true ->
        Social.list_invitable_profiles_for_group(current_profile, group, normalized_identifier,
          limit: 6
        )
    end
  end

  defp invite_group_identifier(_current_profile, _group, "") do
    {:error, :blank_identifier}
  end

  defp invite_group_identifier(current_profile, group, identifier) do
    cond do
      valid_email_identifier?(identifier) ->
        invite_group_by_email(current_profile, group, identifier)

      String.contains?(identifier, "@") ->
        {:error, :invalid_email}

      true ->
        invite_group_by_username(current_profile, group, identifier)
    end
  end

  defp invite_group_by_username(current_profile, group, username) do
    case Social.get_profile_by_username(username) do
      %{} = invitee_profile ->
        case Social.invite_profile_to_group(current_profile, group, invitee_profile) do
          {:ok, _invitation} -> {:ok, gettext("Invitation sent.")}
          error -> error
        end

      nil ->
        {:error, :profile_not_found}
    end
  end

  defp invite_group_by_email(current_profile, group, email) do
    case Accounts.get_account_by_email(email) do
      %Account{} = account ->
        invite_group_for_account(current_profile, group, account)

      nil ->
        with {:ok, account} <- Accounts.register_account(%{email: email}),
             {:ok, _email} <-
               Accounts.deliver_login_instructions(account, &url(~p"/accounts/log-in/#{&1}")),
             {:ok, %GroupAccountInvitation{}} <-
               Social.invite_account_to_group(current_profile, group, account) do
          {:ok, gettext("Account invitation email sent.")}
        else
          {:ok, %GroupInvitation{}} ->
            {:ok, gettext("Invitation sent.")}

          error ->
            error
        end
    end
  end

  defp invite_group_for_account(current_profile, group, account) do
    case Social.invite_account_to_group(current_profile, group, account) do
      {:ok, %GroupInvitation{}} ->
        {:ok, gettext("Invitation sent.")}

      {:ok, %GroupAccountInvitation{}} ->
        {:ok, gettext("Invitation will be sent when they create their first profile.")}

      error ->
        error
    end
  end

  defp valid_email_identifier?(identifier) do
    Accounts.change_account_email(%Account{}, %{"email" => identifier}, validate_unique: false).valid?
  end

  defp list_children(socket, opts) do
    Social.list_child_groups_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      Keyword.merge(opts,
        is_direct: child_group_direct_filter(socket.assigns.sub_groups_kind),
        search: normalize_children_search_query(socket.assigns.children_search_query)
      )
    )
  end

  defp count_children(socket) do
    Social.count_child_groups_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      is_direct: child_group_direct_filter(socket.assigns.sub_groups_kind),
      search: normalize_children_search_query(socket.assigns.children_search_query)
    )
  end

  # Reloads keep the window the viewer already scrolled to; "load more" only
  # fetches the next page and appends it to the stream.
  defp reload_limit(%{loaded_count: loaded_count, per_page: per_page}),
    do: max(loaded_count, per_page)

  defp loaded_pagination(pagination, loaded_count, total_count) do
    %{
      pagination
      | loaded_count: loaded_count,
        total_count: total_count,
        has_more?: loaded_count < total_count
    }
  end

  defp reload_children(socket) do
    socket
    |> maybe_load_children(socket.assigns.group, socket.assigns.active_tab)
    |> assign_child_pending_join_request_counts()
    |> assign_group_unread_counts()
  end

  defp load_more_children(socket) do
    pagination = socket.assigns.children_pagination

    if pagination.has_more? and needs_children?(socket.assigns.group, socket.assigns.active_tab) do
      loaded_ids = MapSet.new(socket.assigns.loaded_children, & &1.id)

      entries =
        socket
        |> list_children(limit: pagination.per_page, offset: pagination.loaded_count)
        |> Enum.reject(&MapSet.member?(loaded_ids, &1.id))

      loaded_children = socket.assigns.loaded_children ++ entries

      socket
      |> assign(:loaded_children, loaded_children)
      |> assign(
        :children_pagination,
        loaded_pagination(pagination, length(loaded_children), pagination.total_count)
      )
      |> merge_child_counts(entries)
      |> stream(:children, entries)
    else
      socket
    end
  end

  defp merge_child_counts(socket, children) do
    current_profile = socket.assigns.current_profile
    manageable_children = Enum.filter(children, &can_manage_join_requests?(current_profile, &1))

    socket
    |> update(
      :group_unread_counts,
      &Map.merge(&1, Social.list_group_unread_counts(current_profile, children))
    )
    |> update(
      :child_pending_join_request_counts,
      &Map.merge(&1, Social.list_pending_group_join_request_counts(manageable_children))
    )
  end

  defp load_more_members(socket) do
    pagination = socket.assigns.members_pagination

    if pagination.has_more? and needs_members?(socket.assigns.group, socket.assigns.active_tab) do
      entries =
        Social.list_group_members(socket.assigns.group,
          limit: pagination.per_page,
          offset: pagination.loaded_count
        )

      socket
      |> assign(
        :members_pagination,
        loaded_pagination(
          pagination,
          pagination.loaded_count + length(entries),
          pagination.total_count
        )
      )
      |> stream(:members, entries)
    else
      socket
    end
  end

  defp load_more_values(socket) do
    if socket.assigns.values_has_more? and
         needs_values?(socket.assigns.group, socket.assigns.active_tab) do
      {older_values, has_more?} =
        Social.list_group_values_page(socket.assigns.group,
          before_id: socket.assigns.oldest_value_id,
          limit: @values_page_size
        )

      socket
      |> update(:loaded_value_ids, fn ids -> Enum.into(older_values, ids, & &1.id) end)
      |> assign(:values_has_more?, has_more?)
      |> assign(:oldest_value_id, first_value_id(older_values) || socket.assigns.oldest_value_id)
      |> stream(:values, Enum.reverse(older_values), at: 0)
    else
      socket
    end
  end

  defp first_value_id([%{id: id} | _]), do: id
  defp first_value_id([]), do: nil

  defp last_value_id(values), do: values |> Enum.reverse() |> first_value_id()

  defp load_member_summary(socket, group) do
    if group.parent_id != nil do
      socket
      |> assign(:members_count, Social.count_group_members(group))
      |> assign(:first3_members, Social.list_first3_group_members(group))
    else
      socket
      |> assign(:members_count, 0)
      |> assign(:first3_members, [])
    end
  end

  defp load_join_request_data(socket, group, active_tab) do
    current_profile = socket.assigns.current_profile
    can_manage_join_requests = can_manage_join_requests?(current_profile, group)

    pending_join_request =
      if group.is_public and not socket.assigns.is_member do
        Social.get_pending_group_join_request(current_profile, group)
      else
        nil
      end

    pending_join_requests =
      if needs_members?(group, active_tab) and can_manage_join_requests do
        Social.list_pending_group_join_requests(group)
      else
        []
      end

    pending_join_requests_count =
      if can_manage_join_requests do
        Social.count_pending_group_join_requests(group)
      else
        0
      end

    socket
    |> assign(:pending_join_request, pending_join_request)
    |> assign(:pending_join_requests, pending_join_requests)
    |> assign(:pending_join_requests_count, pending_join_requests_count)
  end

  defp maybe_load_children(socket, group, active_tab) do
    if needs_children?(group, active_tab) do
      pagination = socket.assigns.children_pagination
      entries = list_children(socket, limit: reload_limit(pagination))

      socket
      |> assign(:loaded_children, entries)
      |> assign(
        :children_pagination,
        loaded_pagination(pagination, length(entries), count_children(socket))
      )
      |> stream(:children, entries, reset: true)
    else
      assign(socket, :loaded_children, [])
    end
  end

  defp maybe_load_members(socket, group, active_tab) do
    if needs_members?(group, active_tab) do
      pagination = socket.assigns.members_pagination
      entries = Social.list_group_members(group, limit: reload_limit(pagination))

      socket
      |> assign(
        :members_pagination,
        loaded_pagination(pagination, length(entries), Social.count_group_members(group))
      )
      |> stream(:members, entries, reset: true)
    else
      socket
    end
  end

  defp maybe_load_values(socket, group, active_tab) do
    if needs_values?(group, active_tab) do
      limit = max(MapSet.size(socket.assigns.loaded_value_ids), @values_page_size)
      {values, has_more?} = Social.list_group_values_page(group, limit: limit)

      socket
      |> assign(:loaded_value_ids, MapSet.new(values, & &1.id))
      |> assign(:values_has_more?, has_more?)
      |> assign(:oldest_value_id, first_value_id(values))
      |> assign(:newest_value_id, last_value_id(values))
      |> stream(:values, values, reset: true)
    else
      socket
    end
  end

  defp maybe_load_value_parent_options(socket, _group, active_tab) do
    if needs_value_parent_options?(socket, active_tab) do
      socket
      # skip loading parent options
      # |> assign(:value_parent_options, value_parent_options(Social.list_group_values(group)))
    else
      socket
    end
  end

  defp maybe_mark_group_values_read(socket, group, active_tab) do
    if needs_values?(group, active_tab) and socket.assigns.current_profile do
      _ = Social.mark_group_values_read(socket.assigns.current_profile, group)
      socket
    else
      socket
    end
  end

  defp assign_group_unread_counts(%{assigns: %{current_profile: nil}} = socket) do
    socket
    |> assign(:group_unread_counts, %{})
    |> assign(:current_group_unread_count, 0)
    |> assign(:sub_groups_unread_count, 0)
    |> assign(:direct_sub_groups_unread_count, 0)
    |> assign(:other_sub_groups_unread_count, 0)
  end

  defp assign_group_unread_counts(%{assigns: %{group: group}} = socket) do
    current_profile = socket.assigns.current_profile
    groups = [group | Map.get(socket.assigns, :loaded_children, [])]

    group_unread_counts = Social.list_group_unread_counts(current_profile, groups)
    current_group_unread_count = Social.count_group_direct_unread_values(current_profile, group)

    sub_groups_unread_count =
      max(Map.get(group_unread_counts, group.id, 0) - current_group_unread_count, 0)

    %{direct: direct_sub_groups_unread_count, other: other_sub_groups_unread_count} =
      Social.child_group_unread_summary(current_profile, group)

    socket
    |> assign(:group_unread_counts, group_unread_counts)
    |> assign(:current_group_unread_count, current_group_unread_count)
    |> assign(:sub_groups_unread_count, sub_groups_unread_count)
    |> assign(:direct_sub_groups_unread_count, direct_sub_groups_unread_count)
    |> assign(:other_sub_groups_unread_count, other_sub_groups_unread_count)
  end

  defp assign_child_pending_join_request_counts(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :child_pending_join_request_counts, %{})
  end

  defp assign_child_pending_join_request_counts(socket) do
    current_profile = socket.assigns.current_profile

    manageable_children =
      socket.assigns
      |> Map.get(:loaded_children, [])
      |> Enum.filter(&can_manage_join_requests?(current_profile, &1))

    assign(
      socket,
      :child_pending_join_request_counts,
      Social.list_pending_group_join_request_counts(manageable_children)
    )
  end

  defp assign_root_group_unread_count(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :root_group_unread_count, 0)
  end

  defp assign_root_group_unread_count(socket) do
    assign(
      socket,
      :root_group_unread_count,
      Social.count_root_group_unread_values(socket.assigns.current_profile)
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

  defp needs_children?(group, active_tab) do
    active_tab == "sub_groups" or (group.parent_id == nil and active_tab == "values")
  end

  defp needs_members?(group, active_tab) do
    group.parent_id != nil and active_tab == "members"
  end

  defp needs_values?(group, active_tab) do
    group.parent_id != nil and active_tab == "values"
  end

  defp needs_value_parent_options?(socket, active_tab) do
    socket.assigns.is_member and active_tab == "create_group"
  end

  defp home_page_options do
    [
      {gettext("Description"), :description},
      {gettext("Chat"), :chat},
      {gettext("Sub-groups"), :subgroups}
    ]
  end

  defp normalize_sub_groups_kind(_kind, %Group{is_root: false}), do: "other"
  defp normalize_sub_groups_kind("direct", %Group{is_root: true}), do: "direct"
  defp normalize_sub_groups_kind("other", %Group{is_root: true}), do: "other"
  defp normalize_sub_groups_kind(_, %Group{is_root: true}), do: "other"

  defp normalize_children_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_children_search_query(_), do: ""

  defp child_group_direct_filter("direct"), do: true
  defp child_group_direct_filter("other"), do: false
  defp child_group_direct_filter(_), do: false

  defp default_active_tab(%Group{is_root: true}), do: "sub_groups"
  defp default_active_tab(%Group{is_direct: true}), do: "values"
  defp default_active_tab(%Group{home_page: :chat}), do: "values"
  defp default_active_tab(%Group{home_page: :subgroups}), do: "sub_groups"
  defp default_active_tab(%Group{}), do: "group_home"

  defp can_manage_join_requests?(%{id: profile_id}, %Group{creator_id: profile_id}), do: true
  defp can_manage_join_requests?(_, _group), do: false

  defp members_tab_label(count, %Group{creator_id: creator_id}, %{id: creator_id})
       when count > 0 do
    gettext("Members (%{count} requests)", count: count)
  end

  defp members_tab_label(_count, _group, _profile), do: gettext("Members")

  defp group_tab_path(%Group{} = group, tab, opts) do
    base_path = ~p"/groups/#{group.id}/#{tab}"

    query_params =
      %{}
      |> maybe_put_sub_groups_kind_query(group, tab, opts[:sub_groups_kind])

    append_query_params(base_path, query_params)
  end

  defp maybe_put_sub_groups_kind_query(query_params, group, tab, sub_groups_kind) do
    if group.is_root and needs_children?(group, tab) do
      Map.put(query_params, "sub_groups_kind", normalize_sub_groups_kind(sub_groups_kind, group))
    else
      query_params
    end
  end

  defp append_query_params(path, query_params) when map_size(query_params) == 0, do: path

  defp append_query_params(path, query_params) do
    path <> "?" <> URI.encode_query(query_params)
  end

  defp delete_group_redirect_path(nil), do: ~p"/groups"
  defp delete_group_redirect_path(parent_id), do: ~p"/groups/#{parent_id}"

  defp normalize_active_tab(tab, _group, _is_member, _current_profile)
       when tab in ["values", "sub_groups", "members", "group_home"],
       do: tab

  defp normalize_active_tab(tab, _group, true, _current_profile)
       when tab in ["create_group", "invite_profile"],
       do: tab

  defp normalize_active_tab("edit_group", group, _is_member, current_profile)
       when not is_nil(current_profile) do
    if can_edit_group?(current_profile, group), do: "edit_group", else: default_active_tab(group)
  end

  defp normalize_active_tab(_, group, _is_member, _current_profile), do: default_active_tab(group)

  defp can_edit_group?(%{id: profile_id}, %Group{creator_id: profile_id}), do: true
  defp can_edit_group?(_, _group), do: false

  defp unread_badge_label(count) when count > 999, do: "999+"
  defp unread_badge_label(count), do: Integer.to_string(count)

  defp normalize_select_nil(attrs, key) when is_binary(key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
    end
  end

  defp handle_join_request_action(socket, id, action, success_message) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Integer.parse(id) do
      {request_id, ""} ->
        case action.(current_profile, group, request_id) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> put_flash(:info, success_message)
             |> refresh_group_data()}

          {:error, :not_group_creator} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Only the group creator can manage access requests.")
             )}

          {:error, :request_not_found} ->
            {:noreply, put_flash(socket, :error, gettext("Access request not found."))}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
  end

  defp can_view_group?(group, is_member) do
    group.is_public or is_member
  end
end
