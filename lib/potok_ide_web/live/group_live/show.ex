defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.{Group, Value}

  alias PotokIdeWeb.GroupLive.Show.{
    Components,
    CreateGroupTab,
    InviteProfileTab,
    MembersTab,
    SubGroupsTab,
    ValuesTab
  }

  alias PotokIdeWeb.ProfileAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sticky top-[4rem] max-w-dvw z-10 rounded-[2rem] border border-base-300/70 bg-base-100/90 px-4 py-3 shadow-lg shadow-primary/5 backdrop-blur">
        <div class="flex items-center gap-3">
          <div :if={!@group.is_root and @group.parent_id} class="pt-1">
            <.link navigate={~p"/groups/#{@group.parent_id}"} class="link text-xl no-underline">
              {"❮"}
            </.link>
          </div>

          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-3">
              <Components.group_identity
                group={@group}
                avatar_size="size-10"
                text_class="text-md"
              />
            </div>
          </div>

          <button
            id="group-subgroups-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="sub_groups"
            aria-label={gettext("Open sub-groups tab")}
            class="cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-folder-open"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
          </button>
          <button
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
            :if={@group.parent_id != nil}
            id="group-members-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="members"
            aria-label={gettext("Open members tab")}
            class="avatar-group -space-x-6 cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <div :for={m <- @first3_members} class="avatar">
              <div class="bg-white w-8"><img src={m.profile_picture_url} alt={m.username} /></div>
            </div>

            <div :if={@members_count > 3} class="avatar avatar-placeholder">
              <div class="bg-neutral text-neutral-content w-8">
                <span>+{@members_count - length(@first3_members)}</span>
              </div>
            </div>
          </button>
          <Layouts.drop_down_menu icon="hero-ellipsis-horizontal">
            <div class="flex min-w-[14rem] flex-col gap-2">
              <Components.group_tab_button
                :if={@group.parent_id != nil}
                id="group-tab-values"
                tab="values"
                active_tab={@active_tab}
                label={gettext("Values")}
              />
              <Components.group_tab_button
                id="group-tab-sub-groups"
                tab="sub_groups"
                active_tab={@active_tab}
                label={gettext("Sub-groups")}
              />
              <Components.group_tab_button
                :if={@group.parent_id != nil}
                id="group-tab-members"
                tab="members"
                active_tab={@active_tab}
                label={gettext("Members")}
              />
              <Components.group_tab_button
                :if={@is_member}
                id="group-tab-create-sub-group"
                tab="create_group"
                active_tab={@active_tab}
                label={gettext("Create sub-group")}
              />
              <Components.group_tab_button
                :if={@is_member}
                id="group-tab-invite-profile"
                tab="invite_profile"
                active_tab={@active_tab}
                label={gettext("Invite profile")}
              />
            </div>
          </Layouts.drop_down_menu>
        </div>
      </div>

      <div class="min-h-0 flex-1 overflow-clip">
        <div class="flex min-h-0 flex-1 flex-col gap-2">
          <div :if={!@is_member} class="alert mt-8">
            <.icon name="hero-lock-closed" class="size-5 shrink-0" />
            <div>
              {gettext(
                "You can view this group, but you must be a member to post values, invite members, or create sub-groups."
              )}
            </div>
          </div>

          <SubGroupsTab.panel
            :if={@active_tab == "sub_groups" or (@group.parent_id == nil and @active_tab == "values")}
            children={@children}
          />
          <MembersTab.panel
            :if={@active_tab == "members"}
            members={@members}
          />
          <ValuesTab.panel
            :if={@active_tab == "values" and @group.parent_id != nil}
            values={@values}
            current_profile={@current_profile}
            expanded_value_ids={@expanded_value_ids}
            editing_value_id={@editing_value_id}
            edit_value_form={@edit_value_form}
            new_value_form={@new_value_form}
            is_member={@is_member}
          />
          <CreateGroupTab.panel
            :if={@is_member and @active_tab == "create_group"}
            new_group_form={@new_group_form}
            format_options={@format_options}
            value_parent_options={@value_parent_options}
          />
          <InviteProfileTab.panel
            :if={@is_member and @active_tab == "invite_profile"}
            invite_form={@invite_form}
            invite_form_version={@invite_form_version}
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
    active_tab = normalize_active_tab(Map.get(params, "tab"), is_member)

    if can_view_group?(group, is_member) do
      if connected?(socket) do
        Social.subscribe_group(group)
      end

      {:ok,
       socket
       |> assign(:is_member, is_member)
       |> assign(:active_tab, active_tab)
       |> assign(:editing_value_id, nil)
       |> assign(:edit_value_form, nil)
       |> load_group_data(group)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(
       socket,
       :active_tab,
       normalize_active_tab(Map.get(params, "tab"), socket.assigns.is_member)
     )}
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

  def handle_event("start_edit_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile

    case find_value(socket.assigns.values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value when value.creator_id != current_profile.id ->
        {:noreply, put_flash(socket, :error, gettext("You can only edit your own values."))}

      value ->
        {:noreply,
         socket
         |> assign(:editing_value_id, value.id)
         |> assign(:edit_value_form, to_form(Value.changeset(value, %{})))}
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

        {:noreply, assign(socket, :edit_value_form, to_form(changeset))}
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

    case find_value(socket.assigns.values, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Value not found."))}

      value ->
        case Social.delete_value(current_profile, value) do
          {:ok, _deleted_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Value deleted."))
             |> refresh_group_data()}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only delete your own values."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete value."))}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         group_tab_path(
           socket.assigns.group.id,
           normalize_active_tab(tab, socket.assigns.is_member)
         )
     )}
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

  def handle_event("invite", %{"invite" => %{"username" => username}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}
    else
      username = String.trim(username || "")

      with false <- username == "",
           %{} = invitee <- Social.get_profile_by_username(username),
           {:ok, _inv} <- Social.invite_profile_to_group(current_profile, group, invitee) do
        {:noreply,
          socket
          |> assign(:invite_form, to_form(%{"username" => ""}, as: "invite"))
          |> update(:invite_form_version, &(&1 + 1))
          |> put_flash(:info, gettext("Invitation sent."))}
      else
        true ->
          {:noreply, put_flash(socket, :error, gettext("Username is required."))}

        nil ->
          {:noreply, put_flash(socket, :error, gettext("No profile found with that username."))}

        {:error, :inviter_not_a_member} ->
          {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}

        {:error, :cannot_invite_self} ->
          {:noreply, put_flash(socket, :error, gettext("You cannot invite yourself."))}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("An invitation is already pending."))}

        {:error, _} ->
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

    {:noreply, assign(socket, :expanded_value_ids, expanded_value_ids)}
  end

  @impl true
  def handle_info({:group_updated, _group_id}, %{assigns: %{current_profile: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:group_updated, group_id}, socket) when socket.assigns.group.id == group_id do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(group_id)
    is_member = Social.member_of_group?(current_profile, group)

    if can_view_group?(group, is_member) do
      {:noreply,
       socket
       |> assign(:is_member, is_member)
       |> load_group_data(group)}
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
    end
  end

  def handle_info({:group_updated, _group_id}, socket), do: {:noreply, socket}

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
           |> load_group_data(group)}
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

  defp load_group_data(socket, group) do
    values = Social.list_group_values(group)
    value_ids = MapSet.new(Enum.map(values, & &1.id))

    expanded_value_ids =
      socket.assigns
      |> Map.get(:expanded_value_ids, MapSet.new())
      |> MapSet.intersection(value_ids)

    active_tab =
      normalize_active_tab(Map.get(socket.assigns, :active_tab), socket.assigns.is_member)

    socket
    |> assign(:group, group)
    |> assign(
      :children,
      Social.list_child_groups_for_profile(group, socket.assigns.current_profile)
    )
    |> assign(:members_count, Social.count_group_members(group))
    |> assign(:first3_members, Social.list_first3_group_members(group))
    |> assign(:members, Social.list_group_members(group))
    |> assign(:values, values)
    |> assign(:active_tab, active_tab)
    |> assign(:expanded_value_ids, expanded_value_ids)
    |> assign(:format_options, [{gettext("Markdown"), :markdown}, {gettext("HTML"), :html}])
    |> assign(:value_parent_options, value_parent_options(values))
    |> assign(:new_value_form, to_form(Value.changeset(%Value{}, %{})))
    |> assign(
      :new_group_form,
      to_form(Group.changeset(%Group{}, %{is_public: false, description_format: :markdown}))
    )
    |> assign(:invite_form, to_form(%{"username" => ""}, as: "invite"))
    |> assign(:invite_form_version, 0)
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group)
  end

  defp current_editing_value(socket) do
    find_value(socket.assigns.values, socket.assigns.editing_value_id)
  end

  defp find_value(_values, nil), do: nil

  defp find_value(values, id) when is_integer(id) do
    Enum.find(values, &(&1.id == id))
  end

  defp find_value(values, id) when is_binary(id) do
    Enum.find(values, &(Integer.to_string(&1.id) == id))
  end

  defp clear_edit_value(socket) do
    socket
    |> assign(:editing_value_id, nil)
    |> assign(:edit_value_form, nil)
  end

  defp value_parent_options(values) do
    Enum.map(values, fn v ->
      label =
        v.content
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 80)

      {"#{v.creator.username}: #{label}", v.id}
    end)
  end

  defp default_active_tab, do: "values"

  defp group_tab_path(group_id, tab), do: ~p"/groups/#{group_id}/#{tab}"

  defp normalize_active_tab(tab, _is_member) when tab in ["values", "sub_groups", "members"],
    do: tab

  defp normalize_active_tab(tab, true)
       when tab in ["create_group", "invite_profile"],
       do: tab

  defp normalize_active_tab(_, _), do: default_active_tab()

  defp normalize_select_nil(attrs, key) when is_binary(key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
    end
  end

  defp can_view_group?(group, is_member) do
    group.is_public or is_member
  end
end
