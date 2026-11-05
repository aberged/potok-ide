defmodule PotokIdeWeb.GroupLive.Show.AppApi do
  @moduledoc """
  Server side of the API that apps in `uses_api` groups reach from their
  sandboxed iframe (`potok_app_sdk.js` -> `GroupAppFrame` hook -> `app_api`).

  The hook only forwards whitelisted methods, but every permission is checked
  here again: the iframe content is written by the group's editors and runs
  for every viewer.

  A group has one app per description: the default one (`app_id` "") and
  each alternative description with `uses_api`. Calls act on the description
  on screen (`active_alt_description`) and name the app they come from, so a
  call that was on its way while the viewer switched apps is refused.

  An app also keeps the groups right under its own (`list_children`,
  `create_child` and the rest), and that acts in the viewer's name, so it works
  only for a viewer who may edit the app's group. They are the ones who could
  rewrite the app anyway, and by default only admins hold that permission.
  A reaction is the one exception (`toggle_group_reaction`): it needs a reader,
  not an editor, so it asks only what the same reaction asks on the group's
  page. The price is that an app can add one in its viewer's name unasked, to a
  group below it, where the viewer sees it and can take it back.
  """
  use Gettext, backend: PotokIdeWeb.Gettext
  use PotokIdeWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_navigate: 2]

  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group}
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.PublicPreview

  # Token bucket for writes: bursts of up to @write_burst, refilled over @write_window_ms.
  @write_burst 30
  @write_window_ms 10_000

  @max_list_limit 200

  # Sub-groups carry their rendered descriptions, so their pages stay short.
  @default_subgroup_limit 20
  @max_subgroup_limit 50

  @signed_in_methods ~w(
    list_subgroups open_group get_group list_children get_child
    create_child update_child withdraw_child preview_description
    toggle_group_reaction share_group
  )

  # All an app may set on a group. Never `uses_api`: an app that made another
  # app would run its code for every viewer of that group.
  @child_fields ~w(name description description_format is_public inherits_members)

  def new_bucket do
    %{tokens: @write_burst, refilled_at: System.monotonic_time(:millisecond)}
  end

  @doc "The id an app frame sends with its calls: \"\" for the default description."
  def app_id(nil), do: ""
  def app_id(%{id: id}), do: Integer.to_string(id)

  @doc "Runs an API method for the app `app_id` and returns `{reply, socket}`."
  def call(method, params, app_id, socket) do
    # Hooks of pages loaded before apps had ids send none; they only ran the default app.
    if (app_id || "") == app_id(socket.assigns.active_alt_description) do
      run(method, params, socket)
    else
      {error("stale_app", nil), socket}
    end
  end

  defp run("insert_value", params, socket) do
    with :ok <-
           require_member(
             socket,
             gettext("You must be a group member to access group data values.")
           ),
         {:ok, socket} <- take_write_token(socket) do
      attrs = %{
        "content" => "data:",
        "data" => Map.get(params, "data"),
        "content_format" => Map.get(params, "content_format") || "markdown"
      }

      case Social.create_data_value(
             socket.assigns.current_profile,
             socket.assigns.group,
             attrs,
             socket.assigns.active_alt_description
           ) do
        {:ok, value} ->
          {%{ok: true, value: Show.value_payload(value)}, socket}

        {:error, _reason} ->
          {error("invalid_value", gettext("Could not save the data value.")), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("list_values", params, socket) do
    case require_member(
           socket,
           gettext("You must be a group member to access group data values.")
         ) do
      :ok ->
        {rows, has_more?} =
          Social.list_group_data_value_rows(socket.assigns.group,
            scope: list_scope(params["scope"], socket.assigns),
            limit: non_negative_integer(params["limit"]) |> clamp_limit(),
            offset: non_negative_integer(params["offset"]),
            after_id: non_negative_integer(params["after_id"]),
            before_id: non_negative_integer(params["before_id"]),
            search_field: optional_string(params["search_field"]),
            search_value: optional_string(params["search_value"]),
            order_by: optional_string(params["order_by"]),
            order_dir: optional_string(params["order_dir"])
          )

        values = Enum.map(rows, &Map.update!(&1, :content_format, fn f -> to_string(f) end))
        {%{ok: true, values: values, has_more: has_more?}, socket}

      {:error, reply} ->
        {reply, socket}
    end
  end

  defp run("update_description", params, socket) do
    forbidden = gettext("Your roles in this group do not allow that.")
    current = description_source(socket.assigns)

    with true <-
           Access.can?(socket.assigns.access, :edit_group) ||
             {:error, error("forbidden", forbidden)},
         {:ok, socket} <- take_write_token(socket) do
      attrs = %{
        "description" => string_param(params["description"], current.description || ""),
        "description_format" =>
          string_param(params["description_format"], to_string(current.description_format))
      }

      case update_description(socket, attrs) do
        {:ok, socket} ->
          {%{ok: true, group: description_payload(socket.assigns)}, socket}

        {:error, :not_permitted} ->
          {error("forbidden", forbidden), socket}

        {:error, _reason} ->
          {error("invalid_description", gettext("Could not update group description.")), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("get_description", _params, socket) do
    {%{ok: true, group: description_payload(socket.assigns)}, socket}
  end

  defp run("current_profile", _params, socket) do
    {%{ok: true, profile: profile_payload(socket.assigns.current_profile, socket.assigns.access)},
     socket}
  end

  defp run(method, _params, %{assigns: %{current_profile: nil}} = socket)
       when method in @signed_in_methods do
    {error("forbidden", gettext("Your roles in this group do not allow that.")), socket}
  end

  # An app runs for every viewer and with the viewer's sight, so it reaches
  # below its group only through what that viewer can see, one level under a
  # direct sub-group.
  defp run("list_subgroups", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with name when is_binary(name) <- params["name"],
         %Group{} = parent <- Social.get_visible_child_group_by_name(group, profile, name) do
      {groups, has_more?} =
        Social.list_visible_child_groups_newest_first(parent, profile,
          limit: subgroup_limit(params["limit"]),
          before_id: non_negative_integer(params["before_id"])
        )

      {%{ok: true, groups: subgroup_payloads(groups, profile), has_more: has_more?}, socket}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  # An app sends its viewer no further than its parent and the two levels below
  # it, and only to what that viewer can see.
  defp run("open_group", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = target <- reachable_group(group, profile, id) do
      {%{ok: true}, push_navigate(socket, to: group_tab_path(target, params["tab"]))}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  defp run("toggle_group_reaction", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = target <- group_below(group, profile, id),
         {:ok, socket} <- take_write_token(socket) do
      case Social.toggle_group_reaction(profile, target, params["emoji"]) do
        {:ok, reactions} ->
          {%{ok: true, reactions: Enum.map(reactions, &reaction_payload/1)}, socket}

        {:error, :not_permitted} ->
          {error("forbidden", gettext("Your roles in this group do not allow that.")), socket}

        {:error, _invalid} ->
          {error("invalid_emoji", nil), socket}
      end
    else
      {:error, reply} -> {reply, socket}
      _not_found -> {error("not_found", nil), socket}
    end
  end

  # The frame can share nothing itself: the sandbox keeps it from Web Share, the
  # clipboard and the mobile app, so the page does it (`shareLink` in longpress.js).
  defp run("share_group", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = target <- reachable_group(group, profile, id) do
      {%{ok: true}, push_event(socket, "app_share_link", %{url: url(~p"/groups/#{target.id}")})}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  defp run("get_group", _params, socket) do
    {%{ok: true, group: group_payload(socket.assigns)}, socket}
  end

  defp run("list_children", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    case require_child_manager(socket) do
      :ok ->
        {groups, has_more?} =
          Social.list_visible_child_groups_newest_first(group, profile,
            limit: subgroup_limit(params["limit"]),
            before_id: non_negative_integer(params["before_id"])
          )

        {%{ok: true, groups: subgroup_payloads(groups, profile), has_more: has_more?}, socket}

      {:error, reply} ->
        {reply, socket}
    end
  end

  defp run("get_child", params, socket) do
    with :ok <- require_child_manager(socket),
         {:ok, child} <- fetch_child(params, socket) do
      {%{ok: true, group: child_payload(child, socket.assigns.current_profile)}, socket}
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("create_child", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with :ok <- require_child_manager(socket),
         {:ok, socket} <- take_write_token(socket) do
      Social.create_group(profile, group, child_attrs(params))
      |> child_reply(socket)
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("update_child", params, socket) do
    profile = socket.assigns.current_profile

    with :ok <- require_child_manager(socket),
         {:ok, child} <- fetch_editable_child(params, socket),
         {:ok, socket} <- take_write_token(socket) do
      Social.update_group(profile, child, child_attrs(params))
      |> child_reply(socket)
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("withdraw_child", params, socket) do
    profile = socket.assigns.current_profile

    with :ok <- require_child_manager(socket),
         {:ok, child} <- fetch_editable_child(params, socket),
         {:ok, socket} <- take_write_token(socket) do
      Social.withdraw_group(profile, child)
      |> child_reply(socket)
    else
      {:error, reply} -> {reply, socket}
    end
  end

  # What a feed will show, by the same road as `description_html` in a sub-group.
  defp run("preview_description", params, socket) do
    with :ok <- require_child_manager(socket),
         {:ok, format} <- description_format(params["description_format"]),
         {:ok, socket} <- take_write_token(socket) do
      html =
        Components.description_html(%Group{
          description: string_param(params["description"], ""),
          description_format: format
        })

      {%{ok: true, html: html}, socket}
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run(_method, _params, socket) do
    {error("unknown_method", nil), socket}
  end

  defp reachable_group(%Group{parent_id: id}, profile, id),
    do: Social.get_visible_group(profile, id)

  defp reachable_group(group, profile, id), do: group_below(group, profile, id)

  defp group_below(group, profile, id) do
    Social.get_visible_child_group(group, profile, id) ||
      Social.get_visible_grandchild_group(group, profile, id)
  end

  defp require_child_manager(socket) do
    if manages_children?(socket.assigns.access) do
      :ok
    else
      {:error, error("forbidden", gettext("Your roles in this group do not allow that."))}
    end
  end

  defp manages_children?(access), do: Access.can?(access, :edit_group)

  defp fetch_child(params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = child <- Social.get_visible_child_group(group, profile, id) do
      {:ok, child}
    else
      _not_found -> {:error, error("not_found", nil)}
    end
  end

  # A group that is an app keeps its code away from other apps.
  defp fetch_editable_child(params, socket) do
    with {:ok, child} <- fetch_child(params, socket) do
      if editable_child?(child, socket.assigns.current_profile) do
        {:ok, child}
      else
        {:error, error("forbidden", gettext("Your roles in this group do not allow that."))}
      end
    end
  end

  defp editable_child?(%Group{uses_api: true}, _profile), do: false
  defp editable_child?(child, profile), do: Access.can?(profile, child, :edit_group)

  defp child_attrs(params) do
    attrs = Map.take(params, @child_fields)

    case params["picture"] do
      picture when is_binary(picture) -> Map.put(attrs, "group_picture_url", picture)
      _none -> attrs
    end
  end

  defp child_reply({:ok, %Group{} = child}, socket) do
    {%{ok: true, group: child_payload(child, socket.assigns.current_profile)}, socket}
  end

  defp child_reply({:error, %Ecto.Changeset{}}, socket) do
    {error("invalid_group", gettext("Could not save the group.")), socket}
  end

  defp child_reply({:error, _not_allowed}, socket) do
    {error("forbidden", gettext("Your roles in this group do not allow that.")), socket}
  end

  defp description_format(nil), do: {:ok, :markdown}
  defp description_format("markdown"), do: {:ok, :markdown}
  defp description_format("html"), do: {:ok, :html}

  defp description_format(_format) do
    {:error, error("invalid_description", gettext("Could not update group description."))}
  end

  defp update_description(%{assigns: %{active_alt_description: nil}} = socket, attrs) do
    case Social.update_group_description(
           socket.assigns.current_profile,
           socket.assigns.group,
           attrs
         ) do
      {:ok, group} -> {:ok, assign(socket, :group, group)}
      error -> error
    end
  end

  defp update_description(%{assigns: %{active_alt_description: alt}} = socket, attrs) do
    case Social.update_alt_description(
           socket.assigns.current_profile,
           socket.assigns.group,
           alt,
           attrs
         ) do
      {:ok, alt} -> {:ok, assign(socket, :active_alt_description, alt)}
      error -> error
    end
  end

  # "group": the values of every app the viewer can open in the group.
  defp list_scope("group", assigns),
    do: {:group, Enum.map(assigns.visible_alt_descriptions, & &1.id)}

  defp list_scope(_scope, %{active_alt_description: alt}), do: {:app, alt && alt.id}

  defp description_source(%{active_alt_description: nil, group: group}), do: group
  defp description_source(%{active_alt_description: alt}), do: alt

  defp require_member(socket, message) do
    if socket.assigns.is_member, do: :ok, else: {:error, error("not_a_member", message)}
  end

  defp take_write_token(socket) do
    now = System.monotonic_time(:millisecond)
    %{tokens: tokens, refilled_at: refilled_at} = socket.assigns.app_api_bucket
    refill = (now - refilled_at) * @write_burst / @write_window_ms
    tokens = min(@write_burst, tokens + refill)

    if tokens >= 1 do
      {:ok, assign(socket, :app_api_bucket, %{tokens: tokens - 1, refilled_at: now})}
    else
      {:error,
       error("rate_limited", gettext("Too many changes in a short time. Try again shortly."))}
    end
  end

  defp error(code, nil), do: %{ok: false, error: code}
  defp error(code, message), do: %{ok: false, error: code, message: message}

  # `id` is the group's; `description_id` is nil for the default description.
  defp description_payload(%{group: group, active_alt_description: alt} = assigns) do
    source = description_source(assigns)

    %{
      id: group.id,
      description_id: alt && alt.id,
      name: if(alt, do: alt.name, else: group.description_name),
      description: source.description || "",
      description_format: to_string(source.description_format)
    }
  end

  # A group that is an app runs on its description tab.
  defp group_tab_path(group, "description"), do: ~p"/groups/#{group.id}/group_home"
  defp group_tab_path(group, "settings"), do: ~p"/groups/#{group.id}/edit_group"
  defp group_tab_path(group, _chat), do: ~p"/groups/#{group.id}/values"

  # What an app needs to know about the place it stands in. `parent` is nil for
  # a viewer who cannot see that group.
  defp group_payload(%{group: group, access: access, current_profile: profile}) do
    %{
      id: group.id,
      name: group.name,
      is_public: group.is_public,
      inherits_members: group.inherits_members,
      parent: parent_payload(group, profile),
      can_manage_children: manages_children?(access),
      can_create_children: manages_children?(access) and Access.can?(access, :create_subgroups),
      # Then any member can put a group here by hand, past the app.
      everyone_creates_subgroups: Access.everyone_can?(access, :create_subgroups)
    }
  end

  defp parent_payload(%Group{parent_id: nil}, _profile), do: nil

  defp parent_payload(%Group{parent_id: parent_id}, profile) do
    case Social.get_visible_group(profile, parent_id) do
      %Group{} = parent ->
        %{
          id: parent.id,
          name: parent.name,
          is_public: parent.is_public,
          uses_api: parent.uses_api
        }

      nil ->
        nil
    end
  end

  # `description_html` is sanitized, so an app can put it in its page. The raw
  # description would run there with the viewer's rights. An app in a sub-group
  # has no text to show, only what it says about itself.
  defp subgroup_payload(%Group{} = group, stats) do
    %{
      id: group.id,
      name: group.name,
      description_html: Components.description_html(group),
      app_description: if(group.uses_api, do: PublicPreview.app_description(group)),
      uses_api: group.uses_api,
      picture_url: Avatars.group_avatar_url(group),
      is_public: group.is_public,
      inherits_members: group.inherits_members,
      creator_id: group.creator_id,
      inserted_at: group.inserted_at,
      published_at: group.published_at,
      last_value_at: group.last_value_at,
      comment_count: Map.get(stats.comments, group.id, 0),
      reactions: stats.reactions |> Map.get(group.id, []) |> Enum.map(&reaction_payload/1),
      can_react:
        Access.can_react_to_group?(stats.profile, Map.fetch!(stats.access, group.id), group)
    }
  end

  # What is read per group goes in one query for the page. The names of who
  # reacted stay on the group's page: an app needs only how many.
  defp subgroup_payloads(groups, profile) do
    ids = Enum.map(groups, & &1.id)

    stats = %{
      profile: profile,
      comments: Social.group_comment_counts(ids),
      reactions: Social.group_reaction_summaries(ids, profile),
      access: Access.for_profile_in_groups(profile, groups)
    }

    Enum.map(groups, &subgroup_payload(&1, stats))
  end

  defp reaction_payload(reaction) do
    %{emoji: reaction.emoji, count: reaction.count, mine: reaction.mine?}
  end

  # The source goes only to who may change it, and never for a group that is an
  # app. `member_count` tells a closed group that still holds people from one
  # that holds only its author.
  defp child_payload(%Group{} = child, profile) do
    can_edit? = editable_child?(child, profile)

    [child]
    |> subgroup_payloads(profile)
    |> hd()
    |> Map.merge(%{
      description: if(can_edit?, do: child.description || ""),
      description_format: to_string(child.description_format),
      can_edit: can_edit?,
      member_count: Social.count_group_members(child),
      updated_at: child.updated_at
    })
  end

  defp profile_payload(nil, _access), do: nil

  # `roles` are the role names (handles) the profile holds in the group.
  defp profile_payload(profile, %Access{} = access) do
    roles = if access.manifest, do: access.manifest.roles, else: []

    %{
      id: profile.id,
      username: profile.username,
      profile_picture_url: Avatars.profile_avatar_url(profile),
      description: profile.description,
      description_format: profile.description_format,
      sharing: profile.sharing,
      inserted_at: profile.inserted_at,
      updated_at: profile.updated_at,
      admin: access.admin?,
      roles: for(role <- roles, role.key in access.role_keys, do: role.name)
    }
  end

  defp clamp_limit(nil), do: nil
  defp clamp_limit(limit), do: min(limit, @max_list_limit)

  defp subgroup_limit(limit) do
    min(non_negative_integer(limit) || @default_subgroup_limit, @max_subgroup_limit)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp string_param(value, _default) when is_binary(value), do: value
  defp string_param(_value, default), do: default
end
