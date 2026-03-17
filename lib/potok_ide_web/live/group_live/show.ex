defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  import Phoenix.HTML, only: [raw: 1]

  alias PotokIde.Social
  alias PotokIde.Social.{Group, Value}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-2">
        <div class="flex items-start gap-3">
          <div :if={!@group.is_root and @group.parent_id} class="pt-1">
            <.link navigate={~p"/groups/#{@group.parent_id}"} class="link text-xl no-underline">
              {"❮"}
            </.link>
          </div>

          <div class="min-w-0 flex-1">
            <.header>
              {@group.name} {if @group.is_public,
                do: "📢",
                else: "🔐"}
              <:subtitle>
                <div
                  :if={@group.description && @group.description != ""}
                  class="text-sm text-base-content/70"
                >
                  {@group.description}
                </div>
              </:subtitle>
            </.header>
          </div>

          <Layouts.header_menu icon="hero-ellipsis-horizontal">
            <div class="flex min-w-[14rem] flex-col gap-2">
              <.group_tab_button
                id="group-tab-values"
                tab="values"
                active_tab={@active_tab}
                label={gettext("Values")}
              />
              <.group_tab_button
                id="group-tab-sub-groups"
                tab="sub_groups"
                active_tab={@active_tab}
                label={gettext("Sub-groups")}
              />
              <.group_tab_button
                id="group-tab-members"
                tab="members"
                active_tab={@active_tab}
                label={gettext("Members")}
              />

              <.group_tab_button
                :if={@is_member}
                id="group-tab-create-value"
                tab="create_value"
                active_tab={@active_tab}
                label={gettext("Create value")}
              />
              <.group_tab_button
                :if={@is_member}
                id="group-tab-create-sub-group"
                tab="create_group"
                active_tab={@active_tab}
                label={gettext("Create sub-group")}
              />
              <.group_tab_button
                :if={@is_member}
                id="group-tab-invite-profile"
                tab="invite_profile"
                active_tab={@active_tab}
                label={gettext("Invite profile")}
              />
            </div>
          </Layouts.header_menu>
        </div>

        <div class="space-y-2">
          <div :if={!@is_member} class="alert">
            <.icon name="hero-lock-closed" class="size-5 shrink-0" />
            <div>
              {gettext(
                "You can view this group, but you must be a member to post values, invite members, or create sub-groups."
              )}
            </div>
          </div>

          <div :if={@active_tab == "sub_groups"} id="group-panel-sub-groups" class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">{gettext("Sub-groups")}</h3>

              <div :if={@children == []} class="text-base-content/70">
                {gettext("No sub-groups yet.")}
              </div>

              <ul :if={@children != []} class="space-y-2">
                <li :for={g <- @children}>
                  <.link navigate={~p"/groups/#{g.id}"} class="link link-hover">{g.name}</.link>
                  <span class="text-xs text-base-content/60">
                    ({if g.is_public, do: gettext("public"), else: gettext("private")})
                  </span>
                </li>
              </ul>
            </div>
          </div>

          <div :if={@active_tab == "members"} id="group-panel-members" class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">{gettext("Members")}</h3>

              <div :if={@members == []} class="text-base-content/70">{gettext("No members.")}</div>

              <ul :if={@members != []} class="space-y-2">
                <li :for={m <- @members}>
                  <.profile_identity profile={m} />
                </li>
              </ul>
            </div>
          </div>

          <div :if={@active_tab == "values"} id="group-panel-values" class="card bg-base-200">
            <div class="card-body">
              <%!-- <h3 class="card-title">{gettext("Values")}</h3> --%>

              <div :if={@values == []} class="text-base-content/70">{gettext("No values yet.")}</div>

              <div :for={v <- @values} class="chat chat-start border-b border-base-300 py-3 last:border-0">

                <div class="flex items-start gap-3">
                  <.profile_identity profile={v.creator} v={v} avatar_size="size-9" expanded_value_ids={@expanded_value_ids} text_class="text-xs" />

                  <%!-- <div class="min-w-0 text-xs text-base-content/60">
                    <div class="truncate">
                      {Calendar.strftime(v.inserted_at, "%Y-%m-%d %H:%M")}
                      {if v.parent_id, do: gettext("· reply/forward")}
                    </div>
                  </div> --%>
                </div>

                <%!-- <div class="relative mt-2">
                  <div
                    class={[
                      "break-words [&_a]:link [&_blockquote]:border-l-4 [&_blockquote]:border-base-300 [&_blockquote]:pl-4 [&_code]:rounded-md [&_code]:bg-base-300/70 [&_code]:px-1.5 [&_code]:py-0.5 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-base-300/70 [&_pre]:p-3 [&_ul]:list-disc [&_ul]:pl-6",
                      !value_expanded?(@expanded_value_ids, v) && value_expandable?(v) &&
                        "overflow-hidden"
                    ]}
                    style={collapsed_value_style(@expanded_value_ids, v)}
                  >
                    {render_value_content(v)}
                  </div>

                  <div
                    :if={value_expandable?(v) and !value_expanded?(@expanded_value_ids, v)}
                    class="pointer-events-none absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t from-base-200 to-transparent"
                  >
                  </div>

                  <button
                    :if={value_expandable?(v)}
                    type="button"
                    phx-click="toggle_value_expansion"
                    phx-value-id={v.id}
                    class="mt-3 text-sm font-semibold text-primary transition-opacity hover:opacity-80"
                  >
                    {if value_expanded?(@expanded_value_ids, v),
                      do: gettext("See less"),
                      else: gettext("See more")}
                  </button>
                </div> --%>
              </div>
            </div>
          </div>

          <div
            :if={@is_member and @active_tab == "create_value"}
            id="group-panel-create-value"
            class="card bg-base-200"
          >
            <div class="card-body">
              <h3 class="card-title">{gettext("Create value")}</h3>

              <.form for={@new_value_form} phx-change="validate_value" phx-submit="create_value">
                <.input
                  field={@new_value_form[:content_format]}
                  label={gettext("Format")}
                  type="select"
                  options={@format_options}
                />
                <.input
                  field={@new_value_form[:content]}
                  label={gettext("Content")}
                  type="textarea"
                  required
                />
                <.input
                  field={@new_value_form[:parent_id]}
                  label={gettext("Parent value (optional)")}
                  type="select"
                  prompt={gettext("(none)")}
                  options={@value_parent_options}
                />
                <.button phx-disable-with={gettext("Posting...")} variant="primary">
                  {gettext("Post")}
                </.button>
              </.form>
            </div>
          </div>

          <div
            :if={@is_member and @active_tab == "create_group"}
            id="group-panel-create-group"
            class="card bg-base-200"
          >
            <div class="card-body">
              <h3 class="card-title">{gettext("Create sub-group")}</h3>

              <.form for={@new_group_form} phx-change="validate_group" phx-submit="create_group">
                <.input field={@new_group_form[:name]} label={gettext("Name")} required />
                <.input
                  field={@new_group_form[:description_format]}
                  label={gettext("Format")}
                  type="select"
                  options={@format_options}
                />
                <.input
                  field={@new_group_form[:description]}
                  label={gettext("Description")}
                  type="textarea"
                />
                <.input field={@new_group_form[:is_public]} label={gettext("Public")} type="checkbox" />
                <.input
                  field={@new_group_form[:parent_value_id]}
                  label={gettext("Reply to value (optional)")}
                  type="select"
                  prompt={gettext("(none)")}
                  options={@value_parent_options}
                />
                <.button phx-disable-with={gettext("Creating...")} variant="primary">
                  {gettext("Create")}
                </.button>
              </.form>
            </div>
          </div>

          <div
            :if={@is_member and @active_tab == "invite_profile"}
            id="group-panel-invite-profile"
            class="card bg-base-200"
          >
            <div class="card-body">
              <h3 class="card-title">{gettext("Invite profile")}</h3>

              <.form for={@invite_form} phx-submit="invite">
                <.input field={@invite_form[:username]} label={gettext("Invitee username")} required />
                <.button phx-disable-with={gettext("Inviting...")} variant="primary">
                  {gettext("Invite")}
                </.button>
              </.form>

              <div class="mt-2 text-xs text-base-content/60">
                {gettext("Invitees accept invitations at")}
                <.link navigate={~p"/invitations"} class="link">/invitations</.link>.
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :active_tab, :string, required: true
  attr :label, :string, required: true

  def group_tab_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        "w-full rounded-2xl px-4 py-2 text-left text-sm font-medium transition-colors",
        if(@active_tab == @tab,
          do: "bg-base-content text-base-100 shadow-sm",
          else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"

  def profile_identity(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <%= if v = @v do %>
        <%= if expanded_value_ids=@expanded_value_ids do %>

          <div class="chat chat-start">
            <div class="chat-image avatar">
              <div class="w-10 rounded-full">
                <img
                  alt={@profile.username}
                  src={profile_picture_url(@profile)}
                />
              </div>
            </div>
            <div class="chat-header">
              {@profile.username}
              <time class="text-xs opacity-50">
                <div class="truncate">
                  {Calendar.strftime(v.inserted_at, "%Y-%m-%d %H:%M")}
                  {if v.parent_id, do: gettext("· reply/forward")}
                </div>
              </time>
            </div>
            <div class="chat-bubble">
              <div class="relative mt-2">
                <div
                  class={[
                    "break-words [&_a]:link [&_blockquote]:border-l-4 [&_blockquote]:border-base-300 [&_blockquote]:pl-4 [&_code]:rounded-md [&_code]:bg-base-300/70 [&_code]:px-1.5 [&_code]:py-0.5 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:bg-base-300/70 [&_pre]:p-3 [&_ul]:list-disc [&_ul]:pl-6",
                    !value_expanded?(expanded_value_ids, v) && value_expandable?(v) &&
                      "overflow-hidden"
                  ]}
                  style={collapsed_value_style(expanded_value_ids, v)}
                >
                  {render_value_content(v)}
                </div>

                <div
                  :if={value_expandable?(v) and !value_expanded?(expanded_value_ids, v)}
                  class="pointer-events-none absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t from-base-200 to-transparent"
                >
                </div>

                <button
                  :if={value_expandable?(v)}
                  type="button"
                  phx-click="toggle_value_expansion"
                  phx-value-id={v.id}
                  class="mt-3 text-sm font-semibold text-primary transition-opacity hover:opacity-80"
                >
                  {if value_expanded?(expanded_value_ids, v),
                    do: gettext("See less"),
                    else: gettext("See more")}
                </button>
              </div>
            </div>
            <div class="chat-footer opacity-50">TODO:// Delivered</div>
          </div>

        <% end %>
      <% else %>
        <%= if avatar_url = profile_picture_url(@profile) do %>
          <img
            src={avatar_url}
            alt={@profile.username}
            class={[@avatar_size, "shrink-0 rounded-full border border-base-300 object-cover shadow-sm"]}
          />
        <% else %>
          <div class={[
            @avatar_size,
            "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
          ]}>
            {profile_initials(@profile.username)}
          </div>
        <% end %>

        <div class="min-w-0">
          <div class={[@text_class, "truncate font-semibold text-base-content"]}>
            {@profile.username}
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(id)

    is_member = Social.member_of_group?(current_profile, group)

    if can_view_group?(group, is_member) do
      {:ok,
       socket
       |> assign(:is_member, is_member)
       |> assign(:active_tab, default_active_tab())
       |> load_group_data(group)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have access to that group."))
       |> push_navigate(to: ~p"/groups")}
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
      |> Value.changeset(attrs)
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
          {:noreply,
           socket
           |> assign(:active_tab, "values")
           |> put_flash(:info, gettext("Value posted."))
           |> refresh_group_data()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create value."))}
      end
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, normalize_active_tab(tab, socket.assigns.is_member))}
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
        {:noreply, put_flash(socket, :info, gettext("Invitation sent."))}
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
    |> assign(:children, Social.list_child_groups(group))
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
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group)
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

  defp render_value_content(%{content: content, content_format: :html}) do
    content
    |> sanitize_html()
    |> raw()
  end

  defp render_value_content(%{content: content, content_format: :markdown}) do
    content
    |> Earmark.as_html!()
    |> sanitize_html()
    |> raw()
  end

  defp render_value_content(%{content: content}) when is_binary(content), do: content

  defp sanitize_html(content) when is_binary(content), do: HtmlSanitizeEx.basic_html(content)

  defp value_expandable?(%{content: content}) when is_binary(content) do
    (String.contains?(content, "\n") and length(String.split(content, ~r/\R/, trim: false)) > 5) or
      String.length(content) > 320
  end

  defp value_expandable?(_), do: false

  defp value_expanded?(expanded_value_ids, %{id: value_id}) do
    MapSet.member?(expanded_value_ids, value_id)
  end

  defp collapsed_value_style(expanded_value_ids, value) do
    if value_expandable?(value) and !value_expanded?(expanded_value_ids, value) do
      "max-height: calc(1.5rem * 5);"
    else
      nil
    end
  end

  defp default_active_tab, do: "values"

  defp normalize_active_tab(tab, _is_member) when tab in ["values", "sub_groups", "members"],
    do: tab

  defp normalize_active_tab(tab, true)
       when tab in ["create_value", "create_group", "invite_profile"],
       do: tab

  defp normalize_active_tab(_, _), do: default_active_tab()

  defp normalize_select_nil(attrs, key) when is_binary(key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
    end
  end

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil

  defp profile_initials(username) when is_binary(username) do
    username
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp profile_initials(_), do: "?"

  defp can_view_group?(group, is_member) do
    group.is_public or is_member
  end
end
