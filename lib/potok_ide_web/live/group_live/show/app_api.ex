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

  A vote is not like that: it can be final. So the app only reads polls, and the
  voting and the form open on the page itself, over the app (`open_poll`,
  `open_poll_form`).

  Values in a collection (`collection` on `insert_value` and `list_values`, and
  the calls after them) go through `PotokIde.Social.AppData`, under the rules
  the app's editors keep in its config: who writes, who reads all and who only
  their own, and what a value may carry. A non-member of a public group gets
  there too when a rule is public.

  A map (`map_config`, `list_places`) shows the direct sub-groups the viewer
  sees that have a place (`Group.latitude`), and `create_place` adds one there:
  a group from a preset, asked of whoever may make a sub-group by hand, as the
  page's own menu asks. `show_group` opens a sub-group's description on the
  page, over the app (`GroupSheet`), where its own apps run with that group's
  rights: an app never runs another app's code.

  Reads are free, but counts and sums (`summarize_values`, `aggregate_values`)
  scan every value the app keeps and hold the page for up to five seconds, so
  they are limited per viewer (`PotokIde.RateLimit`, `:app_heavy_read`).
  """
  use Gettext, backend: PotokIdeWeb.Gettext
  use PotokIdeWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2]

  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, Rules, View}
  alias PotokIde.{MapTiles, RateLimit}
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AppData,
    AppFiles,
    Group,
    GroupPins,
    GroupPresets,
    ValueAttachment,
    ValueRules
  }

  alias PotokIdeWeb.AppFileToken
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show

  alias PotokIdeWeb.GroupLive.Show.{
    AppHost,
    Components,
    GroupSheet,
    PollForm,
    PollsState,
    RolesTab
  }

  alias PotokIdeWeb.PinIcons
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
    toggle_group_reaction share_group list_polls get_poll open_poll open_poll_form
    save_config update_value delete_value delete_values grade_value list_roles
    set_notifications ensure_file_groups file_url prepare_upload
    map_config list_places create_place show_group
  )

  # Every pin a map gets in one call; the rest waits for a map that reads by area.
  @max_places 2_000

  # A filter of a page of values, as JSON: kept small, as it is matched in SQL.
  @max_match_bytes 4_096

  # All an app may set on a group. Never `uses_api`: an app that made another
  # app would run its code for every viewer of that group.
  @child_fields ~w(name description description_format is_public inherits_members)

  def new_bucket do
    %{tokens: @write_burst, refilled_at: System.monotonic_time(:millisecond)}
  end

  defp poll_status("closed"), do: :closed
  defp poll_status("waiting"), do: :waiting
  defp poll_status(_open), do: :open

  defp poll_payload(%View{} = view) do
    %{
      id: view.poll_id,
      question: view.question,
      description: view.description,
      kind: view.kind,
      max_choices: view.max_choices,
      closes_at: view.closes_at,
      closed_at: view.closed_at,
      open: view.open?,
      secret: view.secret?,
      public: view.public?,
      can_vote: view.can_vote?,
      voted: view.voted?,
      can_see_results: view.results?,
      can_see_details: view.details?,
      can_manage: view.manage?,
      voters_count: view.voters_count,
      outcome: view.outcome,
      winner_option_id: view.winner_option_id,
      options:
        Enum.map(
          view.options,
          &%{id: &1.id, text: &1.text, votes_count: &1.votes_count, mine: &1.mine?}
        )
    }
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

  defp run("insert_value", %{"collection" => collection} = params, socket)
       when is_binary(collection) do
    %{group: group, active_alt_description: alt, current_scope: scope} = socket.assigns

    with {:ok, profile} <- signed_in(socket),
         {:ok, socket} <- take_write_token(socket) do
      case AppData.insert(profile, scope.account, group, alt, collection, params["data"]) do
        {:ok, value, _rule} -> {%{ok: true, value: present_value(value, socket)}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("list_values", %{"collection" => collection} = params, socket)
       when is_binary(collection) do
    %{current_profile: profile, group: group, active_alt_description: alt, access: access} =
      socket.assigns

    with {:ok, match} <- match_option(params["match"]),
         {:ok, rows, more?, total} <-
           AppData.list(profile, group, alt, access, collection,
             limit: non_negative_integer(params["limit"]),
             offset: non_negative_integer(params["offset"]),
             before_id: non_negative_integer(params["before_id"]),
             after_id: non_negative_integer(params["after_id"]),
             order_dir: optional_string(params["order_dir"]),
             mine: params["mine"] == true,
             match: match,
             total: params["total"] == true
           ) do
      values = Enum.map(rows, &Map.update!(&1, :content_format, fn f -> to_string(f) end))
      {%{ok: true, values: values, has_more: more?, total: total}, socket}
    else
      {:error, %{ok: false} = reply} -> {reply, socket}
      {:error, reason} -> {data_error(reason), socket}
    end
  end

  # The app's config and what the viewer may do in each collection it rules.
  # Members get it, and anyone where a rule is public, as the form must show.
  defp run("get_config", _params, socket) do
    %{
      current_profile: profile,
      group: group,
      active_alt_description: alt,
      access: access,
      current_scope: scope
    } = socket.assigns

    config = AppData.get_config(group, alt)
    rules = AppData.rules(config)

    public? =
      Enum.any?(rules, fn {c, _rule} -> ValueRules.public?(AppData.rule(config, c), group) end)

    if access.member? or public? do
      now = DateTime.utc_now(:second)
      account = scope && scope.account

      caps =
        Map.new(rules, fn {collection, _rule} ->
          {collection,
           ValueRules.caps(AppData.rule(config, collection), group, access, profile, now,
             written?: AppData.answered?(profile, account, group, alt, collection),
             notify?: AppData.notifications?(profile, group, alt, collection)
           )}
        end)

      {%{
         ok: true,
         config: AppData.config_payload(config, access),
         caps: caps,
         manage: ValueRules.manage?(access),
         can_create_groups: ValueRules.manage?(access) and Access.can?(access, :create_subgroups),
         files: files_status(config, group, access),
         visible_role_keys: (alt && alt.visible_role_keys) || [],
         viewer: %{
           signed_in: not is_nil(profile),
           member: access.member?,
           profile_id: profile && profile.id,
           username: profile && profile.username
         }
       }, socket}
    else
      {error("not_a_member", gettext("You must be a group member to access group data values.")),
       socket}
    end
  end

  # Counts over a collection's answers, for those its rule lets see them.
  defp run("summarize_values", params, socket) do
    %{group: group, active_alt_description: alt, access: access} = socket.assigns

    with :ok <- heavy_read(socket),
         {:ok, summary} <-
           AppData.summarize(group, alt, access, params["collection"],
             under: string_list(params["under"]),
             keys: string_list(params["keys"]) || [],
             score: params["score"] == true
           ) do
      {%{ok: true, summary: summary_payload(summary)}, socket}
    else
      {:error, %{ok: false} = reply} -> {reply, socket}
      {:error, reason} -> {data_error(reason), socket}
    end
  end

  # Sums over the numbers in a collection, for its full readers.
  defp run("aggregate_values", %{"collection" => collection} = params, socket)
       when is_binary(collection) do
    %{group: group, active_alt_description: alt, access: access} = socket.assigns

    with :ok <- heavy_read(socket),
         {:ok, match} <- match_option(params["match"]),
         {:ok, result} <-
           AppData.aggregate(group, alt, access, collection,
             match: match,
             group_by: params["group_by"],
             fields: params["fields"],
             under: params["under"]
           ) do
      {Map.put(result, :ok, true), socket}
    else
      {:error, %{ok: false} = reply} -> {reply, socket}
      {:error, reason} -> {data_error(reason), socket}
    end
  end

  # Sums over the numbers in values outside collections, for members, with the
  # filters of `list_values`.
  defp run("aggregate_values", params, socket) do
    with :ok <-
           require_member(
             socket,
             gettext("You must be a group member to access group data values.")
           ),
         :ok <- heavy_read(socket),
         {:ok, filters} <- value_filters(params, socket),
         {:ok, result} <-
           Social.aggregate_group_data_values(
             socket.assigns.group,
             filters ++
               [group_by: params["group_by"], fields: params["fields"], under: params["under"]]
           ) do
      {Map.put(result, :ok, true), socket}
    else
      {:error, %{ok: false} = reply} -> {reply, socket}
      {:error, reason} -> {data_error(reason), socket}
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
    with :ok <-
           require_member(
             socket,
             gettext("You must be a group member to access group data values.")
           ),
         {:ok, filters} <- value_filters(params, socket) do
      group = socket.assigns.group

      {rows, has_more?} =
        Social.list_group_data_value_rows(
          group,
          filters ++
            [
              limit: non_negative_integer(params["limit"]) |> clamp_limit(),
              offset: non_negative_integer(params["offset"]),
              after_id: non_negative_integer(params["after_id"]),
              before_id: non_negative_integer(params["before_id"]),
              order_by: optional_string(params["order_by"]),
              order_dir: optional_string(params["order_dir"])
            ]
        )

      total = if params["total"] == true, do: Social.count_group_data_value_rows(group, filters)
      values = Enum.map(rows, &Map.update!(&1, :content_format, fn f -> to_string(f) end))
      {%{ok: true, values: values, has_more: has_more?, total: total}, socket}
    else
      {:error, reply} -> {reply, socket}
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

  defp run("save_config", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt, access: access} =
      socket.assigns

    with {:ok, socket} <- take_write_token(socket) do
      case AppData.save_config(
             profile,
             group,
             alt,
             params["data"],
             non_negative_integer(params["revision"])
           ) do
        {:ok, config} ->
          {%{ok: true, config: AppData.config_payload(config, access)}, socket}

        {:error, {:conflict, current}} ->
          {%{ok: false, error: "conflict", current: AppData.config_payload(current, access)},
           socket}

        {:error, reason} ->
          {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("update_value", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, id} <- id_param(params),
         {:ok, socket} <- take_write_token(socket) do
      case AppData.update(
             profile,
             group,
             alt,
             id,
             params["data"],
             non_negative_integer(params["revision"])
           ) do
        {:ok, value, _rule} ->
          {%{ok: true, value: present_value(value, socket)}, socket}

        {:error, {:conflict, current}} ->
          {%{ok: false, error: "conflict", current: present_value(current, socket)}, socket}

        {:error, reason} ->
          {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("delete_value", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, id} <- id_param(params),
         {:ok, socket} <- take_write_token(socket) do
      case AppData.delete(profile, group, alt, id) do
        {:ok, value} -> {%{ok: true, id: value.id}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("delete_values", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, socket} <- take_write_token(socket) do
      case AppData.delete_collection(profile, group, alt, params["collection"]) do
        {:ok, count} -> {%{ok: true, count: count}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("grade_value", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, id} <- id_param(params),
         {:ok, socket} <- take_write_token(socket) do
      case AppData.grade(profile, group, alt, id, params["items"]) do
        {:ok, value, _rule} -> {%{ok: true, value: present_value(value, socket)}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  # The roles a form can name, as the group's Roles tab shows them.
  defp run("list_roles", _params, socket) do
    case require_member(
           socket,
           gettext("You must be a group member to access group data values.")
         ) do
      :ok ->
        roles =
          if socket.assigns.access.manifest, do: socket.assigns.access.manifest.roles, else: []

        {%{
           ok: true,
           roles:
             Enum.map(roles, fn role ->
               %{
                 key: role.key,
                 name: RolesTab.role_label(role),
                 builtin: role.key in ["admin", "everyone"]
               }
             end)
         }, socket}

      {:error, reply} ->
        {reply, socket}
    end
  end

  defp run("set_notifications", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, socket} <- take_write_token(socket) do
      case AppData.set_notifications(
             profile,
             group,
             alt,
             params["collection"],
             params["on"] == true
           ) do
        {:ok, on?} -> {%{ok: true, on: on?}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("ensure_file_groups", _params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, socket} <- take_write_token(socket) do
      case AppFiles.ensure_groups(profile, group, alt) do
        {:ok, files} -> {%{ok: true, files: files}, socket}
        {:error, reason} -> {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  # An address the frame can show a file by, for a viewer who may open it.
  defp run("file_url", params, socket) do
    with {:ok, id} <- id_param(params),
         %ValueAttachment{} = attachment <-
           Social.get_attachment_for_download(socket.assigns.current_profile, id) do
      {%{
         ok: true,
         url: AppFileToken.address(attachment),
         name: attachment.filename,
         type: attachment.content_type,
         size: attachment.byte_size
       }, socket}
    else
      {:error, reply} -> {reply, socket}
      _not_theirs -> {error("not_found", nil), socket}
    end
  end

  # The page's hook asks before it sends a file of the frame's, and the file
  # then arrives through the page's upload (`Show`, `:app_file`).
  defp run("prepare_upload", params, socket) do
    %{current_profile: profile, group: group, active_alt_description: alt} = socket.assigns

    with {:ok, file} <- upload_params(params),
         {:ok, socket} <- take_write_token(socket) do
      prepared =
        if params["image"] == true do
          AppFiles.prepare_image(profile, group, alt, file)
        else
          prepare_value_upload(profile, group, alt, params, file)
        end

      case prepared do
        {:ok, upload} ->
          ref = Integer.to_string(System.unique_integer([:positive]))
          {%{ok: true, ref: ref}, assign(socket, :app_upload, Map.put(upload, :ref, ref))}

        {:error, reason} ->
          {data_error(reason), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  # An app runs for every viewer and with the viewer's sight, so it reaches
  # below its group only through what that viewer can see, one level under a
  # direct sub-group.
  defp run("list_subgroups", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with name when is_binary(name) <- params["name"],
         %Group{} = parent <- Social.get_visible_child_group_by_name(group, profile, name),
         {:ok, reply} <- subgroups_reply(parent, profile, params) do
      {reply, socket}
    else
      {:error, reply} -> {reply, socket}
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

    in_app? = params["in_app"] == true

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = target <- share_target(group, profile, id, in_app?) do
      {%{ok: true},
       AppHost.push(socket, "app_share_link", %{url: shared_url(socket, target, in_app?)})}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  # What the rules show this viewer of the polls of this group, and no more.
  defp run("list_polls", params, socket) do
    %{group: group, access: access, current_profile: profile, current_scope: scope} =
      socket.assigns

    poll_scope = if access.member?, do: {:groups, [group.id]}, else: {:public_of, group.id}

    page =
      Polls.overview(profile, scope.account, poll_scope,
        status: poll_status(params["status"]),
        before_id: non_negative_integer(params["before_id"])
      )

    {%{ok: true, polls: Enum.map(page.rows, &poll_payload(&1.view)), has_more: page.more?},
     socket}
  end

  defp run("get_poll", params, socket) do
    %{current_profile: profile, current_scope: scope} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Poll{} = poll <- Polls.get_poll(id),
         true <- poll.group_id == socket.assigns.group.id,
         %{scope: :full} = view <- Polls.view_of(poll, profile, scope.account) do
      {%{ok: true, poll: poll_payload(view)}, socket}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  defp run("open_poll", params, socket) do
    with id when is_integer(id) <- non_negative_integer(params["id"]),
         {:ok, socket} <- PollsState.open_dialog(socket, id) do
      {%{ok: true}, socket}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  defp run("open_poll_form", _params, socket) do
    case PollForm.open_new(socket) do
      %{assigns: %{poll_form: nil}} = socket -> {error("forbidden", nil), socket}
      socket -> {%{ok: true}, socket}
    end
  end

  defp run("get_group", _params, socket) do
    {%{ok: true, group: group_payload(socket.assigns)}, socket}
  end

  # What a map needs before its first pin: where tiles come from, where it
  # opens, how every pin looks and what the viewer may do on it.
  defp run("map_config", _params, socket) do
    %{access: access} = socket.assigns

    {%{
       ok: true,
       tiles: %{
         url: MapTiles.url_template(PotokIdeWeb.Endpoint.url() <> "/tiles"),
         attribution: MapTiles.attribution(),
         max_zoom: MapTiles.max_zoom()
       },
       default_bounds: MapTiles.default_bounds(),
       pins: PinIcons.catalogue(),
       place_kinds: Enum.map(GroupPresets.keys(), &%{key: &1, title: PinIcons.kind_label(&1)}),
       can_create_places: places_maker?(access),
       can_edit_view: manages_children?(access)
     }, socket}
  end

  defp run("list_places", _params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with :ok <- heavy_read(socket) do
      {places, truncated?} = Social.list_visible_placed_children(group, profile, @max_places)

      {%{ok: true, places: Enum.map(places, &place_payload/1), truncated: truncated?}, socket}
    else
      {:error, reply} -> {reply, socket}
    end
  end

  defp run("create_place", params, socket) do
    %{group: group, current_profile: profile, access: access} = socket.assigns

    with :ok <- require_places_maker(access),
         {:ok, preset, choices, place} <- place_params(params, group),
         :ok <- place_turn(profile),
         {:ok, socket} <- take_write_token(socket) do
      case Social.create_group_from_preset(profile, group, preset, choices, place) do
        {:ok, %{group: created}} ->
          {%{ok: true, place: place_payload(created)}, socket}

        {:error, %Ecto.Changeset{}} ->
          {error("invalid_place", gettext("Could not save the group.")), socket}

        {:error, _not_allowed} ->
          {error("forbidden", gettext("Your roles in this group do not allow that.")), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  # A sheet opens no sheet of its own: one over the other would lose the way back.
  defp run("show_group", _params, %{assigns: %{in_group_sheet: true}} = socket) do
    {error("unavailable", nil), socket}
  end

  defp run("show_group", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with id when is_integer(id) <- non_negative_integer(params["id"]),
         %Group{} = child <- Social.get_visible_child_group(group, profile, id) do
      {%{ok: true}, GroupSheet.open(socket, child)}
    else
      _not_found -> {error("not_found", nil), socket}
    end
  end

  defp run("list_children", params, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with :ok <- require_child_manager(socket),
         {:ok, reply} <- subgroups_reply(group, profile, params) do
      {reply, socket}
    else
      {:error, reply} -> {reply, socket}
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
      # A story keeps the comments of its feed: apps need not know of open chats.
      attrs = Map.put(child_attrs(params), "has_public_chat", group.has_public_chat)

      Social.create_group(profile, group, attrs)
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

  defp prepare_value_upload(profile, group, alt, params, file) do
    collection = params["collection"]
    slot = params["slot"]

    if ValueRules.app_collection?(collection) and is_binary(slot),
      do: AppFiles.prepare(profile, group, alt, collection, slot, file),
      else: {:error, :invalid_files}
  end

  defp upload_params(%{"name" => name, "size" => size, "type" => type})
       when is_binary(name) and is_integer(size) and size > 0 and is_binary(type) do
    {:ok,
     %{
       name: ValueAttachment.clean_filename(name),
       size: size,
       type: ValueAttachment.clean_content_type(type)
     }}
  end

  defp upload_params(_params), do: {:error, error("invalid_files", nil)}

  defp signed_in(%{assigns: %{current_profile: nil}}),
    do: {:error, error("forbidden", gettext("Your roles in this group do not allow that."))}

  defp signed_in(%{assigns: %{current_profile: profile}}), do: {:ok, profile}

  defp id_param(params) do
    case non_negative_integer(params["id"]) do
      nil -> {:error, error("not_found", nil)}
      id -> {:ok, id}
    end
  end

  defp string_list(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list
  end

  defp string_list(_list), do: nil

  # A filter of values by what their data contains: none when absent or empty.
  # Anything else that is not a small object is refused, so a broken filter
  # never reads as "everything".
  defp match_option(nil), do: {:ok, nil}
  defp match_option(match) when is_map(match) and map_size(match) == 0, do: {:ok, nil}

  defp match_option(match) when is_map(match) do
    if byte_size(Jason.encode!(match)) <= @max_match_bytes,
      do: {:ok, match},
      else: {:error, error("invalid_match", nil)}
  end

  defp match_option(_match), do: {:error, error("invalid_match", nil)}

  # Which values outside collections a list or a sum reads.
  defp value_filters(params, socket) do
    with {:ok, match} <- match_option(params["match"]) do
      {:ok,
       [
         scope: list_scope(params["scope"], socket.assigns),
         match: match,
         search_field: optional_string(params["search_field"]),
         search_value: optional_string(params["search_value"])
       ]}
    end
  end

  # A value of a collection as the viewer may see it, by the rules of now.
  defp present_value(value, socket) do
    %{group: group, active_alt_description: alt, access: access, current_profile: profile} =
      socket.assigns

    config = AppData.get_config(group, alt)

    value
    |> Show.value_payload()
    |> ValueRules.present(
      AppData.rule(config, value.collection),
      profile && profile.id,
      access,
      AppData.key(config, value.collection)
    )
  end

  # Whether the groups that keep the app's files stand, for its editors to fix.
  defp files_status(config, group, access) do
    if ValueRules.manage?(access) do
      files = AppFiles.groups(config)

      Map.new(["public", "private"], fn target ->
        status =
          case AppFiles.file_group(files, group, target) do
            {:ok, _group} -> "ok"
            {:error, :files_exposed} -> "exposed"
            {:error, _missing} -> "missing"
          end

        {target, status}
      end)
    end
  end

  defp summary_payload(summary) do
    %{
      total: summary.total,
      keys:
        Map.new(summary.keys, fn {key, entry} ->
          {key,
           %{
             answered: entry.answered,
             rows:
               Enum.map(entry.rows, fn {row, row_entry} ->
                 %{
                   row: row,
                   answered: row_entry.answered,
                   other: row_entry.other,
                   buckets:
                     Enum.map(row_entry.buckets, fn {value, n} -> %{value: value, count: n} end)
                 }
               end)
           }}
        end),
      score: summary.score
    }
  end

  # What went wrong with a value or the config, as an app can tell its viewer.
  defp data_error(reason) do
    case reason do
      reason when reason in [:not_permitted, :role, :blocked] ->
        error("forbidden", gettext("Your roles in this group do not allow that."))

      reason when reason in [:members_only, :not_a_member] ->
        error("not_a_member", gettext("You must be a group member to access group data values."))

      :closed ->
        error("closed", gettext("This no longer takes answers."))

      :already_answered ->
        error("already_answered", gettext("You have already answered."))

      :released ->
        error("released", gettext("The scores are out, so the answer can no longer change."))

      :rate_limited ->
        error("rate_limited", gettext("Too many changes in a short time. Try again shortly."))

      :too_large ->
        error("too_large", gettext("That is too much to save."))

      :invalid_collection ->
        error("invalid_collection", nil)

      reason
      when reason in [
             :invalid_rules,
             :anonymous_uploads,
             :immediate_release_edit,
             :under_required
           ] ->
        %{ok: false, error: "invalid_rules", reason: Atom.to_string(reason)}

      :invalid_files ->
        error("invalid_files", gettext("A file is missing or does not fit."))

      :files_missing ->
        error("files_missing", gettext("The group that keeps the files is gone."))

      :files_exposed ->
        error("files_exposed", gettext("The group for private files is no longer closed."))

      reason
      when reason in [
             :not_found,
             :no_config,
             :not_scored,
             :invalid_summary,
             :invalid_aggregate,
             :invalid_match
           ] ->
        error(Atom.to_string(reason), nil)

      :timeout ->
        error("timeout", gettext("Counting took too long. Try narrowing it down."))

      _other ->
        error("invalid_value", gettext("Could not save the data value."))
    end
  end

  defp share_target(group, profile, id, true), do: group_below(group, profile, id)
  defp share_target(group, profile, id, false), do: reachable_group(group, profile, id)

  # The app itself, open on that group (`linkGroup`). Guests get the card of the
  # group from `PublicPreview` all the same.
  defp shared_url(%{assigns: %{group: group, active_alt_description: alt}}, target, true) do
    query = if alt, do: [d: alt.id, at: target.id], else: [at: target.id]

    url(~p"/groups/#{group.id}/group_home?#{query}")
  end

  defp shared_url(_socket, target, false), do: url(~p"/groups/#{target.id}")

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

  # Who may make a sub-group by hand on the page (`Social.create_group/3`).
  defp places_maker?(access), do: access.member? and Access.can?(access, :create_subgroups)

  defp require_places_maker(access) do
    if places_maker?(access) do
      :ok
    else
      {:error, error("forbidden", gettext("Your roles in this group do not allow that."))}
    end
  end

  defp place_turn(profile) do
    case RateLimit.hit(:app_create_place, profile.id) do
      :ok ->
        :ok

      {:error, :rate_limited, _retry_after} ->
        {:error,
         error("rate_limited", gettext("Too many changes in a short time. Try again shortly."))}
    end
  end

  # A place is a group from a preset, with what the page's menu lets one pick
  # and its defaults, standing where the map was tapped.
  defp place_params(params, group) do
    with preset when is_binary(preset) <- params["kind"],
         true <- preset in GroupPresets.keys(),
         name when is_binary(name) <- optional_string(params["name"]),
         {:ok, lat} <- coordinate(params["lat"], 90),
         {:ok, lng} <- coordinate(params["lng"], 180),
         {:ok, pin} <- place_pin(params["pin"]) do
      choices =
        preset
        |> GroupPresets.defaults(group)
        |> Map.put("name", name)
        |> put_place_audience(params["is_public"])

      {:ok, preset, choices, %{"latitude" => lat, "longitude" => lng, "pin_icon" => pin}}
    else
      _invalid -> {:error, error("invalid_place", gettext("Could not save the group."))}
    end
  end

  defp put_place_audience(choices, is_public) when is_boolean(is_public),
    do: Map.put(choices, "is_public", is_public)

  defp put_place_audience(choices, _default), do: choices

  defp coordinate(value, bound) when is_number(value) and value >= -bound and value <= bound,
    do: {:ok, value / 1}

  defp coordinate(_value, _bound), do: :error

  defp place_pin(nil), do: {:ok, nil}

  defp place_pin(pin) when is_binary(pin),
    do: if(pin in GroupPins.keys(), do: {:ok, pin}, else: :error)

  defp place_pin(_pin), do: :error

  # A pin: where it stands, and what it shows (`GroupPins`), which a map draws
  # from `map_config`. `pin` is nil for the kind's own.
  defp place_payload(%Group{} = group) do
    %{
      id: group.id,
      name: group.name,
      lat: group.latitude,
      lng: group.longitude,
      kind: GroupPins.kind(group),
      pin: GroupPins.pin(group),
      picture_url: Avatars.group_avatar_url(group),
      is_public: group.is_public
    }
  end

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

  # Counts and sums scan every value the app keeps and hold the page while they
  # run, so a viewer gets only so many a minute, on all their pages together.
  defp heavy_read(socket) do
    key =
      case socket.assigns.current_profile do
        nil -> {:page, self()}
        profile -> profile.id
      end

    case RateLimit.hit(:app_heavy_read, key) do
      :ok ->
        :ok

      {:error, :rate_limited, _retry_after} ->
        {:error,
         error("rate_limited", gettext("Too many requests in a short time. Try again shortly."))}
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
      everyone_creates_subgroups: Access.everyone_can?(access, :create_subgroups),
      can_start_polls: Rules.can_create?(access, group)
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
      app_description: if(group.uses_api, do: PublicPreview.own_description(group)),
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

  # `around_id` starts from a group that can lie any number of pages down.
  defp subgroups_reply(parent, profile, params) do
    with {:ok, page} <- subgroup_page(params) do
      {groups, has_more?, has_newer?} =
        case non_negative_integer(params["around_id"]) do
          nil ->
            {groups, has_more?} =
              Social.list_visible_child_groups_newest_first(parent, profile, page)

            {groups, has_more?, false}

          id ->
            Social.list_visible_child_groups_around(parent, profile, id, page)
        end

      {:ok,
       %{
         ok: true,
         groups: subgroup_payloads(groups, profile),
         has_more: has_more?,
         has_newer: has_newer?
       }}
    end
  end

  # A period comes as moments, not days: only the app knows its viewer's zone.
  defp subgroup_page(params) do
    with {:ok, from} <- moment(params["from"]),
         {:ok, to} <- moment(params["to"]) do
      {:ok,
       [
         limit: subgroup_limit(params["limit"]),
         before_id: non_negative_integer(params["before_id"]),
         from: from,
         to: to
       ]}
    end
  end

  defp moment(nil), do: {:ok, nil}

  defp moment(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, moment, _offset} -> {:ok, moment}
      {:error, _reason} -> {:error, error("invalid_date", nil)}
    end
  end

  defp moment(_value), do: {:error, error("invalid_date", nil)}

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
