defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.{Group, Value}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <.header>
          {@group.name}
          <:subtitle>
            {if @group.is_root, do: "Root Group", else: "Group"} · {if @group.is_public,
              do: "public",
              else: "private"}
          </:subtitle>
        </.header>
        
        <div :if={@group.description && @group.description != ""} class="text-sm text-base-content/70">
          {@group.description}
        </div>
        
        <div class="grid grid-cols-1 gap-6">
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Sub-groups</h3>
              
              <div :if={@children == []} class="text-base-content/70">No sub-groups yet.</div>
              
              <ul :if={@children != []} class="space-y-2">
                <li :for={g <- @children}>
                  <.link navigate={~p"/groups/#{g.id}"} class="link link-hover">{g.name}</.link>
                  <span class="text-xs text-base-content/60">
                    ({if g.is_public, do: "public", else: "private"})
                  </span>
                </li>
              </ul>
            </div>
          </div>
          
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Members</h3>
              
              <div :if={@members == []} class="text-base-content/70">No members.</div>
              
              <ul :if={@members != []} class="space-y-1">
                <li :for={m <- @members}>{m.username}</li>
              </ul>
            </div>
          </div>
          
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Values</h3>
              
              <div :if={@values == []} class="text-base-content/70">No values yet.</div>
              
              <div :for={v <- @values} class="border-b border-base-300 py-3 last:border-0">
                <div class="text-xs text-base-content/60">
                  {v.creator.username} · {Calendar.strftime(v.inserted_at, "%Y-%m-%d %H:%M")} {if v.parent_id,
                    do: "· reply/forward"}
                </div>
                
                <div class="mt-1 whitespace-pre-wrap">{v.content}</div>
              </div>
            </div>
          </div>
        </div>
        
        <div :if={!@is_member} class="alert">
          <.icon name="hero-lock-closed" class="size-5 shrink-0" />
          <div>
            You can view this group, but you must be a member to post values, invite members, or create sub-groups.
          </div>
        </div>
        
        <div :if={@is_member} class="grid grid-cols-1 gap-6">
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Create value</h3>
              
              <.form for={@new_value_form} phx-change="validate_value" phx-submit="create_value">
                <.input
                  field={@new_value_form[:content_format]}
                  label="Format"
                  type="select"
                  options={@format_options}
                />
                <.input field={@new_value_form[:content]} label="Content" type="textarea" required />
                <.input
                  field={@new_value_form[:parent_id]}
                  label="Parent value (optional)"
                  type="select"
                  prompt="(none)"
                  options={@value_parent_options}
                /> <.button phx-disable-with="Posting..." variant="primary">Post</.button>
              </.form>
            </div>
          </div>
          
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Create sub-group</h3>
              
              <.form for={@new_group_form} phx-change="validate_group" phx-submit="create_group">
                <.input field={@new_group_form[:name]} label="Name" required />
                <.input
                  field={@new_group_form[:description_format]}
                  label="Format"
                  type="select"
                  options={@format_options}
                />
                <.input field={@new_group_form[:description]} label="Description" type="textarea" />
                <.input field={@new_group_form[:is_public]} label="Public" type="checkbox" />
                <.input
                  field={@new_group_form[:parent_value_id]}
                  label="Reply to value (optional)"
                  type="select"
                  prompt="(none)"
                  options={@value_parent_options}
                /> <.button phx-disable-with="Creating..." variant="primary">Create</.button>
              </.form>
            </div>
          </div>
          
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title">Invite profile</h3>
              
              <.form for={@invite_form} phx-submit="invite">
                <.input field={@invite_form[:username]} label="Invitee username" required />
                <.button phx-disable-with="Inviting..." variant="primary">Invite</.button>
              </.form>
              
              <div class="mt-2 text-xs text-base-content/60">
                Invitees accept invitations at <.link navigate={~p"/invitations"} class="link">/invitations</.link>.
              </div>
            </div>
          </div>
        </div>
        
        <div class="mt-6"><.link navigate={~p"/groups"} class="link">Back to Root Group</.link></div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(id)

    is_member = Social.member_of_group?(current_profile, group)

    if can_view_group?(group, is_member) do
      {:ok, socket |> assign(:is_member, is_member) |> load_group_data(group)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to that group.")
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
      {:noreply, put_flash(socket, :error, "You must be a group member to post values.")}
    else
      case Social.create_value(current_profile, group, normalize_select_nil(attrs, "parent_id")) do
        {:ok, _value} ->
          {:noreply,
           socket
           |> put_flash(:info, "Value posted.")
           |> refresh_group_data()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not create value.")}
      end
    end
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
      {:noreply, put_flash(socket, :error, "You must be a group member to create sub-groups.")}
    else
      attrs =
        attrs
        |> normalize_select_nil("parent_value_id")
        |> Map.put("is_root", false)

      case Social.create_group(current_profile, parent, attrs) do
        {:ok, child} ->
          {:noreply,
           socket
           |> put_flash(:info, "Group created.")
           |> push_navigate(to: ~p"/groups/#{child.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_group_form, to_form(changeset))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not create group.")}
      end
    end
  end

  def handle_event("invite", %{"invite" => %{"username" => username}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, "You must be a member to invite.")}
    else
      username = String.trim(username || "")

      with false <- username == "",
           %{} = invitee <- Social.get_profile_by_username(username),
           {:ok, _inv} <- Social.invite_profile_to_group(current_profile, group, invitee) do
        {:noreply, put_flash(socket, :info, "Invitation sent.")}
      else
        true ->
          {:noreply, put_flash(socket, :error, "Username is required.")}

        nil ->
          {:noreply, put_flash(socket, :error, "No profile found with that username.")}

        {:error, :inviter_not_a_member} ->
          {:noreply, put_flash(socket, :error, "You must be a member to invite.")}

        {:error, :cannot_invite_self} ->
          {:noreply, put_flash(socket, :error, "You cannot invite yourself.")}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, "An invitation is already pending.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not send invitation.")}
      end
    end
  end

  defp load_group_data(socket, group) do
    values = Social.list_group_values(group)

    socket
    |> assign(:group, group)
    |> assign(:children, Social.list_child_groups(group))
    |> assign(:members, Social.list_group_members(group))
    |> assign(:values, values)
    |> assign(:format_options, Markdown: :markdown, HTML: :html)
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
