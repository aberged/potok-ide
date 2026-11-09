defmodule PotokIdeWeb.GroupLive.Sheet do
  @moduledoc """
  A sub-group's description over the app of its parent, which asked for it
  (`AppApi` `show_group`), or over the root's map, which opens any group the
  viewer sees (`Social.get_visible_group_below/3`): the body of
  `Show.GroupSheet`, a LiveView of its own inside the page's, bound to that
  group.

  An app's calls act on the group of the LiveView that runs it, so here the
  apps in the sub-group's description (a form, a board of polls, a feed) work
  with that group's rights, through the same `AppApi`, uploads and dialogs as
  on its own page. It shows only the description the group opens on, with its
  reactions: the rest is on the group's page, a link away.

  Opened only after the page is up, it gets nothing from the page's assigns:
  the page signs who is looking into its session, and it checks again that the
  viewer sees the group. It follows the group and its polls, and ignores the
  rest of what the group's topic carries.
  """
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Scope
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, Group, Profile}

  alias PotokIdeWeb.GroupLive.Show.{
    AppApi,
    AppHost,
    AppValues,
    GroupDescriptionTab,
    PollCard,
    PollForm,
    PollsState
  }

  on_mount {PotokIdeWeb.Locale, :mount_locale}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="group-sheet-body" class="flex min-h-0 flex-1 flex-col">
      <Layouts.sheet_flash flash={@flash} />
      <div
        :if={@unavailable?}
        id="group-sheet-unavailable"
        class="flex flex-1 flex-col items-center justify-center gap-2 px-6 py-12 text-center text-sm text-base-content/65"
      >
        <.icon name="hero-eye-slash" class="size-6" />
        <p>{gettext("This group is no longer here for you.")}</p>
      </div>
      <GroupDescriptionTab.panel
        :if={!@unavailable?}
        group={@group}
        current_profile={@current_profile}
        is_member={@is_member}
        viewer_roles={Enum.join(@access.role_keys, ",")}
        alt_descriptions={@visible_alt_descriptions}
        active_alt_description={@active_alt_description}
        can_edit={false}
        reactions={@group_reactions}
        can_react={@can_react_to_group}
        app_upload={@uploads.sheet_app_file}
        host="sheet"
        switcher={false}
      />
      <PollForm.dialog :if={!@unavailable?} state={@poll_form} />
      <PollCard.dialog :if={!@unavailable?} view={@poll_dialog} />
    </div>
    """
  end

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    with {:ok, scope, profile} <- viewer(session),
         parent_id when is_integer(parent_id) <- session["parent_id"],
         group_id when is_integer(group_id) <- session["group_id"],
         %Group{} = parent <- Social.get_visible_group(profile, parent_id),
         %Group{} = group <- Social.get_visible_group_below(parent, profile, group_id) do
      if connected?(socket) do
        Social.subscribe_group(group)
        AppData.subscribe(group)
      end

      {:ok,
       socket
       |> assign(
         current_scope: scope,
         current_profile: profile,
         calendar_time_zone: session["time_zone"] || "Etc/UTC",
         parent_id: parent.id,
         group: group,
         unavailable?: false,
         in_group_sheet: true,
         # What the shared description code reads of a page (`Show`).
         active_tab: "group_home",
         description_param: nil,
         loaded_value_ids: MapSet.new(),
         app_api_bucket: AppApi.new_bucket()
       )
       |> assign_access(Social.get_group_access(profile, group))
       |> AppHost.allow("sheet")
       |> load_descriptions()
       |> load_reactions()
       |> PollForm.init()
       |> PollsState.init_dialog()
       |> PollsState.maybe_load(group, "group_home"), layout: false}
    else
      _not_theirs -> {:ok, assign(socket, unavailable?: true, group: nil), layout: false}
    end
  end

  # Who the page says is looking, as long as that is still the account's
  # profile: the page itself leaves when the account switches profiles.
  defp viewer(%{"account_id" => account_id, "profile_id" => profile_id})
       when is_integer(account_id) and is_integer(profile_id) do
    with account when not is_nil(account) <- Accounts.get_account(account_id),
         %Profile{id: ^profile_id} = profile <- Social.get_account_current_profile(account) do
      {:ok, Scope.for_account(account), profile}
    else
      _gone -> :error
    end
  end

  defp viewer(_session), do: :error

  defp assign_access(socket, %Access{} = access) do
    socket
    |> assign(:access, access)
    |> assign(:is_member, access.member?)
  end

  # Only the description the group opens on, when the viewer may see it.
  defp load_descriptions(socket) do
    %{group: group, access: access} = socket.assigns

    visible =
      group
      |> Social.list_alt_descriptions()
      |> Enum.filter(&Access.sees_alt_description?(access, &1))

    socket
    |> assign(:visible_alt_descriptions, visible)
    |> assign(
      :active_alt_description,
      group.home_alt_description_id &&
        Enum.find(visible, &(&1.id == group.home_alt_description_id))
    )
  end

  defp load_reactions(socket) do
    %{group: group, current_profile: profile, access: access} = socket.assigns
    reactions = Social.group_reaction_summaries([group.id], profile)

    socket
    |> assign(:group_reactions, Map.get(reactions, group.id, []))
    |> assign(:can_react_to_group, Access.can_react_to_group?(profile, access, group))
  end

  # Roles, the group itself or its descriptions changed: read it all again,
  # and close when the viewer no longer sees it.
  defp reload(socket) do
    %{current_profile: profile, parent_id: parent_id, group: group} = socket.assigns

    with %Group{} = parent <- Social.get_visible_group(profile, parent_id),
         %Group{} = group <- Social.get_visible_group_below(parent, profile, group.id) do
      socket
      |> assign(:group, group)
      |> assign_access(Social.get_group_access(profile, group))
      |> load_descriptions()
      |> load_reactions()
    else
      _gone -> gone(socket)
    end
  end

  defp gone(socket) do
    send(socket.parent_pid, {:group_sheet_gone, socket.assigns.group.id})
    assign(socket, :unavailable?, true)
  end

  @impl true
  def handle_event("app_api", %{"method" => method} = params, socket) when is_binary(method) do
    {reply, socket} =
      AppApi.call(method, Map.get(params, "params") || %{}, Map.get(params, "app_id"), socket)

    {:reply, reply, socket}
  end

  def handle_event("app_api", _params, socket) do
    {:reply, %{ok: false, error: "unknown_method"}, socket}
  end

  def handle_event("validate_app_file", _params, socket),
    do: {:noreply, AppHost.validate_file(socket)}

  def handle_event("poll_form_" <> _ = event, params, socket),
    do: PollForm.handle_event(event, params, socket)

  def handle_event("poll" <> _ = event, params, socket),
    do: PollsState.handle_event(event, params, socket)

  def handle_event("toggle_group_reaction", %{"emoji" => emoji}, socket) do
    %{current_profile: profile, group: group} = socket.assigns

    case Social.toggle_group_reaction(profile, group, emoji) do
      {:ok, reactions} ->
        {:noreply, assign(socket, :group_reactions, reactions)}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not update reaction."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, %{assigns: %{unavailable?: true}} = socket), do: {:noreply, socket}

  def handle_info({:polls, message}, socket), do: PollsState.handle_info(message, socket)

  def handle_info({:data_value_created, group_id, value}, socket)
      when group_id == socket.assigns.group.id,
      do: {:noreply, AppHost.announce_new_data_value(socket, value)}

  def handle_info({:app_value, group_id, event, payload}, socket)
      when group_id == socket.assigns.group.id,
      do: {:noreply, AppValues.announce(socket, event, payload)}

  def handle_info({:group_reactions_updated, group_id}, socket)
      when group_id == socket.assigns.group.id,
      do: {:noreply, load_reactions(socket)}

  def handle_info({event, group_id}, socket)
      when event in [
             :group_updated,
             :group_roles_updated,
             :group_description_updated,
             :alt_descriptions_updated
           ] and group_id == socket.assigns.group.id,
      do: {:noreply, reload(socket)}

  def handle_info({:group_deleted, group_id, _parent_id}, socket)
      when group_id == socket.assigns.group.id,
      do: {:noreply, gone(socket)}

  # The rest of the group's topic is for its own page: values, members, presence.
  def handle_info(_message, socket), do: {:noreply, socket}
end
