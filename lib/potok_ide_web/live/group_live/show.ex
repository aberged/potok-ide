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
  alias PotokIdeWeb.GroupLive.Show.Components

  @children_page_size 20
  @members_page_size 20
  @values_page_size 20

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sticky top-16 max-w-dvw lg:max-w-6xl justify-center z-50 rounded-4xl border border-base-300/70 bg-base-30/70 px-4 py-3 shadow-lg shadow-primary/5 backdrop-blur">
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
            <div class="flex items-center gap-3">
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
            :if={!@group.is_root and @is_member}
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

          <Layouts.drop_down_menu icon="hero-ellipsis-horizontal">
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
                :if={@group.is_root or @is_member}
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

      <div class="min-h-0 flex-1 overflow-clip">
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
          />
          <MembersTab.panel
            :if={@active_tab == "members"}
            members={@streams.members}
            pagination={@members_pagination}
            current_profile={@current_profile}
            online_profile_ids={@online_profile_ids}
            group={@group}
            join_requests={@pending_join_requests}
            pending_join_requests_count={@pending_join_requests_count}
          />
          <ValuesTab.panel
            :if={@active_tab == "values" and @group.parent_id != nil and @is_member}
            values={@streams.values}
            pagination={@values_pagination}
            current_profile={@current_profile}
            online_profile_ids={@online_profile_ids}
            expanded_value_ids={@expanded_value_ids}
            editing_value_id={@editing_value_id}
            editing_value={find_value(@loaded_values, @editing_value_id)}
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
       |> assign(:values_pagination, default_pagination(@values_page_size))
       |> assign(:loaded_children, [])
       |> assign(:loaded_members, [])
       |> assign(:loaded_values, [])
       |> assign(:child_pending_join_request_counts, %{})
       |> assign(:group_unread_counts, %{})
       |> assign(:current_group_unread_count, 0)
       |> assign(:sub_groups_unread_count, 0)
       |> assign(:members_count, 0)
       |> assign(:first3_members, [])
       |> assign(:online_profile_ids, MapSet.new())
       |> assign(:presence_profile_id, nil)
       |> assign(:is_member, is_member)
       |> assign(:group, group)
       |> assign(:active_tab, active_tab)
       |> assign(:editing_value_id, nil)
       |> assign(:edit_value_form, nil)
       |> assign(:format_options, [{gettext("Markdown"), :markdown}, {gettext("HTML"), :html}])
       |> assign(:home_page_options, home_page_options())
       |> assign(:value_parent_options, [])
       |> assign(:new_value_form, empty_new_value_form())
       |> assign(:new_group_form, empty_new_group_form())
       |> assign(:edit_group_form, edit_group_form(group))
       |> assign(:description_details_open, true)
       |> assign(:invite_form, empty_invite_form())
       |> assign(:invite_form_version, 0)
       |> assign(:pending_join_request, nil)
       |> assign(:pending_join_requests, [])
       |> assign(:pending_join_requests_count, 0)
       |> assign(:latest_data_value_id, nil)
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

    if active_tab == socket.assigns.active_tab do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:active_tab, active_tab)
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
      case Social.create_value(current_profile, group, normalize_select_nil(attrs, "parent_id")) do
        {:ok, _value} ->
          socket =
            socket
            |> assign(:active_tab, "values")
            |> assign(:new_value_form, empty_new_value_form())
            # |> put_flash(:info, gettext("Value posted."))
            |> refresh_group_data()
            |> push_event("scroll_values_to_latest", %{})

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create value."))}
      end
    end
  end

  def handle_event("create_data_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a group member to post values."))}
    else
      case Social.create_value(current_profile, group, normalize_select_nil(attrs, "parent_id")) do
        {:ok, value} ->
          socket =
            socket
            |> assign(:active_tab, socket.assigns.active_tab || "values")
            |> assign(:new_value_form, empty_new_value_form())
            # |> put_flash(:info, gettext("Value posted."))
            |> refresh_group_data()
            |> push_event("new_data_value", %{content: value.content})

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create value."))}
      end
    end
  end

  def handle_event("update_group_description", params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not can_edit_group?(current_profile, group) do
      {:reply, %{ok: false, error: gettext("Only the group creator can edit this group.")},
       put_flash(socket, :error, gettext("Only the group creator can edit this group."))}
    else
      attrs = %{
        "description" => Map.get(params, "description", group.description || ""),
        "description_format" => Map.get(params, "description_format", group.description_format)
      }

      case Social.update_group(current_profile, group, attrs) do
        {:ok, updated_group} ->
          socket =
            socket
            |> assign(:group, updated_group)
            |> assign(:edit_group_form, edit_group_form(updated_group))
            |> refresh_group_data()

          {:reply,
           %{
             ok: true,
             group: %{
               id: updated_group.id,
               description: updated_group.description,
               description_format: updated_group.description_format
             }
           }, socket}

        {:error, :not_group_creator} ->
          {:reply, %{ok: false, error: gettext("Only the group creator can edit this group.")},
           put_flash(socket, :error, gettext("Only the group creator can edit this group."))}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:reply, %{ok: false, error: gettext("Could not update group description.")},
           assign(socket, :edit_group_form, to_form(Map.put(changeset, :action, :validate)))}

        {:error, _reason} ->
          {:reply, %{ok: false, error: gettext("Could not update group description.")},
           put_flash(socket, :error, gettext("Could not update group description."))}
      end
    end
  end

  def handle_event("list_group_data_values", _params, socket) do
    if not socket.assigns.is_member do
      {:reply,
       %{ok: false, error: gettext("You must be a group member to access group data values.")},
       put_flash(
         socket,
         :error,
         gettext("You must be a group member to access group data values.")
       )}
    else
      values =
        socket.assigns.group
        |> Social.list_group_data_values()
        |> Enum.map(&value_payload/1)

      {:reply, %{ok: true, values: values}, socket}
    end
  end

  def handle_event("start_edit_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile
    previous_editing_value_id = socket.assigns.editing_value_id

    case find_value(socket.assigns.loaded_values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value when value.creator_id != current_profile.id ->
        {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

      value ->
        {:noreply,
         socket
         |> assign(:editing_value_id, value.id)
         |> assign(:edit_value_form, to_form(Value.changeset(value, %{})))
         |> restream_values([previous_editing_value_id, value.id])}
    end
  end

  def handle_event("validate_edit_value", %{"value" => attrs}, socket) do
    case current_editing_value(socket) do
      nil ->
        {:noreply, socket}

      value ->
        changeset =
          value
          |> Value.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:edit_value_form, to_form(changeset))
         |> restream_values([value.id])}
    end
  end

  def handle_event("save_edit_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile

    case current_editing_value(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.update_value(current_profile, value, attrs) do
          {:ok, _updated_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value updated."))
             |> refresh_group_data()
             |> clear_edit_value()}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:edit_value_form, to_form(Map.put(changeset, :action, :validate)))
             |> restream_values([value.id])}

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

    case find_value(socket.assigns.loaded_values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.delete_value(current_profile, value) do
          {:ok, _deleted_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value deleted."))
             |> remove_value(value)}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only delete your own values."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete value."))}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => "group_home"}, socket) do
    {:noreply,
     redirect(
       socket,
       to:
         group_tab_path(
           socket.assigns.group.id,
           normalize_active_tab(
             "group_home",
             socket.assigns.group,
             socket.assigns.is_member,
             socket.assigns.current_profile
           )
         )
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         group_tab_path(
           socket.assigns.group.id,
           normalize_active_tab(
             tab,
             socket.assigns.group,
             socket.assigns.is_member,
             socket.assigns.current_profile
           )
         )
     )}
  end

  def handle_event("load_more_children", _params, socket) do
    {:noreply,
     socket
     |> maybe_increment_pagination(:children_pagination)
     |> refresh_group_data()}
  end

  def handle_event("load_more_members", _params, socket) do
    {:noreply,
     socket
     |> maybe_increment_pagination(:members_pagination)
     |> refresh_group_data()}
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
    {:noreply,
     socket
     |> maybe_increment_pagination(:values_pagination)
     |> refresh_group_data()}
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
           |> assign(:edit_group_form, edit_group_form(updated_group))
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

  def handle_event("invite", %{"invite" => %{"identifier" => identifier}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}
    else
      identifier = String.trim(identifier || "")

      case invite_group_identifier(current_profile, group, identifier) do
        {:ok, message} ->
          {:noreply,
           socket
           |> assign(:invite_form, empty_invite_form())
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

  def handle_event("toggle_value_expansion", %{"id" => id}, socket) do
    value_id = String.to_integer(id)

    expanded_value_ids =
      if MapSet.member?(socket.assigns.expanded_value_ids, value_id) do
        MapSet.delete(socket.assigns.expanded_value_ids, value_id)
      else
        MapSet.put(socket.assigns.expanded_value_ids, value_id)
      end

    {:noreply,
     socket
     |> assign(:expanded_value_ids, expanded_value_ids)
     |> restream_values([value_id])}
  end

  def handle_event("invite_account", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/accounts/register")}
  end

  @impl true
  def handle_info({:group_updated, _group_id}, %{assigns: %{current_profile: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:group_updated, group_id}, socket) when socket.assigns.group.id == group_id do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(group_id)
    is_member = Social.member_of_group?(current_profile, group)
    previous_loaded_values = socket.assigns.loaded_values
    previous_values_pagination = socket.assigns.values_pagination
    previous_latest_data_value_id = socket.assigns.latest_data_value_id

    if can_view_group?(group, is_member) do
      socket =
        socket
        |> assign(:is_member, is_member)
        |> load_group_data(group)
        |> maybe_scroll_values_to_latest(previous_loaded_values, previous_values_pagination)
        |> maybe_new_data_value(previous_latest_data_value_id, group)

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  def handle_info({:group_updated, _group_id}, socket), do: {:noreply, socket}

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
    {:noreply,
     socket
     |> maybe_load_children(socket.assigns.group, socket.assigns.active_tab)
     |> assign(
       :root_group_unread_count,
       Social.count_group_unread_values(socket.assigns.current_profile, Social.get_root_group!())
     )
     |> assign_group_unread_counts()
     |> maybe_push_root_group_unread_count()}
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

    socket
    |> assign(:group, group)
    |> assign(:active_tab, active_tab)
    |> load_member_summary(group)
    |> load_join_request_data(group, active_tab)
    |> maybe_load_children(group, active_tab)
    |> assign_child_pending_join_request_counts()
    |> maybe_load_members(group, active_tab)
    |> maybe_load_values(group, active_tab)
    |> maybe_load_latest_data_value_id(group, active_tab)
    |> maybe_mark_group_values_read(group, active_tab)
    |> assign_root_group_unread_count()
    |> maybe_push_root_group_unread_count()
    |> assign_group_unread_counts()
    |> maybe_load_value_parent_options(group, active_tab)
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group, socket.assigns.active_tab)
  end

  defp refresh_group_presence(socket) do
    socket
    |> assign(:online_profile_ids, Social.list_online_profile_ids_for_group(socket.assigns.group))
    |> restream_members()
    |> restream_loaded_values()
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

  defp maybe_scroll_values_to_latest(socket, previous_loaded_values, previous_values_pagination) do
    if newer_value_arrived?(socket, previous_loaded_values, previous_values_pagination) do
      push_event(socket, "scroll_values_to_latest", %{})
    else
      socket
    end
  end

  defp maybe_new_data_value(socket, previous_latest_data_value_id, group) do
    if previous_latest_data_value_id != socket.assigns.latest_data_value_id do
      case Social.get_latest_data_value_for_group(group) do
        %Value{} = latest_data_value ->
          push_event(socket, "new_data_value", %{content: latest_data_value.content})

        nil ->
          socket
      end
    else
      socket
    end
  end

  defp value_payload(%Value{} = value, creator_username \\ nil) do
    %{
      id: value.id,
      content: value.content,
      content_format: to_string(value.content_format),
      is_data: value.is_data,
      group_id: value.group_id,
      parent_id: value.parent_id,
      creator_id: value.creator_id,
      creator_username: creator_username || value_creator_username(value)
    }
  end

  defp value_creator_username(%Value{creator: %{username: username}}), do: username
  defp value_creator_username(_), do: nil

  defp current_editing_value(socket) do
    find_value(socket.assigns.loaded_values, socket.assigns.editing_value_id)
  end

  defp find_value(_values, nil), do: nil

  defp find_value(values, id) when is_integer(id) do
    Enum.find(values, &(&1.id == id))
  end

  defp find_value(values, id) when is_binary(id) do
    Enum.find(values, &(Integer.to_string(&1.id) == id))
  end

  defp clear_edit_value(socket) do
    editing_value_id = socket.assigns.editing_value_id

    socket
    |> assign(:editing_value_id, nil)
    |> assign(:edit_value_form, nil)
    |> restream_values([editing_value_id])
  end

  defp remove_value(socket, value) do
    loaded_values = Enum.reject(socket.assigns.loaded_values, &(&1.id == value.id))

    expanded_value_ids = MapSet.delete(socket.assigns.expanded_value_ids, value.id)

    values_pagination =
      socket.assigns.values_pagination
      |> Map.update!(:loaded_count, &max(&1 - 1, 0))
      |> Map.update!(:total_count, &max(&1 - 1, 0))
      |> then(fn pagination ->
        Map.put(pagination, :has_more?, pagination.loaded_count < pagination.total_count)
      end)

    socket
    |> assign(:loaded_values, loaded_values)
    |> assign(:expanded_value_ids, expanded_value_ids)
    |> assign(:values_pagination, values_pagination)
    |> stream_delete(:values, value)
  end

  defp restream_members(socket) do
    Enum.reduce(socket.assigns.loaded_members, socket, fn member, acc ->
      stream_insert(acc, :members, member)
    end)
  end

  defp restream_loaded_values(socket) do
    Enum.reduce(socket.assigns.loaded_values, socket, fn value, acc ->
      stream_insert(acc, :values, value)
    end)
  end

  defp restream_values(socket, value_ids) do
    value_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(socket, fn value_id, acc ->
      case find_value(acc.assigns.loaded_values, value_id) do
        nil -> acc
        value -> stream_insert(acc, :values, value)
      end
    end)
  end

  defp default_pagination(per_page) do
    %{page: 1, per_page: per_page, loaded_count: 0, total_count: 0, has_more?: false}
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

  defp edit_group_form(group) do
    to_form(Group.update_changeset(group, %{}))
  end

  defp empty_invite_form do
    to_form(%{"identifier" => ""}, as: "invite")
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

  defp maybe_increment_pagination(socket, key) do
    if socket.assigns[key].has_more? do
      update(socket, key, &Map.update!(&1, :page, fn page -> page + 1 end))
    else
      socket
    end
  end

  defp child_groups_page(group, current_profile, pagination) do
    total_count = Social.count_child_groups_for_profile(group, current_profile)
    limit = pagination_limit(pagination)
    entries = Social.list_child_groups_for_profile(group, current_profile, limit: limit)

    pagination_result(pagination, entries, total_count)
  end

  defp members_page(group, pagination) do
    total_count = Social.count_group_members(group)
    limit = pagination_limit(pagination)
    entries = Social.list_group_members(group, limit: limit)

    pagination_result(pagination, entries, total_count)
  end

  defp values_page(group, pagination) do
    total_count = Social.count_group_values(group)
    limit = pagination_limit(pagination)
    offset = max(total_count - limit, 0)

    entries =
      Social.list_group_values(group,
        offset: offset,
        limit: limit
      )

    pagination_result(pagination, entries, total_count)
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
      current_profile = socket.assigns.current_profile

      children_page =
        child_groups_page(group, current_profile, socket.assigns.children_pagination)

      socket
      |> assign(:loaded_children, children_page.entries)
      |> assign(:children_pagination, pagination_metadata(children_page))
      |> stream(:children, children_page.entries, reset: true)
    else
      assign(socket, :loaded_children, [])
    end
  end

  defp maybe_load_members(socket, group, active_tab) do
    if needs_members?(group, active_tab) do
      members_page = members_page(group, socket.assigns.members_pagination)

      socket
      |> assign(:loaded_members, members_page.entries)
      |> assign(:members_pagination, pagination_metadata(members_page))
      |> stream(:members, members_page.entries, reset: true)
    else
      socket
    end
  end

  defp maybe_load_values(socket, group, active_tab) do
    if needs_values?(group, active_tab) do
      values_page = values_page(group, socket.assigns.values_pagination)
      values = values_page.entries
      value_ids = MapSet.new(Enum.map(values, & &1.id))

      expanded_value_ids =
        socket.assigns
        |> Map.get(:expanded_value_ids, MapSet.new())
        |> MapSet.intersection(value_ids)

      socket
      |> assign(:loaded_values, values)
      |> assign(:values_pagination, pagination_metadata(values_page))
      |> assign(:expanded_value_ids, expanded_value_ids)
      |> stream(:values, values, reset: true)
    else
      socket
    end
  end

  defp maybe_load_latest_data_value_id(socket, group, active_tab) do
    if needs_latest_data_value_id?(group, active_tab) do
      assign(socket, :latest_data_value_id, Social.get_latest_data_value_id_for_group(group))
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
  end

  defp assign_group_unread_counts(%{assigns: %{group: group}} = socket) do
    groups = [group | Map.get(socket.assigns, :loaded_children, [])]

    group_unread_counts = Social.list_group_unread_counts(socket.assigns.current_profile, groups)

    current_group_unread_count =
      Social.count_group_direct_unread_values(socket.assigns.current_profile, group)

    sub_groups_unread_count =
      max(Map.get(group_unread_counts, group.id, 0) - current_group_unread_count, 0)

    socket
    |> assign(:group_unread_counts, group_unread_counts)
    |> assign(:current_group_unread_count, current_group_unread_count)
    |> assign(:sub_groups_unread_count, sub_groups_unread_count)
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

  defp needs_children?(group, active_tab) do
    active_tab == "sub_groups" or (group.parent_id == nil and active_tab == "values")
  end

  defp needs_members?(group, active_tab) do
    group.parent_id != nil and active_tab == "members"
  end

  defp needs_values?(group, active_tab) do
    group.parent_id != nil and active_tab == "values"
  end

  defp needs_latest_data_value_id?(group, active_tab) do
    group.parent_id != nil and active_tab == "group_home"
  end

  defp newer_value_arrived?(socket, previous_loaded_values, previous_values_pagination) do
    needs_values?(socket.assigns.group, socket.assigns.active_tab) and
      latest_loaded_value_id(socket.assigns.loaded_values) !=
        latest_loaded_value_id(previous_loaded_values) and
      socket.assigns.values_pagination.total_count > previous_values_pagination.total_count
  end

  defp latest_loaded_value_id(values) when is_list(values) do
    values
    |> List.last()
    |> case do
      %{id: id} -> id
      _ -> nil
    end
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

  defp group_tab_path(group_id, tab), do: ~p"/groups/#{group_id}/#{tab}"

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
