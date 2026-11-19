defmodule PotokIdeWeb.GroupLive.Show.ProcessEditorState do
  @moduledoc """
  The process editor of the group's Processes tab: drawing a process in
  Potok (`PotokIde.Social.DrawnProcesses`), or looking at the drawing of one
  an app writes into its rules.

  The page holds the drawing (`process_editor`): its graph, with a key on
  every flow (`Processes.GraphEdit`), and where its steps stand on a wide
  screen. Every change goes through `GraphEdit`, is checked as a save would
  check it (`Graph.normalize/1`, the group's roles), and goes to the canvas
  (`ProcessCanvas` in `assets/js/process_canvas.js`) with every text on it,
  so the canvas has no text of its own. The step or flow picked on the
  canvas is edited in a form (`process_editor_form`).

  A drawing is drawn in today's language (`Graph` `"v" => 2`): one kept in
  the first is turned into it as its editor opens it (`Graph.upgrade/1`),
  and asks to be saved. What its texts and conditions say is checked as it
  is drawn (`Processes.Check`), against what its trigger hands a run and
  the entities of the group.

  With nothing picked, the panel shows the data of the process (`data/1`):
  what set it going, its variables, which are listed and changed there,
  what its steps bring back, and the entities of the group.

  `GroupLive.Show` delegates every `"process_editor_*"` event here; the URL
  (`?process=new`, `?process=12`) opens the editor (`ProcessesState`).
  """

  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2, put_flash: 3]

  alias PotokIde.Processes.{
    Check,
    Graph,
    GraphEdit,
    GroupEntities,
    GroupEntity,
    GroupFields,
    Scope,
    Triggers,
    Types
  }

  alias PotokIde.Repo
  alias PotokIde.Social.{AppData, AppProcess, DrawnProcesses, ValueRules}
  alias PotokIdeWeb.GroupLive.Show.RolesTab

  @canvas "process-canvas"
  @units %{"minutes" => 60, "hours" => 3_600, "days" => 86_400, "weeks" => 604_800}

  def init(socket),
    do: assign(socket, process_editor: nil, process_editor_form: nil, process_editor_meta: nil)

  ## Opening and closing

  @doc "Opens the editor on `:new`, on the process `id`, or closes it on nil."
  def open(socket, nil), do: init(socket)

  def open(socket, :new) do
    %{group: group, access: access} = socket.assigns

    case {ValueRules.manage?(access), DrawnProcesses.apps(group)} do
      {true, apps} ->
        # On a new value of an app, where the group has one; by hand otherwise.
        {trigger, alt_id} =
          case apps do
            [app | _] -> {"value", app.alt_id}
            [] -> {"manual", nil}
          end

        collections = if apps == [], do: [], else: DrawnProcesses.collections(group, alt_id)
        collection = List.first(collections)

        editor = %{
          id: nil,
          source: :new,
          editable?: true,
          active?: false,
          name: gettext("New process"),
          trigger: trigger,
          trigger_config: default_config(trigger, socket),
          alt_id: alt_id,
          collection: collection,
          apps: apps,
          collections: collections,
          graph: Map.put(GraphEdit.new(), "zone", zone(socket)),
          layout: %{},
          revision: nil,
          dirty?: true,
          upgraded?: false,
          stale?: false,
          public?: false,
          selected: nil,
          inserting: nil,
          error: nil,
          conflict: nil,
          fields: DrawnProcesses.fields_for(group, trigger, alt_id, collection),
          callable: DrawnProcesses.callable(group),
          group_fields: GroupFields.names(group),
          signals: DrawnProcesses.signals(group),
          related_hearers: DrawnProcesses.related_hearers(group),
          entities: GroupEntities.list(group),
          entry_entity: nil,
          return_entity: nil,
          signal_entities: DrawnProcesses.signal_entities(group),
          data?: false
        }

        socket |> assign(:process_editor, editor) |> refresh(reset: true)

      {false, _apps} ->
        socket
        |> put_flash(:error, gettext("Only the app's editors draw processes."))
        |> close_url()
    end
  end

  def open(socket, id) when is_integer(id) do
    %{group: group, access: access} = socket.assigns
    manage? = ValueRules.manage?(access)

    case Repo.get_by(AppProcess, id: id, group_id: group.id) do
      %AppProcess{drawn: true} = row when row.active or manage? ->
        drawing = drawing(row, manage?, socket)

        editor = %{
          id: row.id,
          source: :drawn,
          editable?: manage?,
          active?: row.active,
          name: row.name,
          trigger: row.trigger,
          trigger_config: row.trigger_config,
          alt_id: row.alt_description_id,
          collection: row.collection,
          apps: [],
          collections: [],
          graph: drawing.graph,
          layout: drawing.layout,
          revision: row.lock_version,
          dirty?: drawing.upgraded?,
          upgraded?: drawing.upgraded?,
          # Saved with things as they were: saving it again brings it in step.
          stale?: manage? and DrawnProcesses.stale?(row, group),
          public?: row.is_public,
          selected: nil,
          inserting: nil,
          error: nil,
          conflict: nil,
          fields:
            if(manage?,
              do:
                DrawnProcesses.fields_for(
                  group,
                  row.trigger,
                  row.alt_description_id,
                  row.collection,
                  row.trigger_config
                ),
              else: []
            ),
          callable: DrawnProcesses.callable(group),
          group_fields: if(manage?, do: GroupFields.names(group), else: []),
          signals: if(manage?, do: DrawnProcesses.signals(group), else: %{}),
          related_hearers: if(manage?, do: DrawnProcesses.related_hearers(group), else: %{}),
          entities: if(manage?, do: GroupEntities.list(group), else: []),
          entry_entity: row.entry_entity_id,
          return_entity: row.return_entity_id,
          signal_entities:
            if(manage?, do: DrawnProcesses.signal_entities(group, row.id), else: %{}),
          data?: false
        }

        socket |> assign(:process_editor, editor) |> refresh(reset: true)

      %AppProcess{drawn: false, active: true} = row ->
        graph =
          group
          |> AppData.get_config(row.alt_description_id)
          |> AppData.rules()
          |> get_in([row.collection, "process", "graph"])

        editor = %{
          id: row.id,
          source: :app,
          editable?: false,
          active?: true,
          name: row.name,
          trigger: "value",
          trigger_config: %{},
          alt_id: row.alt_description_id,
          collection: row.collection,
          apps: [],
          collections: [],
          graph: if(graph, do: GraphEdit.with_keys(graph), else: GraphEdit.new()),
          layout: %{},
          revision: nil,
          dirty?: false,
          upgraded?: false,
          stale?: false,
          public?: false,
          selected: nil,
          inserting: nil,
          error: nil,
          conflict: nil,
          fields: [],
          callable: [],
          group_fields: [],
          signals: %{},
          entities: [],
          entry_entity: nil,
          return_entity: nil,
          signal_entities: %{},
          data?: false
        }

        socket |> assign(:process_editor, editor) |> refresh(reset: true)

      _gone_or_hidden ->
        socket |> put_flash(:error, gettext("That process is not here.")) |> close_url()
    end
  end

  defp close_url(socket),
    do: socket |> init() |> push_patch(to: ~p"/groups/#{socket.assigns.group.id}/processes")

  # The drawing of a saved process as its editor draws on it: in today's
  # language (`Graph.upgrade/1`), with its steps where they stood. One kept
  # in the first language is changed by that alone, so it asks to be saved.
  # Whoever only looks at a drawing sees it as it is kept.
  defp drawing(%AppProcess{} = row, true, socket) do
    {graph, ids} = Graph.upgrade(row.graph)
    places = (row.layout || %{})["nodes"] || %{}

    %{
      graph:
        graph
        |> Map.put_new("zone", row.trigger_config["time_zone"] || zone(socket))
        |> GraphEdit.with_keys(),
      layout: Map.new(places, fn {id, place} -> {Map.get(ids, id, id), place} end),
      upgraded?: row.graph["v"] != 2
    }
  end

  defp drawing(%AppProcess{} = row, false, _socket) do
    %{
      graph: GraphEdit.with_keys(row.graph),
      layout: (row.layout || %{})["nodes"] || %{},
      upgraded?: false
    }
  end

  # The time zone a new drawing reads days and hours in: its editor's.
  defp zone(socket), do: socket.assigns[:calendar_time_zone] || "Etc/UTC"

  ## Events

  def handle_event(_event, _params, %{assigns: %{process_editor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("process_editor_close", _params, socket), do: {:noreply, close_url(socket)}

  def handle_event("process_editor_select", params, socket) do
    selected =
      cond do
        is_binary(params["node"]) -> {:node, params["node"]}
        is_binary(params["flow"]) -> {:flow, params["flow"]}
        true -> nil
      end

    {:noreply,
     socket
     |> update_editor(&%{&1 | selected: selected, inserting: nil, data?: false})
     |> refresh()}
  end

  def handle_event("process_editor_deselect", _params, socket) do
    {:noreply,
     socket
     |> update_editor(&%{&1 | selected: nil, inserting: nil, data?: false})
     |> refresh()}
  end

  # The data of the process, which a wide screen shows beside the drawing
  # whenever nothing is picked, as a sheet on a phone.
  def handle_event("process_editor_data", _params, socket) do
    {:noreply,
     socket
     |> update_editor(&%{&1 | selected: nil, inserting: nil, data?: true})
     |> refresh()}
  end

  def handle_event(event, params, %{assigns: %{process_editor: %{editable?: true}}} = socket),
    do: editing(event, params, socket)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp editing("process_editor_insert_menu", %{"flow" => key}, socket),
    do: {:noreply, socket |> update_editor(&%{&1 | inserting: key, selected: nil}) |> refresh()}

  defp editing("process_editor_insert_cancel", _params, socket),
    do: {:noreply, socket |> update_editor(&%{&1 | inserting: nil}) |> refresh()}

  defp editing("process_editor_insert", %{"kind" => kind}, socket) do
    editor = socket.assigns.process_editor

    case GraphEdit.insert(editor.graph, editor.inserting, kind, defaults(socket)) do
      {:ok, graph} ->
        new_id = new_node(editor.graph, graph)
        graph = carrying(graph, new_id, editor)

        {:noreply,
         socket
         |> changed(graph)
         |> update_editor(&%{&1 | inserting: nil, selected: new_id && {:node, new_id}})
         |> refresh()}

      {:error, _reason} ->
        {:noreply, socket |> update_editor(&%{&1 | inserting: nil}) |> refresh()}
    end
  end

  defp editing("process_editor_add_branch", %{"node" => id}, socket) do
    graph_change(socket, &GraphEdit.add_branch(&1, id, defaults(socket)))
  end

  defp editing("process_editor_remove_flow", %{"flow" => key}, socket) do
    socket = update_editor(socket, &%{&1 | selected: nil})
    graph_change(socket, &GraphEdit.delete_flow(&1, key))
  end

  defp editing("process_editor_delete", _params, socket) do
    editor = socket.assigns.process_editor

    case editor.selected do
      {:node, id} ->
        case GraphEdit.delete_node(editor.graph, id) do
          {:ok, graph, removed} ->
            {:noreply,
             socket
             |> changed(graph)
             |> update_editor(&%{&1 | selected: nil, layout: Map.drop(&1.layout, removed)})
             |> removed_flash(removed)
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, refusal(reason))}
        end

      {:flow, key} ->
        socket = update_editor(socket, &%{&1 | selected: nil})
        graph_change(socket, &GraphEdit.delete_flow(&1, key))

      nil ->
        {:noreply, socket}
    end
  end

  defp editing("process_editor_connect", %{"from" => from, "to" => to}, socket) do
    graph_change(socket, &GraphEdit.connect(&1, from, to, defaults(socket)))
  end

  defp editing("process_editor_move", %{"positions" => positions}, socket)
       when is_map(positions) do
    editor = socket.assigns.process_editor
    ids = MapSet.new(editor.graph["nodes"], & &1["id"])

    layout =
      for {id, [x, y]} <- positions,
          MapSet.member?(ids, id),
          is_number(x) and is_number(y),
          into: %{},
          do: {id, [round(x), round(y)]}

    {:noreply,
     socket
     |> update_editor(&%{&1 | layout: layout, dirty?: true})
     |> refresh()}
  end

  defp editing("process_editor_relayout", _params, socket) do
    {:noreply,
     socket
     |> update_editor(&%{&1 | layout: %{}, dirty?: true})
     |> refresh(reset: true)}
  end

  defp editing("process_editor_meta", %{"meta" => meta}, socket) do
    editor = socket.assigns.process_editor
    group = socket.assigns.group
    name = meta["name"] || editor.name

    editor =
      if editor.source == :new,
        do: new_target(editor, meta, group, socket),
        else: editor

    {:noreply,
     socket
     |> assign(:process_editor, %{
       editor
       | name: name,
         dirty?: editor.dirty? or name != editor.name
     })
     |> refresh()}
  end

  defp editing("process_editor_change", %{"element" => attrs}, socket) do
    case socket.assigns.process_editor.selected do
      {:node, id} -> graph_change(socket, &change_node(&1, id, attrs, socket))
      _other -> {:noreply, socket}
    end
  end

  defp editing("process_editor_change", %{"flow" => attrs}, socket) do
    case socket.assigns.process_editor.selected do
      {:flow, key} -> graph_change(socket, &change_flow(&1, key, attrs), keep_selection: true)
      _other -> {:noreply, socket}
    end
  end

  defp editing("process_editor_trigger", %{"trigger" => params}, socket) when is_map(params) do
    editor = socket.assigns.process_editor
    config = trigger_params(editor.trigger, params, editor.trigger_config)

    # The entity the process takes, where its trigger lets it take one.
    entity =
      if Map.has_key?(params, "entity") and Triggers.typed?(editor.trigger),
        do: parse_id(params["entity"]),
        else: editor.entry_entity

    # The entity it hands back, for one others call.
    returns =
      if Map.has_key?(params, "returns") and editor.trigger == "process",
        do: parse_id(params["returns"]),
        else: editor[:return_entity]

    fields =
      if editor.trigger in ~w(process signal),
        do: trigger_fields(socket.assigns.group, editor.trigger, config),
        else: editor.fields

    # Whether the groups above and below may call it, for one others call.
    public? =
      if Map.has_key?(params, "public") and editor.trigger == "process",
        do: params["public"] == "true",
        else: editor.public?

    {:noreply,
     socket
     |> update_editor(
       &%{
         &1
         | trigger_config: config,
           entry_entity: entity,
           return_entity: returns,
           fields: fields,
           public?: public?,
           dirty?: true
       }
     )
     |> refresh()}
  end

  # The fields a called process takes become an entity of the group, with a
  # text for each, which the process then takes instead.
  defp editing("process_editor_entity_from_fields", _params, socket) do
    %{group: group, access: access, process_editor: editor} = socket.assigns

    names =
      case Triggers.normalize("process", editor.trigger_config) do
        {:ok, %{"fields" => names}} -> names
        _not_set_right -> []
      end

    cond do
      editor.trigger != "process" or names == [] ->
        {:noreply, socket}

      not Enum.all?(names, &Types.name?/1) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("An attribute is named with letters, digits and _, starting with a letter.")
         )}

      true ->
        attributes = for name <- names, do: %{"name" => name, "type" => "text"}
        attrs = %{"name" => fresh_entity_name(editor), "attributes" => attributes}

        case GroupEntities.create(group, access, attrs) do
          {:ok, entity} ->
            {:noreply,
             socket
             |> update_editor(
               &%{
                 &1
                 | entities: GroupEntities.list(group),
                   entry_entity: entity.id,
                   trigger_config: %{"fields" => []},
                   fields: Triggers.fields("process", %{}),
                   dirty?: true
               }
             )
             |> refresh()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not make the entity."))}
        end
    end
  end

  # The list a loop goes through, picked by its name.
  defp editing("process_editor_insert_field", %{"target" => "list_expr", "path" => path}, socket) do
    case socket.assigns.process_editor.selected do
      {:node, id} ->
        graph_change(socket, &GraphEdit.update_node(&1, id, %{"list" => path}))

      _other ->
        {:noreply, socket}
    end
  end

  # A name put into what a step sets, where that is an expression.
  defp editing("process_editor_insert_field", %{"target" => "value_expr", "path" => path}, socket) do
    case socket.assigns.process_editor.selected do
      {:node, id} ->
        graph_change(socket, fn graph ->
          current = Graph.node(graph, id)["value"]
          GraphEdit.update_node(graph, id, %{"value" => put_name(current, path)})
        end)

      _other ->
        {:noreply, socket}
    end
  end

  defp editing("process_editor_insert_field", %{"target" => target, "path" => path}, socket)
       when target in ["text", "name", "value", "intro"] do
    case socket.assigns.process_editor.selected do
      {:node, id} ->
        graph_change(socket, fn graph ->
          current = Graph.node(graph, id)[target] || ""
          GraphEdit.update_node(graph, id, %{target => put_field(current, path)})
        end)

      _other ->
        {:noreply, socket}
    end
  end

  # A name put into what a form starts with in one attribute: in braces where
  # that is written as a text.
  defp editing(
         "process_editor_insert_field",
         %{"target" => "form_values." <> name, "path" => path},
         socket
       ) do
    editor = socket.assigns.process_editor

    case editor.selected do
      {:node, id} ->
        graph_change(socket, fn graph ->
          node = Graph.node(graph, id)
          values = node["values"] || %{}
          put = if form_value_textual?(editor, node, name), do: &put_field/2, else: &put_name/2

          GraphEdit.update_node(graph, id, %{
            "values" => Map.put(values, name, put.(values[name], path))
          })
        end)

      _other ->
        {:noreply, socket}
    end
  end

  # A name put into what an end hands back in one attribute: in braces where
  # that is written as a text.
  defp editing(
         "process_editor_insert_field",
         %{"target" => "end_values." <> name, "path" => path},
         socket
       ) do
    editor = socket.assigns.process_editor

    case {editor.selected, return_entity(editor)} do
      {{:node, id}, %GroupEntity{} = entity} ->
        textual? = textual_attribute?(GroupEntities.definition(entity)["attributes"], name)

        graph_change(socket, fn graph ->
          values = Graph.node(graph, id)["values"] || %{}
          put = if textual?, do: &put_field/2, else: &put_name/2

          GraphEdit.update_node(graph, id, %{
            "values" => Map.put(values, name, put.(values[name], path))
          })
        end)

      _other ->
        {:noreply, socket}
    end
  end

  # A name put into what a signal carries for one field, or one attribute
  # of its entity: in braces where that is written as a text.
  defp editing(
         "process_editor_insert_field",
         %{"target" => "signal_fields." <> index, "path" => path},
         socket
       ) do
    editor = socket.assigns.process_editor

    with {:node, id} <- editor.selected,
         {i, ""} <- Integer.parse(index) do
      graph_change(socket, fn graph ->
        node = Graph.node(graph, id)
        fields = node["fields"] || []

        case Enum.at(fields, i) do
          %{} = field ->
            put =
              if textual_field?(editor, node, field["name"]),
                do: &put_field/2,
                else: &put_name/2

            field = Map.put(field, "value", put.(field["value"], path))
            GraphEdit.update_node(graph, id, %{"fields" => List.replace_at(fields, i, field)})

          nil ->
            {:ok, graph}
        end
      end)
    else
      _other -> {:noreply, socket}
    end
  end

  # A name put into what a call hands over for one attribute: in braces
  # where that is written as a text, as it is where it is an expression.
  defp editing(
         "process_editor_insert_field",
         %{"target" => "fields." <> name, "path" => path},
         socket
       ) do
    editor = socket.assigns.process_editor

    case editor.selected do
      {:node, id} ->
        graph_change(socket, fn graph ->
          node = Graph.node(graph, id)
          fields = node["fields"] || %{}

          put =
            if textual_field?(editor, node, name), do: &put_field/2, else: &put_name/2

          if Map.has_key?(fields, name),
            do:
              GraphEdit.update_node(graph, id, %{
                "fields" => Map.put(fields, name, put.(fields[name], path))
              }),
            else: {:ok, graph}
        end)

      _other ->
        {:noreply, socket}
    end
  end

  # The variables as their form lists them, kept as typed: the drawing's
  # check says what is wrong with one.
  defp editing("process_editor_variables", %{"variables" => rows}, socket) when is_map(rows) do
    graph_change(socket, &{:ok, GraphEdit.put_variables(&1, variable_rows(rows))})
  end

  defp editing("process_editor_var_add", _params, socket) do
    graph_change(socket, fn graph ->
      variables = graph["variables"] || []

      if length(variables) < 30 do
        variable = %{"name" => fresh_variable(graph), "type" => "text", "list" => false}
        {:ok, GraphEdit.put_variables(graph, variables ++ [variable])}
      else
        {:error, :too_many}
      end
    end)
  end

  defp editing("process_editor_var_remove", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {i, ""} ->
        graph_change(
          socket,
          &{:ok, GraphEdit.put_variables(&1, List.delete_at(&1["variables"] || [], i))}
        )

      _other ->
        {:noreply, socket}
    end
  end

  # A name put into what a condition asks, which is an expression.
  defp editing("process_editor_insert_field", %{"target" => "expr", "path" => path}, socket) do
    case socket.assigns.process_editor.selected do
      {:flow, key} ->
        graph_change(
          socket,
          fn graph ->
            case GraphEdit.flow(graph, key) do
              %{"condition" => %{"expr" => current}} ->
                GraphEdit.update_condition(graph, key, %{"expr" => put_name(current, path)})

              _other ->
                {:ok, graph}
            end
          end,
          keep_selection: true
        )

      _other ->
        {:noreply, socket}
    end
  end

  defp editing("process_editor_add_signal_field", _params, socket) do
    case socket.assigns.process_editor.selected do
      {:node, id} ->
        graph_change(socket, fn graph ->
          fields = Graph.node(graph, id)["fields"] || []
          name = "#{gettext("field")}#{length(fields) + 1}"

          if length(fields) < 10,
            do:
              GraphEdit.update_node(graph, id, %{
                "fields" => fields ++ [%{"name" => name, "value" => ""}]
              }),
            else: {:error, :too_many}
        end)

      _other ->
        {:noreply, socket}
    end
  end

  defp editing("process_editor_remove_signal_field", %{"index" => index}, socket) do
    with {:node, id} <- socket.assigns.process_editor.selected,
         {i, ""} <- Integer.parse(to_string(index)) do
      graph_change(socket, fn graph ->
        fields = Graph.node(graph, id)["fields"] || []
        GraphEdit.update_node(graph, id, %{"fields" => List.delete_at(fields, i)})
      end)
    else
      _other -> {:noreply, socket}
    end
  end

  defp editing("process_editor_save", _params, socket), do: {:noreply, save(socket)}

  defp editing("process_editor_activate", _params, socket),
    do: {:noreply, switch(socket, &DrawnProcesses.activate/3, gettext("The process is on."))}

  defp editing("process_editor_deactivate", _params, socket),
    do: {:noreply, switch(socket, &DrawnProcesses.deactivate/3, gettext("The process is off."))}

  defp editing("process_editor_destroy", _params, socket) do
    %{group: group, current_profile: profile, process_editor: editor} = socket.assigns

    case editor.id && DrawnProcesses.delete(profile, group, editor.id) do
      {:ok, _row} ->
        {:noreply, socket |> put_flash(:info, gettext("The process is deleted.")) |> close_url()}

      {:error, {:in_use, _name} = reason} ->
        {:noreply, put_flash(socket, :error, refusal(reason))}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the process."))}
    end
  end

  defp editing("process_editor_take_theirs", _params, socket) do
    case socket.assigns.process_editor.conflict do
      %AppProcess{} = row ->
        drawing = drawing(row, true, socket)

        {:noreply,
         socket
         |> update_editor(fn editor ->
           %{
             editor
             | name: row.name,
               graph: drawing.graph,
               layout: drawing.layout,
               revision: row.lock_version,
               active?: row.active,
               dirty?: drawing.upgraded?,
               upgraded?: drawing.upgraded?,
               stale?: DrawnProcesses.stale?(row, socket.assigns.group),
               public?: row.is_public,
               conflict: nil,
               selected: nil
           }
         end)
         |> refresh(reset: true)}

      nil ->
        {:noreply, socket}
    end
  end

  defp editing("process_editor_keep_mine", _params, socket) do
    case socket.assigns.process_editor.conflict do
      %AppProcess{lock_version: revision} ->
        {:noreply,
         socket
         |> update_editor(&%{&1 | revision: revision, conflict: nil})
         |> save()}

      nil ->
        {:noreply, socket}
    end
  end

  defp editing(_event, _params, socket), do: {:noreply, socket}

  # A new signal that goes with an entity carries its attributes from the start.
  defp carrying(graph, id, editor) do
    case Graph.node(graph, id) do
      %{"action" => "signal", "entity" => entity} = node when is_integer(entity) ->
        {:ok, graph} = GraphEdit.update_node(graph, id, signal_attrs(node, %{}, editor))
        graph

      _other ->
        graph
    end
  end

  # The trigger's settings from its form, kept as typed until a save
  # normalizes them (`Triggers.normalize/2`); the time zone stays.
  defp trigger_params("message", params, _config),
    do: %{"words" => params["words"] || "", "role" => blank_nil(params["role"])}

  defp trigger_params("subgroup", params, _config), do: %{"placed" => params["placed"] == "true"}

  defp trigger_params("schedule", params, config) do
    %{
      "every" => params["every"] || config["every"],
      "weekdays" => List.wrap(params["weekdays"]) |> Enum.reject(&(&1 == "")),
      "day" => params["day"] || config["day"],
      "time" => params["time"] || config["time"],
      "time_zone" => config["time_zone"]
    }
  end

  defp trigger_params("manual", params, _config),
    do: %{"roles" => List.wrap(params["roles"]) |> Enum.reject(&(&1 == ""))}

  defp trigger_params("process", params, _config), do: %{"fields" => params["fields"] || ""}

  defp trigger_params("signal", params, _config) do
    %{"name" => params["name"] || ""}
    |> then(&if(params["related"] == "true", do: Map.put(&1, "related", true), else: &1))
  end

  defp trigger_params(_trigger, _params, config), do: config

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp put_field(current, path) do
    current = current || ""
    joiner = if current == "" or String.ends_with?(current, " "), do: "", else: " "
    current <> joiner <> "{{#{path}}}"
  end

  # The rows of the variables' form, in its order. Options come as one
  # text, as an entity's attribute takes them.
  defp variable_rows(rows) do
    rows
    |> Enum.flat_map(fn {i, row} ->
      case Integer.parse(i) do
        {i, ""} when is_map(row) -> [{i, variable_row(row)}]
        _other -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp variable_row(row) do
    %{
      "name" => row["name"] || "",
      "type" => row["type"] || "text",
      "list" => row["list"] == "true"
    }
    |> maybe_put("options", row["options"] && split_options(row["options"]))
    |> maybe_put("entity", parse_id(row["entity"]))
    |> maybe_put("initial", row["initial"])
  end

  defp split_options(text) do
    text
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # A name no step and no variable of the drawing has yet.
  defp fresh_variable(graph) do
    taken =
      MapSet.new(
        Enum.map(graph["nodes"], & &1["id"]) ++ Enum.map(graph["variables"] || [], & &1["name"])
      )

    base = gettext("variable")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&"#{base}#{&1}")
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  # In an expression a name stands as it is; it takes the place of the
  # `true` a new condition starts with.
  defp put_name(current, path) do
    case String.trim(current || "") do
      blank when blank in ["", "true"] -> path
      current -> current <> " " <> path
    end
  end

  # The fields a trigger gives, from its settings as typed so far.
  defp trigger_fields(group, trigger, config) do
    case Triggers.normalize(trigger, config) do
      {:ok, config} -> DrawnProcesses.fields_for(group, trigger, nil, nil, config)
      {:error, _reason} -> Triggers.fields(trigger, %{})
    end
  end

  # What a new process starts on, as its editor picks: the trigger, and for a
  # new value the app and its collection.
  defp new_target(editor, meta, group, socket) do
    trigger = parse_trigger(meta["trigger"], editor)

    if trigger == "value" do
      alt_id =
        if editor.trigger == "value",
          do: parse_alt(meta["app"], editor.apps, editor.alt_id),
          else: hd(editor.apps).alt_id

      collections = DrawnProcesses.collections(group, alt_id)

      collection =
        if meta["collection"] in collections,
          do: meta["collection"],
          else: List.first(collections)

      fields =
        if editor.trigger != "value" or collection != editor.collection or
             alt_id != editor.alt_id,
           do: DrawnProcesses.fields(group, alt_id, collection),
           else: editor.fields

      %{
        editor
        | trigger: "value",
          trigger_config: %{},
          alt_id: alt_id,
          collections: collections,
          collection: collection,
          fields: fields
      }
    else
      config =
        if trigger == editor.trigger,
          do: editor.trigger_config,
          else: default_config(trigger, socket)

      %{
        editor
        | trigger: trigger,
          trigger_config: config,
          alt_id: nil,
          collection: nil,
          fields: trigger_fields(group, trigger, config)
      }
    end
  end

  # A trigger the editor may pick: on a new value only where the group has an app.
  defp parse_trigger("value", %{apps: []} = editor), do: editor.trigger

  defp parse_trigger(trigger, editor) when is_binary(trigger),
    do: if(trigger in Triggers.all(), do: trigger, else: editor.trigger)

  defp parse_trigger(_trigger, editor), do: editor.trigger

  @doc false
  # The first settings of a trigger: a schedule in the editor's time zone.
  def default_config("message", _socket), do: %{"words" => "", "role" => nil}
  def default_config("subgroup", _socket), do: %{"placed" => false}
  def default_config("manual", _socket), do: %{"roles" => ["everyone"]}
  def default_config("process", _socket), do: %{"fields" => []}
  def default_config("signal", _socket), do: %{"name" => ""}

  def default_config("schedule", socket) do
    %{
      "every" => "week",
      "weekdays" => [1],
      "day" => 1,
      "time" => "09:00",
      "time_zone" => socket.assigns[:calendar_time_zone] || "Etc/UTC"
    }
  end

  def default_config(_trigger, _socket), do: %{}

  defp parse_alt("default", _apps, _current), do: nil

  defp parse_alt(value, apps, current) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> if Enum.any?(apps, &(&1.alt_id == id)), do: id, else: current
      _other -> current
    end
  end

  defp parse_alt(_value, _apps, current), do: current

  ## Changes to the graph

  defp graph_change(socket, fun, opts \\ []) do
    editor = socket.assigns.process_editor

    case fun.(editor.graph) do
      {:ok, graph} ->
        socket = changed(socket, graph)

        socket =
          if opts[:keep_selection], do: socket, else: keep_existing_selection(socket)

        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, refusal(reason)) |> refresh()}
    end
  end

  defp changed(socket, graph),
    do: update_editor(socket, &%{&1 | graph: graph, dirty?: true})

  # A step or flow that went with the change is no longer picked.
  defp keep_existing_selection(socket) do
    update_editor(socket, fn editor ->
      case editor.selected do
        {:node, id} ->
          if Graph.node(editor.graph, id), do: editor, else: %{editor | selected: nil}

        {:flow, key} ->
          if GraphEdit.flow(editor.graph, key), do: editor, else: %{editor | selected: nil}

        nil ->
          editor
      end
    end)
  end

  # The deadline is read from the form as it came, as it is no key of the step.
  defp change_node(graph, id, params, socket) do
    node = Graph.node(graph, id)

    attrs =
      params
      |> Map.take(~w(label text in name role field op value target list item))
      |> maybe_put("admins", admins(params))
      |> maybe_put("inherits", inherits(params))
      |> maybe_put("inherit_roles", admins(%{"admins" => params["inherit_roles"]}))
      |> maybe_put("duration", duration(params["duration_amount"], params["duration_unit"]))
      |> Map.merge(call_attrs(node, params, socket.assigns.process_editor.callable))
      |> Map.merge(signal_attrs(node, params, socket.assigns.process_editor))
      |> Map.merge(assign_attrs(node, params, socket.assigns.process_editor))
      |> Map.merge(form_attrs(node, params, socket.assigns.process_editor))
      |> Map.merge(end_attrs(node, params, socket.assigns.process_editor))

    with {:ok, graph} <- GraphEdit.update_node(graph, id, attrs) do
      deadline(graph, Graph.node(graph, id), params, socket)
    end
  end

  # The entity a form asks for, who fills it in (whoever started the run, or
  # the people of a role, which its form names as `role:<key>`), what it
  # says first, and what it starts with in each attribute of that entity.
  defp form_attrs(%{"type" => "formTask"} = node, params, editor) do
    entity =
      if Map.has_key?(params, "entity"), do: parse_id(params["entity"]), else: node["entity"]

    who =
      case params["who"] do
        "role:" <> role when role != "" -> %{"by" => "role", "role" => role}
        "starter" -> %{"by" => "starter", "role" => nil}
        _as_it_is -> %{}
      end

    written =
      case params["form_values"] do
        values when is_map(values) -> Map.merge(node["values"] || %{}, values)
        _none -> node["values"] || %{}
      end

    # Another entity has other attributes: what was written for those that
    # share a name stays.
    written =
      case Enum.find(editor[:entities] || [], &(&1.id == entity)) do
        %GroupEntity{attributes: attributes} -> Map.take(written, Enum.map(attributes, & &1.name))
        nil -> written
      end

    who
    |> Map.put("entity", entity)
    |> maybe_put("intro", if(is_binary(params["intro"]), do: params["intro"]))
    |> Map.put("values", written)
  end

  defp form_attrs(_node, _params, _editor), do: %{}

  # What an end hands back, attribute by attribute of the entity the process
  # hands back: only those it has.
  defp end_attrs(%{"type" => "endEvent"} = node, params, editor) do
    case {return_entity(editor), params["end_values"]} do
      {%GroupEntity{attributes: attributes}, values} when is_map(values) ->
        written = Map.merge(node["values"] || %{}, values)
        %{"values" => Map.take(written, Enum.map(attributes, & &1.name))}

      _nothing_typed ->
        %{}
    end
  end

  defp end_attrs(_node, _params, _editor), do: %{}

  @doc "The entity the process hands back to its caller, as the group has it, or nil."
  def return_entity(editor) do
    with "process" <- editor.trigger,
         id when is_integer(id) <- editor[:return_entity] do
      Enum.find(editor[:entities] || [], &(&1.id == id))
    else
      _hands_back_nothing -> nil
    end
  end

  # A step adds to a list only while what it sets is one: with another
  # target picked, it sets again.
  defp assign_attrs(%{"action" => "assign"} = node, params, editor) do
    target = params["target"] || node["target"]
    op = params["op"] || node["op"]
    %{"op" => if(op == "append" and list_target?(editor, target), do: "append", else: "set")}
  end

  defp assign_attrs(_node, _params, _editor), do: %{}

  # The process a call starts, whether it waits, and the fields it hands
  # over: those the process takes, keeping what was typed for the same name.
  defp call_attrs(%{"type" => "callActivity"} = call, attrs, callable) do
    process = parse_id(attrs["process"]) || call["process"]
    typed = if is_map(attrs["fields"]), do: attrs["fields"], else: %{}
    kept = Map.merge(call["fields"] || %{}, typed)

    fields =
      case Enum.find(callable, &(&1.id == process)) do
        %{fields: names} -> Map.new(names, &{&1, Map.get(kept, &1, "")})
        nil -> kept
      end

    %{"process" => process, "fields" => fields}
    |> maybe_put("wait", if(is_binary(attrs["wait"]), do: attrs["wait"] == "true"))
  end

  defp call_attrs(_node, _attrs, _callable), do: %{}

  # A signal's name in small letters, and the fields it carries in the order
  # of the form; a wait's signal, and whether it is only for its subject.
  defp signal_attrs(%{"action" => "signal"} = node, params, editor) do
    rows =
      case params["signal_fields"] do
        rows when is_map(rows) ->
          rows
          |> Enum.flat_map(fn {i, row} ->
            case Integer.parse(i) do
              {i, ""} when is_map(row) ->
                [{i, %{"name" => row["name"] || "", "value" => row["value"] || ""}}]

              _other ->
                []
            end
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        _none ->
          nil
      end

    name = signal_text(params["name"])
    entity = signal_entity(node, params, name, node["name"], editor)

    # With an entity the signal carries its attributes, each keeping what
    # was written for it; with none, the fields as the form lists them.
    fields =
      case entity && Enum.find(editor[:entities] || [], &(&1.id == entity)) do
        %GroupEntity{attributes: attributes} ->
          written = Map.new(rows || node["fields"] || [], &{&1["name"], &1["value"]})

          for attribute <- attributes,
              do: %{"name" => attribute.name, "value" => written[attribute.name] || ""}

        _no_entity ->
          rows
      end

    %{"entity" => entity}
    |> maybe_put("name", name)
    |> maybe_put("fields", fields)
  end

  defp signal_attrs(%{"type" => "receiveTask"} = node, params, editor) do
    signal = signal_text(params["signal"])

    related = if is_binary(params["related"]), do: params["related"] == "true"

    # Groups around share no subject, so hearing them leaves the same subject out.
    same_subject =
      if related,
        do: false,
        else: if(is_binary(params["same_subject"]), do: params["same_subject"] == "true")

    %{"entity" => signal_entity(node, params, signal, node["signal"], editor)}
    |> maybe_put("signal", signal)
    |> maybe_put("same_subject", same_subject)
    |> maybe_put("related", related)
  end

  defp signal_attrs(_node, _params, _editor), do: %{}

  # The entity a step sends or waits for a signal with: the one its form
  # names, or, as the signal's name changes, the one those who wait for
  # that signal already expect.
  defp signal_entity(node, params, name, old_name, editor) do
    chosen =
      if Map.has_key?(params, "entity"), do: parse_id(params["entity"]), else: node["entity"]

    if is_binary(name) and name != old_name and chosen == node["entity"] do
      case Map.get(editor[:signal_entities] || %{}, name, []) do
        [expected] -> expected
        _none_or_several -> chosen
      end
    else
      chosen
    end
  end

  # Whether what a call or a signal hands over under `name` is written as a
  # text: always, unless the attribute of that name holds something else.
  defp textual_field?(editor, %{"type" => "callActivity", "process" => id}, name) do
    case Enum.find(editor.callable, &(&1.id == id)) do
      %{attributes: [_ | _] = attributes} -> textual_attribute?(attributes, name)
      _takes_fields -> true
    end
  end

  defp textual_field?(editor, %{"action" => "signal", "entity" => id}, name)
       when is_integer(id) do
    case GroupEntities.definitions(editor[:entities] || [])[to_string(id)] do
      %{"attributes" => attributes} -> textual_attribute?(attributes, name)
      _unknown -> true
    end
  end

  defp textual_field?(_editor, _node, _name), do: true

  # Whether what a form starts with in an attribute is written as a text.
  defp form_value_textual?(editor, %{"entity" => id}, name) when is_integer(id) do
    case GroupEntities.definitions(editor[:entities] || [])[to_string(id)] do
      %{"attributes" => attributes} -> textual_attribute?(attributes, name)
      _unknown -> true
    end
  end

  defp form_value_textual?(_editor, _node, _name), do: true

  defp textual_attribute?(attributes, name) do
    case Enum.find(attributes, &(&1["name"] == name)) do
      nil -> true
      attribute -> Types.textual?(Types.of(attribute))
    end
  end

  # A name for an entity made from the fields of the process, which no
  # entity of the group has yet.
  defp fresh_entity_name(editor) do
    taken = MapSet.new(editor[:entities] || [], &String.downcase(&1.name))
    base = editor.name |> String.trim() |> String.slice(0, 36)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base} #{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end

  defp signal_text(text) when is_binary(text), do: text |> String.trim() |> String.downcase()
  defp signal_text(_text), do: nil

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _other -> nil
    end
  end

  defp parse_id(_value), do: nil

  defp admins(%{"admins" => admins}) when is_list(admins),
    do: admins |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp admins(_attrs), do: nil

  defp inherits(%{"inherits" => value}) when is_binary(value), do: value == "true"
  defp inherits(_params), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deadline(graph, %{"type" => "userTask", "id" => id} = task, attrs, socket) do
    if Map.has_key?(attrs, "deadline_amount") do
      wanted = duration(attrs["deadline_amount"], attrs["deadline_unit"])

      if wanted == task["deadline"],
        do: {:ok, graph},
        else: GraphEdit.set_deadline(graph, id, wanted, %{text: reminder_text(socket)})
    else
      {:ok, graph}
    end
  end

  defp deadline(graph, %{"type" => type, "id" => id} = wait, attrs, _socket)
       when type in ~w(receiveTask formTask) do
    wanted = duration(attrs["deadline_amount"], attrs["deadline_unit"])

    if not Map.has_key?(attrs, "deadline_amount") or wanted == wait["deadline"],
      do: {:ok, graph},
      else: GraphEdit.set_deadline(graph, id, wanted)
  end

  defp deadline(graph, %{"type" => "callActivity", "wait" => true, "id" => id} = call, attrs, _s) do
    wanted = duration(attrs["deadline_amount"], attrs["deadline_unit"])

    if not Map.has_key?(attrs, "deadline_amount") or wanted == call["deadline"],
      do: {:ok, graph},
      else: GraphEdit.set_deadline(graph, id, wanted)
  end

  defp deadline(graph, _node, _attrs, _socket), do: {:ok, graph}

  @doc false
  # An ISO 8601 duration from an amount and a unit, nil when there is none.
  def duration(amount, unit) when is_binary(amount) and is_map_key(@units, unit) do
    case Integer.parse(String.trim(amount)) do
      {n, ""} when n > 0 ->
        case unit do
          "minutes" -> "PT#{n}M"
          "hours" -> "PT#{n}H"
          "days" -> "P#{n}D"
          "weeks" -> "P#{n}W"
        end

      _blank_or_wrong ->
        nil
    end
  end

  def duration(_amount, _unit), do: nil

  @doc false
  # A duration as an amount in the largest unit that holds it whole.
  def amount(nil), do: {"", "days"}

  def amount(duration) do
    seconds = Graph.seconds(duration) || 0

    Enum.find_value(["weeks", "days", "hours", "minutes"], {"", "days"}, fn unit ->
      size = @units[unit]

      if seconds > 0 and rem(seconds, size) == 0,
        do: {Integer.to_string(div(seconds, size)), unit}
    end)
  end

  defp change_flow(graph, key, attrs) do
    flow = GraphEdit.flow(graph, key)

    with {:ok, graph} <- retarget(graph, flow, attrs["to"]),
         {:ok, graph} <- outcome_name(graph, flow, attrs["outcome"]) do
      if Map.has_key?(flow, "condition") and is_binary(attrs["expr"]),
        do: GraphEdit.update_condition(graph, key, %{"expr" => attrs["expr"]}),
        else: {:ok, graph}
    end
  end

  defp retarget(graph, _flow, nil), do: {:ok, graph}
  defp retarget(graph, %{"to" => to}, to), do: {:ok, graph}
  defp retarget(graph, %{"key" => key}, "__new_end"), do: GraphEdit.retarget(graph, key, :new_end)
  defp retarget(graph, %{"key" => key}, to), do: GraphEdit.retarget(graph, key, to)

  defp outcome_name(graph, %{"outcome" => old, "from" => from}, new) when is_binary(new) do
    if String.trim(new) == "",
      do: {:ok, graph},
      else: GraphEdit.rename_outcome(graph, from, old, new)
  end

  defp outcome_name(graph, _flow, _new), do: {:ok, graph}

  defp new_node(before, graph) do
    ids = MapSet.new(before["nodes"], & &1["id"])
    Enum.find_value(graph["nodes"], &(not MapSet.member?(ids, &1["id"]) and &1["id"]))
  end

  defp removed_flash(socket, removed) when length(removed) > 1,
    do:
      put_flash(
        socket,
        :info,
        ngettext("One step went.", "%{count} steps went.", length(removed))
      )

  defp removed_flash(socket, _removed), do: socket

  # The first texts of a new step, in the editor's language.
  defp defaults(socket) do
    editor = socket.assigns.process_editor
    callee = List.first(editor.callable)
    variables = Map.get(editor.graph, "variables", [])
    signal = editor.signals |> Map.keys() |> Enum.sort() |> List.first() || gettext("ready")

    # The entity those who wait for that signal expect, where they agree.
    signal_entity =
      case Map.get(editor[:signal_entities] || %{}, signal, []) do
        [expected] -> expected
        _none_or_several -> nil
      end

    %{
      text: gettext("A new value came in."),
      name: gettext("New value"),
      role: "admin",
      outcomes: [gettext("Approve"), gettext("Decline")],
      outcome: gettext("Outcome"),
      variable: variables |> List.first() |> then(&(&1 && &1["name"])),
      group_field: gettext("field"),
      signal: signal,
      signal_entity: signal_entity,
      # A form asks for the first entity a form can fill in, if there is one.
      form_entity: editor |> form_entities() |> List.first() |> then(&(&1 && &1.id)),
      # A loop starts on the first list the drawing keeps, if it keeps one.
      loop_list: List.first(for(%{"name" => name, "list" => true} <- variables, do: name)) || "",
      loop_item: gettext("item"),
      process: callee && callee.id,
      call_fields: if(callee, do: Map.new(callee.fields, &{&1, ""}), else: %{})
    }
  end

  defp reminder_text(_socket), do: gettext("A decision is still waiting.")

  ## Saving

  defp save(socket) do
    %{group: group, current_profile: profile, process_editor: editor} = socket.assigns

    attrs = %{
      "name" => editor.name,
      "graph" => editor.graph,
      "layout" => %{"nodes" => editor.layout},
      "trigger_config" => editor.trigger_config,
      "entry_entity_id" => if(Triggers.typed?(editor.trigger), do: editor[:entry_entity]),
      "return_entity_id" => if(editor.trigger == "process", do: editor[:return_entity]),
      "is_public" => editor.trigger == "process" and editor.public?
    }

    result =
      case editor.source do
        :new ->
          DrawnProcesses.create(
            profile,
            group,
            Map.merge(attrs, %{
              "trigger" => editor.trigger,
              "alt_id" => editor.alt_id,
              "collection" => editor.collection
            })
          )

        :drawn ->
          DrawnProcesses.update(profile, group, editor.id, attrs, editor.revision)
      end

    case {editor.source, result} do
      {:new, {:ok, row}} ->
        socket
        |> put_flash(:info, gettext("The process is saved. Switch it on when it is ready."))
        |> push_patch(to: ~p"/groups/#{group.id}/processes?#{[process: row.id]}")

      {:drawn, {:ok, row}} ->
        socket
        |> update_editor(fn editor ->
          %{
            editor
            | name: row.name,
              revision: row.lock_version,
              dirty?: false,
              upgraded?: false,
              stale?: false,
              conflict: nil
          }
        end)
        |> put_flash(:info, gettext("The process is saved."))
        |> refresh()

      {_source, {:error, {:conflict, row}}} ->
        socket |> update_editor(&%{&1 | conflict: row}) |> refresh()

      {_source, {:error, {:invalid_trigger, path, reason}}} ->
        socket
        |> update_editor(
          &%{
            &1
            | error: trigger_error("trigger." <> path, reason, {:node, Graph.start(&1.graph)})
          }
        )
        |> put_flash(:error, gettext("What starts the process is not set right."))
        |> refresh()

      {_source, {:error, {:invalid_graph, path, reason}}} ->
        socket
        |> update_editor(&%{&1 | error: error(&1.graph, path, reason)})
        |> put_flash(:error, gettext("The drawing is not finished yet."))
        |> refresh()

      {_source, {:error, reason}} ->
        put_flash(socket, :error, refusal(reason))
    end
  end

  defp switch(socket, fun, message) do
    %{group: group, current_profile: profile, process_editor: editor} = socket.assigns

    cond do
      editor.source != :drawn ->
        socket

      editor.dirty? ->
        put_flash(socket, :error, gettext("Save the drawing first."))

      true ->
        case fun.(profile, group, editor.id) do
          {:ok, row} ->
            socket
            |> update_editor(&%{&1 | active?: row.active})
            |> put_flash(:info, message)
            |> refresh()

          {:error, reason} ->
            put_flash(socket, :error, refusal(reason))
        end
    end
  end

  ## The view

  defp update_editor(socket, fun),
    do: assign(socket, :process_editor, fun.(socket.assigns.process_editor))

  # Checks the drawing as a save would, builds the forms and tells the canvas.
  defp refresh(socket, opts \\ []) do
    editor = socket.assigns.process_editor

    editor = %{
      editor
      | error:
          check(editor, socket.assigns.access) ||
            check_trigger(editor, socket.assigns.access)
    }

    socket
    |> assign(:process_editor, editor)
    |> assign(:process_editor_form, element_form(editor, socket.assigns.access))
    |> assign(
      :process_editor_meta,
      to_form(
        %{
          "name" => editor.name,
          "trigger" => editor.trigger,
          "app" => app_value(editor.alt_id),
          "collection" => editor.collection
        },
        as: :meta
      )
    )
    |> push_event("process_canvas:state", canvas_state(editor, socket.assigns.access, opts))
  end

  defp app_value(nil), do: "default"
  defp app_value(id), do: Integer.to_string(id)

  defp check(%{graph: graph} = editor, access) do
    keys = AppData.role_keys(access.manifest)
    callable = Map.new(editor.callable, &{&1.id, &1.fields})

    with {:ok, normalized} <- Graph.normalize(graph, drawn: editor.source != :app),
         nil <- Graph.unknown_role(normalized, keys),
         nil <- Graph.unknown_process(normalized, callable),
         {:ok, _checked} <- said(normalized, editor) do
      nil
    else
      {:error, {"entry", reason}} ->
        trigger_error("trigger.entity", reason, {:node, Graph.start(graph)})

      {:error, {path, reason}} ->
        error(graph, path, reason)

      {path, reason} ->
        error(graph, path, reason)
    end
  end

  # What the drawing says, checked as a save would check it, for whoever
  # draws on it: against what its trigger hands a run, the group's entities,
  # the processes it calls and those that wait for its signals.
  defp said(graph, %{editable?: true} = editor) do
    Check.run(graph, %{
      trigger: editor.trigger,
      config: trigger_config(editor),
      entry_entity: if(Triggers.typed?(editor.trigger), do: editor[:entry_entity]),
      return_entity: if(editor.trigger == "process", do: editor[:return_entity]),
      entities: GroupEntities.definitions(editor[:entities] || []),
      callable: Map.new(editor.callable, &{&1.id, Map.take(&1, [:attributes, :types, :returns])}),
      signals: editor[:signal_entities] || %{}
    })
  end

  defp said(graph, _looking), do: {:ok, graph}

  # The trigger's settings as a save would keep them, as far as they are set.
  defp trigger_config(editor) do
    case Triggers.normalize(editor.trigger, editor.trigger_config) do
      {:ok, config} -> config
      {:error, _reason} -> %{}
    end
  end

  @doc """
  Reads the group's entities again and checks the drawing against them, as
  one of them changed while the drawing is open.
  """
  def entities_changed(%{assigns: %{process_editor: %{editable?: true}}} = socket) do
    entities = GroupEntities.list(socket.assigns.group)
    socket |> update_editor(&%{&1 | entities: entities}) |> refresh()
  end

  def entities_changed(socket), do: socket

  @doc """
  The data of the process, for its panel: what set it going (`entry`), what
  its steps bring back (`results`) and the fields of the group (`group`),
  each as `{path, type}` with the path an expression names it by, and its
  variables as their form lists them.
  """
  def data(editor) do
    start = Graph.start(editor.graph)
    names = Scope.names(told(editor))
    definitions = GroupEntities.definitions(editor[:entities] || [])

    entry =
      case entry(editor) do
        {:record, fields, _open?} when map_size(fields) > 0 ->
          # The attributes of the entity it takes first, in their order.
          attributes =
            case entry_definition(editor) do
              %{"attributes" => attributes} -> Enum.map(attributes, & &1["name"])
              nil -> []
            end

          known = for name <- attributes ++ editor.fields, is_map_key(fields, name), do: name
          known = Enum.uniq(known)

          for name <- known ++ (Map.keys(fields) -- known),
              do: {Scope.path(start, name), fields[name]}

        _open_or_unknown ->
          for name <- editor.fields, do: {Scope.path(start, name), :any}
      end

    results =
      Enum.flat_map(editor.graph["nodes"], fn
        %{"type" => "userTask", "id" => id} ->
          [{"#{id}.outcome", :text}, {"#{id}.by", :text}, {"#{id}.comment", :text}]

        %{"type" => "formTask"} = form ->
          form_results(form, definitions)

        %{"type" => "callActivity", "wait" => true, "id" => id} ->
          [{"#{id}.outcome", :text}]

        %{"type" => "receiveTask", "id" => id, "signal" => signal} ->
          [{"#{id}.from", :text}] ++
            for(field <- carried(editor, signal), do: {Scope.path(id, field), :any})

        %{"type" => "loop", "id" => id, "item" => item} ->
          [{item, Map.get(names, item, :any)}, {"#{id}.index", :number}, {"#{id}.count", :number}]

        _other ->
          []
      end)

    %{
      entry: entry,
      results: results,
      group: for(name <- group_field_names(editor), do: {Scope.path("group", name), :any}),
      variables: editor.graph["variables"] || []
    }
  end

  # What a form brings back: the attributes of the entity it asks for, in
  # their order, and who filled it in.
  defp form_results(%{"id" => id} = form, definitions) do
    attributes = (form["entity"] && Types.attributes(definitions, form["entity"])) || []

    for(attribute <- attributes, do: {Scope.path(id, attribute["name"]), Types.of(attribute)}) ++
      [{"#{id}.author", :text}]
  end

  @doc """
  The group's entities a form can fill in: every one, as a form asks for
  lists and the entities an entity holds too (`EntityFields`).
  """
  def form_entities(editor), do: editor[:entities] || []

  # The drawing as far as its names can be told just now: with the group's
  # entities, what its trigger hands a run, and what an item of each loop is.
  defp told(editor) do
    graph =
      editor.graph
      |> Map.put("types", GroupEntities.definitions(editor[:entities] || []))
      |> Map.put("entry", Types.json(entry(editor)))

    {:ok, graph} = Check.items(graph, loose: true)
    graph
  end

  @doc """
  Whether what a step sets is written as a text, which may hold expressions
  in braces, rather than as one expression: a text or a choice is, and so
  is an item of a list of them for a step that adds to the list (`op`).
  """
  def textual_target?(editor, target, op \\ "set") do
    case target_type(editor, target) do
      {:list, item} when op == "append" -> Types.textual?(item)
      nil -> false
      type -> Types.textual?(type)
    end
  end

  @doc "Whether what a step sets holds a list, which it may also add to."
  def list_target?(editor, target), do: match?({:list, _item}, target_type(editor, target))

  defp target_type(editor, target) when is_binary(target) do
    graph = Map.put(editor.graph, "types", GroupEntities.definitions(editor[:entities] || []))

    with {:ok, tree} <- PotokIde.Processes.Expr.parse(target),
         {:ok, type} <- PotokIde.Processes.Expr.check(tree, Scope.scope(graph)) do
      type
    else
      _unknown -> nil
    end
  end

  defp target_type(_editor, _target), do: nil

  @doc """
  The lists a loop may go through, as an expression names them: the lists
  among the names of the process, and those their entities hold, but not
  what the loop on hand hands out itself.
  """
  def list_hints(editor) do
    graph = told(editor)
    entities = graph["types"]

    own =
      with {:node, id} <- editor.selected,
           %{"item" => item} when is_binary(item) <- Graph.node(editor.graph, id) do
        item
      else
        _no_loop -> nil
      end

    for {name, type} <- Enum.sort(Scope.names(graph)),
        is_binary(name) and name not in ["", own],
        path <- lists(name, type, entities, 2),
        do: path
  end

  defp lists(name, {:list, _item}, _entities, _depth), do: [name]
  defp lists(_name, _type, _entities, 0), do: []

  defp lists(name, {:entity, id}, entities, depth) do
    for attribute <- Types.attributes(entities, id) || [],
        path <-
          lists(Scope.path(name, attribute["name"]), Types.of(attribute), entities, depth - 1),
        do: path
  end

  defp lists(name, {:record, fields, _open?}, entities, depth) do
    for {field, type} <- Enum.sort(fields),
        path <- lists(Scope.path(name, field), type, entities, depth - 1),
        do: path
  end

  defp lists(_name, _type, _entities, _depth), do: []

  @doc """
  What a step may set, as it names it: each variable, and for one that holds
  an entity its attributes, and theirs.
  """
  def assign_targets(editor) do
    definitions = GroupEntities.definitions(editor[:entities] || [])

    Enum.flat_map(editor.graph["variables"] || [], fn
      %{"name" => name, "type" => "entity", "entity" => id, "list" => false}
      when is_binary(name) ->
        [name | attribute_paths(name, id, definitions, 2)]

      %{"name" => name} when is_binary(name) and name != "" ->
        [name]

      _unnamed ->
        []
    end)
  end

  # The attributes of an entity as paths under `name`, down to `depth` levels.
  defp attribute_paths(_name, _id, _definitions, 0), do: []

  defp attribute_paths(name, id, definitions, depth) do
    case definitions[to_string(id)] do
      %{"attributes" => attributes} ->
        Enum.flat_map(attributes, fn
          %{"name" => attribute, "type" => "entity", "entity" => held, "list" => false} ->
            path = "#{name}.#{attribute}"
            [path | attribute_paths(path, held, definitions, depth - 1)]

          %{"name" => attribute} ->
            ["#{name}.#{attribute}"]
        end)

      _unknown ->
        []
    end
  end

  # The fields of the group the drawing may read: those kept, and those its
  # own steps set.
  defp group_field_names(editor) do
    editor.graph["nodes"]
    |> Enum.flat_map(fn
      %{"action" => "set", "field" => field} when is_binary(field) -> [field]
      _other -> []
    end)
    |> Kernel.++(editor[:group_fields] || [])
    |> Enum.uniq()
  end

  # What the trigger hands a run, from its settings as typed so far and the
  # entity the process takes.
  defp entry(editor),
    do: Triggers.entry(editor.trigger, trigger_config(editor), entry_definition(editor))

  @doc "The entity the process takes when it starts, as a graph keeps it, or nil."
  def entry_definition(editor) do
    with true <- Triggers.typed?(editor.trigger),
         id when is_integer(id) <- editor[:entry_entity],
         %GroupEntity{} = entity <- Enum.find(editor[:entities] || [], &(&1.id == id)) do
      GroupEntities.definition(entity)
    else
      _takes_none -> nil
    end
  end

  # The trigger's settings, checked as a save would, pinned on the start.
  defp check_trigger(editor, access) do
    keys = AppData.role_keys(access.manifest)
    start = {:node, Graph.start(editor.graph)}

    case Triggers.normalize(editor.trigger, editor.trigger_config) do
      {:ok, config} ->
        case Enum.find(Triggers.role_refs(editor.trigger, config), fn {_path, key} ->
               not MapSet.member?(keys, key)
             end) do
          nil -> nil
          {path, _key} -> trigger_error("trigger." <> path, :unknown_role, start)
        end

      {:error, {path, reason}} ->
        trigger_error("trigger." <> path, reason, start)
    end
  end

  defp trigger_error(path, reason, target),
    do: %{path: path, reason: reason, target: target, message: reason_text(reason, path)}

  defp error(graph, path, reason) do
    target =
      case String.split(path, ".") do
        ["nodes", i | _rest] -> node_at(graph, i)
        ["flows", k | _rest] -> flow_at(graph, k)
        _other -> nil
      end

    %{path: path, reason: reason, target: target, message: reason_text(reason, path)}
  end

  defp node_at(graph, i) do
    case Integer.parse(i) do
      {i, ""} -> (node = Enum.at(graph["nodes"], i)) && {:node, node["id"]}
      _other -> nil
    end
  end

  defp flow_at(graph, k) do
    case Integer.parse(k) do
      {k, ""} -> (flow = Enum.at(graph["flows"], k)) && {:flow, flow["key"]}
      _other -> nil
    end
  end

  @doc "The state the canvas draws."
  def canvas_state(editor, access, opts \\ []) do
    roles = role_labels(access)
    invalid = editor.error && editor.error.target

    %{
      id: @canvas,
      reset: opts[:reset] == true,
      editable: editor.editable?,
      dirty: editor.dirty?,
      selected: selected_value(editor.selected),
      layout: editor.layout,
      nodes:
        Enum.map(editor.graph["nodes"], fn node ->
          {kind, icon, title, detail} =
            describe(node, editor.graph, roles,
              start: start_title(editor, roles),
              processes: process_names(editor)
            )

          %{
            id: node["id"],
            kind: kind,
            icon: icon,
            title: title,
            detail: detail,
            invalid: invalid == {:node, node["id"]}
          }
        end),
      flows:
        Enum.map(editor.graph["flows"], fn flow ->
          %{
            key: flow["key"],
            from: flow["from"],
            to: flow["to"],
            kind: flow_kind(flow),
            label: flow_label(flow) || exit_label(editor.graph, flow),
            invalid: invalid == {:flow, flow["key"]}
          }
        end),
      labels: %{
        add: gettext("Add a step here"),
        connect: gettext("Drag to another step"),
        zoom_in: gettext("Zoom in"),
        zoom_out: gettext("Zoom out"),
        fit: gettext("Show it all")
      }
    }
  end

  defp selected_value({:node, id}), do: "node:" <> id
  defp selected_value({:flow, key}), do: "flow:" <> key
  defp selected_value(nil), do: nil

  @doc "The names of the processes a call may start, by id."
  def process_names(editor), do: Map.new(editor[:callable] || [], &{&1.id, &1.name})

  @doc """
  What a step's texts and conditions may name, as an expression names it
  (`Processes.Scope`): the fields of what set the process going, under the
  id of its start, then what the calls, waits and decisions of the drawing
  bring back, but the step's own, then the fields of the group; and its
  variables, with the attributes of those that hold an entity.
  """
  def field_hints(editor) do
    own = with {:node, id} <- editor.selected, do: id
    group = Enum.map(group_field_names(editor), &Scope.path("group", &1))
    names = Scope.names(told(editor))
    definitions = GroupEntities.definitions(editor[:entities] || [])

    results =
      Enum.flat_map(editor.graph["nodes"], fn
        %{"id" => ^own} ->
          []

        %{"type" => "callActivity", "wait" => true, "id" => id} = call ->
          returned =
            case Enum.find(editor.callable, &(&1.id == call["process"])) do
              %{returned: [_ | _] = attributes} -> Enum.map(attributes, & &1["name"])
              _hands_back_nothing -> []
            end

          ["#{id}.outcome" | Enum.map(returned, &Scope.path(id, &1))]

        %{"type" => "receiveTask", "id" => id, "signal" => signal} ->
          for field <- ["from" | carried(editor, signal)], do: Scope.path(id, field)

        %{"type" => "userTask", "id" => id} ->
          ["#{id}.outcome", "#{id}.by", "#{id}.comment"]

        %{"type" => "formTask"} = form ->
          for {path, _type} <- form_results(form, definitions), do: path

        %{"type" => "loop", "id" => id, "item" => item} ->
          held =
            case Map.get(names, item) do
              {:entity, entity} -> attribute_paths(item, entity, definitions, 2)
              _plain -> []
            end

          [item | held] ++ ["#{id}.index"]

        _other ->
          []
      end)

    Enum.map(data(editor).entry, &elem(&1, 0)) ++ assign_targets(editor) ++ results ++ group
  end

  # The fields the senders of a signal put in it, in the group and here.
  defp carried(editor, signal) do
    here =
      for %{"action" => "signal", "name" => ^signal} = step <- editor.graph["nodes"],
          field <- step["fields"] || [],
          do: field["name"]

    Enum.uniq(Map.get(editor[:signals] || %{}, signal, []) ++ here)
  end

  @doc "The roles of the group by key, with their names."
  def role_labels(access) do
    roles = if access.manifest, do: access.manifest.roles, else: []
    Map.new(roles, &{&1.key, RolesTab.role_label(&1)})
  end

  @doc """
  How a step shows on the canvas and in lists: `{kind, icon, title, detail}`.
  """
  def describe(node, graph, roles, opts \\ []) do
    label = node["label"]

    case node do
      %{"type" => "startEvent"} ->
        {"start", "hero-play-circle", label || opts[:start] || gettext("A value comes in"), nil}

      %{"type" => "endEvent"} ->
        {"end", "hero-flag", label || gettext("End"), nil}

      %{"type" => "exclusiveGateway"} ->
        {"gateway", "hero-arrows-right-left", label || gettext("Condition"), nil}

      %{"action" => "message", "in" => "app"} ->
        {"message", "hero-chat-bubble-left-ellipsis", label || gettext("Message in the group"),
         node["text"]}

      %{"action" => "message", "in" => target} ->
        sub =
          case Graph.node(graph, target) do
            nil -> target
            node -> Graph.label(node)
          end

        {"message", "hero-chat-bubble-left-ellipsis",
         label || gettext("Message in %{group}", group: sub), node["text"]}

      %{"action" => "subgroup"} ->
        {"subgroup", "hero-folder-plus", label || gettext("New sub-group"), node["name"]}

      %{"action" => "push"} ->
        {"push", "hero-bell-alert",
         label || gettext("Push to %{role}", role: role_name(roles, node["role"])), node["text"]}

      %{"type" => "userTask"} ->
        detail =
          [role_name(roles, node["role"]), node["deadline"] && duration_text(node["deadline"])]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        {"task", "hero-hand-raised", label || gettext("Decision"), detail}

      %{"type" => "formTask"} ->
        who =
          if node["by"] == "role",
            do: role_name(roles, node["role"]),
            else: gettext("whoever started it")

        detail =
          [who, node["deadline"] && duration_text(node["deadline"])]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        {"form", "hero-clipboard-document-list", label || gettext("Form"), detail}

      %{"type" => "timer"} ->
        {"timer", "hero-clock", label || gettext("Wait"), duration_text(node["duration"])}

      %{"action" => "signal"} ->
        {"signal", "hero-megaphone", label || gettext("Signal %{name}", name: node["name"]),
         node["fields"] |> List.wrap() |> Enum.map_join(", ", & &1["name"])}

      %{"type" => "receiveTask"} ->
        detail =
          [
            node["same_subject"] && gettext("same subject"),
            node["deadline"] && duration_text(node["deadline"])
          ]
          |> Enum.reject(&(&1 in [nil, false]))
          |> Enum.join(" · ")

        {"receive", "hero-signal", label || gettext("Wait for %{name}", name: node["signal"]),
         if(detail == "", do: nil, else: detail)}

      %{"action" => "assign"} ->
        target = if node["target"] in [nil, ""], do: gettext("a variable"), else: node["target"]

        title =
          if node["op"] == "append",
            do: gettext("Add to list %{name}", name: target),
            else: gettext("Set %{name}", name: target)

        {"assign", "hero-variable", label || title, node["value"]}

      %{"type" => "loop"} ->
        {"loop", "hero-arrow-path", label || gettext("For each %{item}", item: node["item"]),
         node["list"]}

      %{"action" => "set", "op" => "add"} ->
        {"set", "hero-pencil-square", label || gettext("Add to %{field}", field: node["field"]),
         node["value"]}

      %{"action" => "set"} ->
        {"set", "hero-pencil-square", label || gettext("Set %{field}", field: node["field"]),
         node["value"]}

      %{"type" => "callActivity"} ->
        process = Map.get(opts[:processes] || %{}, node["process"]) || gettext("a process")

        title =
          if node["wait"] == false,
            do: gettext("Start %{process}", process: process),
            else: gettext("Call %{process}", process: process)

        detail =
          cond do
            node["wait"] == false -> gettext("goes on at once")
            node["deadline"] -> duration_text(node["deadline"])
            true -> nil
          end

        {"call", "hero-arrow-top-right-on-square", label || title, detail}

      _other ->
        {"message", "hero-question-mark-circle", label || node["id"], nil}
    end
  end

  defp role_name(roles, key), do: Map.get(roles, key, key)

  @doc "A duration in words, such as `7 days`."
  def duration_text(duration) do
    case amount(duration) do
      {"", _unit} -> duration
      {n, unit} -> unit_text(String.to_integer(n), unit)
    end
  end

  defp unit_text(n, "minutes"), do: ngettext("%{count} minute", "%{count} minutes", n)
  defp unit_text(n, "hours"), do: ngettext("%{count} hour", "%{count} hours", n)
  defp unit_text(n, "days"), do: ngettext("%{count} day", "%{count} days", n)
  defp unit_text(n, "weeks"), do: ngettext("%{count} week", "%{count} weeks", n)

  # The plain flow of a loop is the way on after its last item.
  defp exit_label(graph, %{"from" => from}) do
    case Graph.node(graph, from) do
      %{"type" => "loop"} -> gettext("after the last")
      _other -> nil
    end
  end

  defp flow_kind(flow) do
    cond do
      Map.has_key?(flow, "each") -> "each"
      Map.has_key?(flow, "outcome") -> "outcome"
      Map.has_key?(flow, "deadline") -> "deadline"
      Map.has_key?(flow, "default") -> "default"
      Map.has_key?(flow, "condition") -> "condition"
      true -> "plain"
    end
  end

  @doc "What a flow says on the canvas, nil for a plain one."
  def flow_label(%{"outcome" => outcome}), do: outcome
  def flow_label(%{"deadline" => true}), do: gettext("deadline passed")
  def flow_label(%{"default" => true}), do: gettext("otherwise")
  def flow_label(%{"each" => true}), do: gettext("for each")

  def flow_label(%{"condition" => %{"expr" => expression}}) do
    if String.length(expression) > 36,
      do: String.slice(expression, 0, 35) <> "…",
      else: expression
  end

  def flow_label(%{"condition" => %{"op" => "empty", "field" => field}}),
    do: gettext("%{field} is empty", field: field)

  def flow_label(%{"condition" => %{"op" => op, "field" => field, "value" => value}}),
    do: "#{field} #{op_text(op)} #{value}"

  def flow_label(_plain), do: nil

  defp op_text("="), do: "="
  defp op_text("!="), do: "≠"
  defp op_text(op), do: op

  # The form of the step or flow on hand.
  defp element_form(%{selected: {:node, id}} = editor, _access) do
    case Graph.node(editor.graph, id) do
      nil ->
        nil

      node ->
        {duration_amount, duration_unit} = amount(node["duration"])
        {deadline_amount, deadline_unit} = amount(node["deadline"])

        node
        |> Map.take(
          ~w(label text in name role admins fields field op value target list item intro)
        )
        |> Map.merge(%{
          "duration_amount" => duration_amount,
          "duration_unit" => duration_unit,
          "deadline_amount" => deadline_amount,
          "deadline_unit" => deadline_unit,
          "process" => node["process"] && to_string(node["process"]),
          "wait" => to_string(node["wait"] != false),
          "signal" => node["signal"],
          "entity" => node["entity"] && to_string(node["entity"]),
          "same_subject" => to_string(node["same_subject"] == true),
          "related" => to_string(node["related"] == true),
          # Who fills in a form, as its select names them.
          "who" => if(node["by"] == "role", do: "role:#{node["role"]}", else: "starter")
        })
        |> to_form(as: :element, id: "process-element-#{id}")
    end
  end

  defp element_form(%{selected: {:flow, key}} = editor, _access) do
    case GraphEdit.flow(editor.graph, key) do
      nil ->
        nil

      flow ->
        condition = flow["condition"] || %{}

        %{
          "to" => flow["to"],
          "outcome" => flow["outcome"],
          "expr" => condition["expr"],
          "field" => condition["field"],
          "op" => condition["op"],
          "value" => condition["value"]
        }
        |> to_form(as: :flow, id: "process-flow-#{key}")
    end
  end

  defp element_form(_editor, _access), do: nil

  ## Words

  defp reason_text(reason, "trigger." <> field), do: trigger_reason(reason, field)
  defp reason_text(:unreachable, _path), do: gettext("Nothing leads to this step from the start.")
  defp reason_text(:dead_end, _path), do: gettext("From this step there is no way to an end.")
  defp reason_text(:unknown_role, _path), do: gettext("The group has no such role.")
  defp reason_text(:duplicate, _path), do: gettext("Two outcomes have the same name.")
  defp reason_text(:no_flow, _path), do: gettext("An outcome or the deadline has no way on.")
  defp reason_text(:no_default, _path), do: gettext("A condition needs a way for “otherwise”.")
  defp reason_text(:conditions, _path), do: gettext("A condition needs at least one condition.")
  defp reason_text(:unknown, _path), do: gettext("The sub-group this message goes to is gone.")
  defp reason_text(:too_many, _path), do: gettext("A drawing holds at most 100 steps.")

  defp reason_text(:unknown_process, _path),
    do:
      gettext(
        "The process this step calls is gone, or no longer public. Pick one that starts when another calls it."
      )

  defp reason_text(:unknown_field, _path),
    do: gettext("The process called does not take this field.")

  defp reason_text(:not_a_number, _path), do: gettext("Adding takes a number, or a field.")

  defp reason_text(:no_list, _path), do: gettext("Say which list the loop goes through.")

  defp reason_text(:loop_flows, _path),
    do: gettext("A loop needs one way into its own steps and one way on.")

  defp reason_text(:loop_empty, _path), do: gettext("A loop needs a step of its own.")

  defp reason_text(:loop_open, _path),
    do: gettext("The steps of a loop lead back to the loop, not to an end.")

  defp reason_text(:loop_entered, _path),
    do: gettext("Only the loop itself leads into its own steps.")

  defp reason_text(:invalid, "nodes." <> rest = path) do
    if String.ends_with?(rest, ".item"),
      do: gettext("An item is named in one word: letters, digits and _, starting with a letter."),
      else: invalid_text(path)
  end

  defp reason_text(:required, _path),
    do: gettext("An attribute that must be filled in is left empty.")

  defp reason_text(:signal_entity, _path),
    do: gettext("Those who wait for this signal expect it with another entity.")

  defp reason_text(:taken, _path),
    do: gettext("A step or another variable has that name already.")

  defp reason_text(:unknown_entity, _path),
    do: gettext("The group no longer has that entity, or one it holds.")

  defp reason_text(:no_entity, _path), do: gettext("Pick the entity the form asks for.")

  defp reason_text(:no_starter, _path),
    do: gettext("Nobody starts a process on a schedule, so its form asks the people of a role.")

  defp reason_text({:not_a_variable, ""}, _path),
    do: gettext("A step sets a variable, or an attribute of one.")

  defp reason_text({:not_a_variable, name}, _path),
    do: gettext("%{name} is no variable, so no step can set it.", name: name)

  defp reason_text(:invalid, "variables" <> _rest = path) do
    cond do
      String.ends_with?(path, ".name") ->
        gettext("A variable is named in one word: letters, digits and _, starting with a letter.")

      String.ends_with?(path, ".options") ->
        gettext("A choice lists what it may be, each once.")

      String.ends_with?(path, ".entity") ->
        gettext("Pick the entity the variable holds.")

      String.ends_with?(path, ".initial") ->
        gettext("What the variable starts with is too long.")

      true ->
        gettext("A variable is not set right.")
    end
  end

  defp reason_text(:too_many, "variables" <> _rest),
    do: gettext("A drawing keeps at most 30 variables.")

  defp reason_text(:invalid, path), do: invalid_text(path)

  # What an expression says wrong (`Processes.Expr`).
  defp reason_text({:syntax, at}, _path),
    do: gettext("This cannot be read from its character %{at} on.", at: at + 1)

  defp reason_text({:unknown_name, name}, _path),
    do: gettext("The process has nothing named %{name}.", name: name)

  defp reason_text({:unknown_attribute, name}, _path),
    do: gettext("There is no %{name} in that.", name: name)

  defp reason_text({:unknown_function, name}, _path),
    do: gettext("There is no function %{name}.", name: name)

  defp reason_text({:arguments, name}, _path),
    do: gettext("The function %{name} takes something else.", name: name)

  defp reason_text({:mismatch, expected, got}, _path),
    do:
      gettext("Here goes %{expected}, and this is %{got}.",
        expected: type_text(expected),
        got: type_text(got)
      )

  defp reason_text(:reserved, _path), do: gettext("That name is taken by the process itself.")
  defp reason_text(_reason, _path), do: gettext("The ways on from this step are not right.")

  # What is missing or too long, by where it stands.
  defp invalid_text(path) do
    cond do
      String.ends_with?(path, ".target") ->
        gettext("Pick what the step sets: a variable, or an attribute of one.")

      String.ends_with?(path, ".intro") ->
        gettext("What the form says first is at most 1000 characters.")

      String.contains?(path, ".values.") ->
        gettext("What the form starts with is at most 1000 characters.")

      String.ends_with?(path, ".text") ->
        gettext("The text is empty or too long.")

      String.ends_with?(path, ".name") ->
        gettext("The name is empty or too long.")

      String.ends_with?(path, ".label") ->
        gettext("The name on the drawing is too long.")

      String.ends_with?(path, ".process") ->
        gettext("Pick the process to call.")

      String.ends_with?(path, ".signal") or String.contains?(path, ".fields.") ->
        gettext("Signals and their fields are named in one word: letters, digits, - or _.")

      String.ends_with?(path, ".field") ->
        gettext("A field is named with up to 40 letters, digits, - or _.")

      String.ends_with?(path, ".value") ->
        gettext("The value is at most 1000 characters.")

      String.contains?(path, ".fields") ->
        gettext("A field it hands over is too long.")

      String.contains?(path, ".outcomes") ->
        gettext("An outcome is empty or too long.")

      String.contains?(path, ".condition") ->
        gettext("The condition needs a field.")

      String.contains?(path, "duration") or String.contains?(path, "deadline") ->
        gettext("The time is from a minute to a year.")

      true ->
        gettext("Something here is missing.")
    end
  end

  # A type in words, as a sentence about a mistake names it.
  defp type_text(:number), do: gettext("a number")
  defp type_text(:text), do: gettext("a text")
  defp type_text(:boolean), do: gettext("a yes or no")
  defp type_text(:date), do: gettext("a date")
  defp type_text(:datetime), do: gettext("a date and time")
  defp type_text({:choice, _options}), do: gettext("a choice")
  defp type_text({:entity, _id}), do: gettext("an entity")
  defp type_text(type) when type == :list or elem(type, 0) == :list, do: gettext("a list")

  defp type_text(type) when type == :record or elem(type, 0) == :record,
    do: gettext("a set of fields")

  defp type_text(:empty), do: gettext("nothing")
  defp type_text(_any), do: gettext("something else")

  defp trigger_reason(:empty, "words"),
    do: gettext("Type a word, or pick a role a message mentions.")

  defp trigger_reason(:too_many, "words"), do: gettext("At most 10 words.")

  defp trigger_reason(:invalid, "words"),
    do: gettext("Words go one by one, 2 to 40 letters or digits each.")

  defp trigger_reason(:invalid, "name"),
    do: gettext("A signal is named in one word, 2 to 40 letters or digits.")

  defp trigger_reason(:too_many, "fields"), do: gettext("At most 10 fields.")
  defp trigger_reason(:reserved, "fields"), do: gettext("The names from and outcome are taken.")

  defp trigger_reason(:invalid, "fields"),
    do: gettext("Fields go one by one: letters, digits, - and _, up to 40 each.")

  defp trigger_reason(:empty, "weekdays"), do: gettext("Pick at least one day.")
  defp trigger_reason(:invalid, "time"), do: gettext("The time is written as 20:00.")
  defp trigger_reason(:unknown_role, _field), do: gettext("The group has no such role.")

  defp trigger_reason(_reason, "entity"),
    do: gettext("The group no longer has the entity this process takes.")

  defp trigger_reason(_reason, "returns"),
    do: gettext("The group no longer has the entity this process hands back.")

  defp trigger_reason(_reason, _field), do: gettext("What starts the process is not set right.")

  ## The trigger in words

  @doc "What starts a process, in words, for its start and its row on the tab."
  def start_title(%{trigger: trigger, trigger_config: config} = editor, roles) do
    case Triggers.normalize(trigger, config) do
      {:ok, config} -> trigger_summary(trigger, config, editor[:collection], roles)
      {:error, _reason} -> trigger_title(trigger)
    end
  end

  # A trigger's title on the start step, before its settings are whole.
  defp trigger_title("message"), do: gettext("A message")
  defp trigger_title("subgroup"), do: gettext("A new sub-group")
  defp trigger_title("schedule"), do: gettext("On a schedule")
  defp trigger_title("manual"), do: gettext("Started by hand")
  defp trigger_title("process"), do: gettext("Called by another process")
  defp trigger_title("signal"), do: gettext("On a signal")
  defp trigger_title(_value), do: gettext("A value comes in")

  @doc "A trigger with its settings in words."
  def trigger_summary("value", _config, _collection, _roles), do: gettext("A value comes in")

  def trigger_summary("message", %{"words" => words, "role" => role}, _collection, roles) do
    words = Enum.join(words, ", ")
    role = role && Map.get(roles, role, role)

    cond do
      words != "" and role ->
        gettext("A message with %{words} or for %{role}", words: words, role: role)

      words != "" ->
        gettext("A message with: %{words}", words: words)

      true ->
        gettext("A message for %{role}", role: role)
    end
  end

  def trigger_summary("subgroup", %{"placed" => true}, _collection, _roles),
    do: gettext("A new sub-group with a place")

  def trigger_summary("subgroup", _config, _collection, _roles), do: gettext("A new sub-group")
  def trigger_summary("schedule", config, _collection, _roles), do: schedule_text(config)

  def trigger_summary("manual", %{"roles" => keys}, _collection, roles),
    do: gettext("Started by: %{roles}", roles: Enum.map_join(keys, ", ", &Map.get(roles, &1, &1)))

  def trigger_summary("process", %{"fields" => [_ | _] = fields}, _collection, _roles),
    do: gettext("Called with: %{fields}", fields: Enum.join(fields, ", "))

  def trigger_summary("process", _config, _collection, _roles),
    do: gettext("Called by another process")

  def trigger_summary("signal", %{"name" => name}, _collection, _roles),
    do: gettext("On the signal %{name}", name: name)

  def trigger_summary(trigger, _config, _collection, _roles), do: trigger_name(trigger)

  @doc "A schedule in words, such as `Every week on Thu at 20:00`."
  def schedule_text(%{"every" => "day", "time" => time}),
    do: gettext("Every day at %{time}", time: time)

  def schedule_text(%{"every" => "week", "weekdays" => days, "time" => time}) do
    gettext("Every week on %{days} at %{time}",
      days: Enum.map_join(days, ", ", &PotokIde.Events.Format.weekday_short/1),
      time: time
    )
  end

  def schedule_text(%{"every" => "month", "day" => "last", "time" => time}),
    do: gettext("On the last day of the month at %{time}", time: time)

  def schedule_text(%{"every" => "month", "day" => day, "time" => time}),
    do: gettext("Every month on day %{day} at %{time}", day: day, time: time)

  def schedule_text(_config), do: trigger_name("schedule")

  @doc "A trigger's name, as the editor offers it after “When”."
  def trigger_name("value"), do: gettext("a value comes to an app")
  def trigger_name("message"), do: gettext("someone writes a message")
  def trigger_name("subgroup"), do: gettext("a sub-group is made")
  def trigger_name("schedule"), do: gettext("the set time comes")
  def trigger_name("manual"), do: gettext("someone starts it")
  def trigger_name("process"), do: gettext("another process calls it")
  def trigger_name("signal"), do: gettext("a signal is sent")

  defp refusal(:start), do: gettext("The start stays.")
  defp refusal(:last_end), do: gettext("The last end stays.")
  defp refusal(:last_branch), do: gettext("The last branch stays.")
  defp refusal(:last_in_loop), do: gettext("A loop keeps at least one step of its own.")
  defp refusal(:needed), do: gettext("This way on is needed; send it elsewhere instead.")
  defp refusal(:too_many), do: gettext("There are too many already.")
  defp refusal(:self), do: gettext("A step cannot lead to itself.")
  defp refusal(:to_start), do: gettext("Nothing leads back to the start.")
  defp refusal(:from_end), do: gettext("Nothing leads on from an end.")
  defp refusal(:duplicate), do: gettext("Two outcomes have the same name.")
  defp refusal(:invalid_name), do: gettext("The process needs a name of up to 60 characters.")

  defp refusal({:in_use, name}),
    do: gettext("%{process} calls this process. Change that first.", process: name)

  defp refusal({:invalid_trigger, _path, _reason}),
    do: gettext("What starts the process is not set right.")

  defp refusal(:unknown_collection), do: gettext("Pick a collection of the app.")
  defp refusal(:not_permitted), do: gettext("Only the app's editors draw processes.")
  defp refusal(_reason), do: gettext("That did not work.")
end
