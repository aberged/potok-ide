defmodule PotokIdeWeb.GroupLive.Show.ProcessesState do
  @moduledoc """
  What `GroupLive.Show` holds for its Processes tab: the group's processes,
  those its apps write into their rules and those drawn in Potok
  (`PotokIde.Social.DrawnProcesses`), with how their instances are doing, and
  the tasks of drawn processes that wait on the viewer, which no app shows.
  `GroupLive.Show` delegates every `"processes_*"` event and `{:processes, _}`
  message here.

  - Members see the processes and their counts; the app's editors also see
    the drawings that are off, what a process may not do, and the failed
    instances, to take up again or cancel.
  - The people of a task's role decide it here, with the value as far as
    they may read it. A form that waits for the viewer is listed here too,
    and filled in in its own dialog (`ProcessForm`).
  - The app's editors define the group's entities here
    (`PotokIde.Processes.GroupEntities`), in a form over the tab
    (`processes_entity`).
  - Other people's changes (`{:app_value, ...}`) reload the tab after a short
    wait, so a burst of moves loads it once.
  - How many tasks wait for the viewer (`processes_waiting`) is kept on every
    tab, for the mark in the page's header, and counted again only on news
    that is the viewer's (`theirs?/3`).
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Processes
  alias PotokIde.Processes.{Graph, GroupEntities, GroupEntity, GroupFields}
  alias PotokIde.Social.{Access, AppProcesses, DrawnProcesses, Group, ValueRules}
  alias PotokIdeWeb.GroupLive.Show.{EntityFields, ProcessEditorState, ProcessForm}

  @debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @reloading_events [:config, :process, :drawn_process, :created, :entity]

  ## Setup

  def init(socket, params) do
    socket
    |> assign(
      processes_tab?: false,
      processes_apps: [],
      processes_tasks: [],
      processes_fields: [],
      processes_entities: [],
      processes_entity: nil,
      processes_can_draw?: false,
      processes_refresh?: false,
      processes_start: nil,
      processes_waiting: 0,
      processes_recount?: false
    )
    |> ProcessEditorState.init()
    |> assign_params(params)
  end

  @doc """
  Takes the open drawing from the URL into assigns, without loading it:
  `?process=new` or `?process=12`.
  """
  def assign_params(socket, params),
    do: assign(socket, :processes_param, parse_param(params["process"]))

  def params_changed?(socket, params),
    do: parse_param(params["process"]) != socket.assigns.processes_param

  def handle_params(socket, params) do
    socket |> assign_params(params) |> ensure_editor()
  end

  defp parse_param("new"), do: :new

  defp parse_param(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> id
      _other -> nil
    end
  end

  defp parse_param(_param), do: nil

  # Opens the drawing the URL names, unless it is open already: the tab
  # loads again on other people's changes, and a drawing under way stays.
  defp ensure_editor(socket) do
    param = socket.assigns.processes_param

    case socket.assigns.process_editor do
      %{id: nil} when param == :new -> socket
      %{id: id} when is_integer(id) and id == param -> socket
      _other -> ProcessEditorState.open(socket, param)
    end
  end

  @doc """
  Whether the group has the tab: for its members, in a group that is neither
  the root nor a conversation, with an app or a process.
  """
  def available?(%Group{is_root: true}, _access), do: false
  def available?(%Group{is_direct: true}, _access), do: false

  def available?(%Group{} = group, %Access{member?: true} = access),
    do: ValueRules.manage?(access) or AppProcesses.any_app_or_process?(group)

  def available?(_group, _access), do: false

  @doc "Sets `processes_tab?` for the group on screen."
  def assign_available(socket) do
    assign(socket, :processes_tab?, available?(socket.assigns.group, socket.assigns.access))
  end

  @doc """
  Counts what waits for the viewer in the group on screen, decisions and
  forms (`Processes.waiting_count/3`), for the mark in the page's header and
  on the tab's item in the menu. A group without the tab has nothing to
  count.
  """
  def assign_waiting(socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    count =
      if profile && socket.assigns.processes_tab?,
        do: Processes.waiting_count(profile, group, access),
        else: 0

    assign(socket, processes_waiting: count, processes_recount?: false)
  end

  def maybe_load(socket, %Group{}, "processes"), do: socket |> load() |> ensure_editor()

  def maybe_load(socket, %Group{}, _active_tab) do
    socket
    |> assign(
      processes_apps: [],
      processes_tasks: [],
      processes_fields: [],
      processes_entities: [],
      processes_entity: nil
    )
    |> ProcessEditorState.init()
  end

  defp load(socket) do
    %{group: group, access: access, current_profile: profile} = socket.assigns
    manage? = ValueRules.manage?(access)
    rows = AppProcesses.list_for_tab(group, manage?)
    counts = rows |> Enum.map(& &1.id) |> Processes.counts()
    shared = shared_collections(rows)

    entries =
      Enum.map(rows, fn row ->
        %{
          id: row.id,
          process: row,
          counts: Map.get(counts, row.id, %{}),
          warning: if(manage? and row.active, do: AppProcesses.warning(row, group)),
          failed: if(manage?, do: failed(row), else: []),
          shared?: MapSet.member?(shared, {row.alt_description_id, row.collection})
        }
      end)

    assign(socket,
      processes_apps: by_app(entries, group),
      processes_tasks: Processes.tasks_for(profile, group, access),
      processes_fields: if(manage?, do: GroupFields.list(group), else: []),
      processes_entities: if(manage?, do: GroupEntities.list(group), else: []),
      processes_can_draw?: manage?,
      processes_refresh?: false
    )
  end

  # The collections on which more than one process runs.
  defp shared_collections(rows) do
    rows
    |> Enum.filter(&(&1.active and &1.trigger == "value"))
    |> Enum.frequencies_by(&{&1.alt_description_id, &1.collection})
    |> Enum.filter(fn {_key, n} -> n > 1 end)
    |> MapSet.new(&elem(&1, 0))
  end

  defp failed(row) do
    for instance <- Processes.failed(row.id) do
      element = (instance.error || %{})["element"] || instance.element
      %{instance: instance, label: element_label(instance.graph, element)}
    end
  end

  @doc "The label of an element of a graph, or its id."
  def element_label(graph, id) do
    case Graph.node(graph, id) do
      nil -> id
      node -> Graph.label(node)
    end
  end

  # The group's own processes (on messages, sub-groups, a schedule or by
  # hand) first, then the default description's app, then the others.
  defp by_app(entries, group) do
    entries
    |> Enum.group_by(fn %{process: p} ->
      if p.trigger == "value", do: {:app, p.alt_description_id}, else: :group
    end)
    |> Enum.map(fn
      {:group, entries} ->
        %{id: "group", name: gettext("In the group"), position: {0, 0, 0}, entries: entries}

      {{:app, alt_id}, entries} ->
        alt = hd(entries).process.alt_description

        %{
          id: alt_id || "default",
          name: if(alt, do: alt.name, else: group.description_name),
          position: if(alt, do: {2, alt.position, alt.id}, else: {1, 0, 0}),
          entries: entries
        }
    end)
    |> Enum.sort_by(& &1.position)
  end

  ## Events

  def handle_event("processes_complete", params, socket) do
    %{group: group, access: access, current_profile: profile} = socket.assigns

    with {id, ""} <- Integer.parse(to_string(params["instance"])),
         {:ok, _instance} <-
           Processes.complete_task(
             profile,
             group,
             :any,
             access,
             id,
             params["element"],
             params["outcome"],
             params["comment"]
           ) do
      {:noreply, socket |> put_flash(:info, gettext("Your decision is in.")) |> load()}
    else
      {:error, :not_waiting} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Someone has already decided this.")) |> load()}

      _refused ->
        {:noreply,
         socket |> put_flash(:error, gettext("Could not record the decision.")) |> load()}
    end
  end

  def handle_event("processes_start_open", %{"id" => id}, socket) do
    %{group: group, access: access} = socket.assigns

    with {id, ""} <- Integer.parse(to_string(id)),
         %{} = process <- DrawnProcesses.get(group, id),
         true <- process.active and DrawnProcesses.may_start?(process, access) do
      {:noreply, open_start(socket, process, %{})}
    else
      _other -> {:noreply, put_flash(socket, :error, gettext("You may not start this process."))}
    end
  end

  def handle_event("processes_start_close", _params, socket),
    do: {:noreply, assign(socket, :processes_start, nil)}

  def handle_event("processes_start_validate", %{"start" => params}, socket) do
    case socket.assigns.processes_start do
      nil -> {:noreply, socket}
      start -> {:noreply, assign(socket, :processes_start, start_params(start, params))}
    end
  end

  def handle_event("processes_start_add", %{"path" => path}, socket) do
    case socket.assigns.processes_start do
      %{attributes: [_ | _] = attributes, types: types, params: params} = start ->
        params = EntityFields.add(params, EntityFields.parse_path(path), attributes, types)
        {:noreply, assign(socket, :processes_start, start_params(start, params))}

      _plain_or_none ->
        {:noreply, socket}
    end
  end

  def handle_event("processes_start_remove", %{"path" => path, "index" => index}, socket) do
    case socket.assigns.processes_start do
      %{params: params} = start ->
        params = EntityFields.remove(params, EntityFields.parse_path(path), index)
        {:noreply, assign(socket, :processes_start, start_params(start, params))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("processes_start_save", %{"start" => params}, socket) do
    %{group: group, current_profile: profile, processes_start: start} = socket.assigns

    # A time typed into the form is the starter's own.
    zoned =
      case start do
        %{attributes: [_ | _] = attributes, types: types} ->
          attributes
          |> EntityFields.value(types, params)
          |> Map.put("time_zone", socket.assigns[:calendar_time_zone])

        _plain ->
          Map.put(params, "time_zone", socket.assigns[:calendar_time_zone])
      end

    case start && DrawnProcesses.start(profile, group, start.process.id, zoned) do
      {:ok, _instance} ->
        {:noreply,
         socket
         |> assign(:processes_start, nil)
         |> put_flash(:info, gettext("The process is started."))
         |> load()}

      {:error, reason} ->
        error_at =
          if start.attributes,
            do: PotokIdeWeb.GroupLive.Show.ProcessForm.error_at(reason, start, params)

        {:noreply,
         assign(socket, :processes_start, %{
           start_params(start, params)
           | error: start_error(reason),
             error_at: error_at
         })}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("processes_retry", %{"id" => id}, socket) do
    case instance_call(socket, id, &Processes.retry/4) do
      {:ok, _instance} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The process goes on from where it stopped."))
         |> load()}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not take it up again."))}
    end
  end

  def handle_event("processes_delete_field", %{"id" => id}, socket) do
    %{group: group, access: access} = socket.assigns

    result =
      case Integer.parse(to_string(id)) do
        {id, ""} -> GroupFields.delete(group, access, id)
        _invalid -> {:error, :not_found}
      end

    case result do
      {:ok, _field} ->
        {:noreply, socket |> put_flash(:info, gettext("The field is deleted.")) |> load()}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete the field."))}
    end
  end

  def handle_event("processes_cancel", %{"id" => id}, socket) do
    case instance_call(socket, id, &Processes.cancel/4) do
      {:ok, _instance} ->
        {:noreply, socket |> put_flash(:info, gettext("The instance is cancelled.")) |> load()}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not cancel it."))}
    end
  end

  def handle_event("processes_entity_new", _params, socket) do
    if socket.assigns.processes_can_draw? do
      # A new entity starts with one attribute to fill in.
      {:noreply, open_entity(socket, %GroupEntity{}, %{"attributes" => %{"0" => %{}}})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("processes_entity_edit", %{"id" => id}, socket) do
    with true <- socket.assigns.processes_can_draw?,
         {id, ""} <- Integer.parse(to_string(id)),
         %GroupEntity{} = entity <- GroupEntities.get(socket.assigns.group, id) do
      {:noreply, open_entity(socket, entity, %{})}
    else
      _gone -> {:noreply, put_flash(socket, :error, gettext("That entity is not here."))}
    end
  end

  def handle_event("processes_entity_close", _params, socket),
    do: {:noreply, assign(socket, :processes_entity, nil)}

  def handle_event("processes_entity_validate", %{"entity" => params}, socket) do
    case socket.assigns.processes_entity do
      nil ->
        {:noreply, socket}

      %{entity: entity} = state ->
        changeset =
          entity
          |> GroupEntities.change(params, socket.assigns.processes_entities)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :processes_entity, %{state | form: entity_form(changeset)})}
    end
  end

  def handle_event("processes_entity_save", %{"entity" => params}, socket) do
    %{group: group, access: access, processes_entity: state} = socket.assigns

    result =
      case state do
        nil -> nil
        %{entity: %GroupEntity{id: nil}} -> GroupEntities.create(group, access, params)
        %{entity: entity} -> GroupEntities.update(group, access, entity, params)
      end

    case result do
      nil ->
        {:noreply, socket}

      {:ok, _entity} ->
        {:noreply,
         socket
         |> assign(:processes_entity, nil)
         |> put_flash(:info, gettext("The entity is saved."))
         |> load()
         |> ProcessEditorState.entities_changed()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :processes_entity, %{state | form: entity_form(changeset)})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, entity_error(reason))}
    end
  end

  def handle_event("processes_entity_delete", %{"id" => id}, socket) do
    %{group: group, access: access} = socket.assigns

    result =
      case Integer.parse(to_string(id)) do
        {id, ""} -> GroupEntities.delete(group, access, id)
        _invalid -> {:error, :not_found}
      end

    case result do
      {:ok, _entity} ->
        {:noreply,
         socket
         |> assign(:processes_entity, nil)
         |> put_flash(:info, gettext("The entity is deleted."))
         |> load()
         |> ProcessEditorState.entities_changed()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, entity_error(reason))}
    end
  end

  # The form of an entity over the tab, among the group's entities as they
  # stand now.
  defp open_entity(socket, %GroupEntity{} = entity, params) do
    entities = GroupEntities.list(socket.assigns.group)
    changeset = GroupEntities.change(entity, params, entities)

    socket
    |> assign(:processes_entities, entities)
    |> assign(:processes_entity, %{entity: entity, form: entity_form(changeset)})
  end

  defp entity_form(changeset), do: to_form(changeset, as: :entity)

  defp entity_error({:in_use, names}),
    do:
      gettext("It is held by %{names}. Take it out of there first.",
        names: Enum.join(names, ", ")
      )

  defp entity_error(:too_many), do: gettext("A group has at most 50 entities.")
  defp entity_error(:not_found), do: gettext("That entity is not here.")
  defp entity_error(_reason), do: gettext("Only the app's editors define entities.")

  @doc """
  Opens the Start form of a process started by hand, for the page's dialog:
  the attributes of the entity it takes, starting with `prefill` (by
  attribute, as a run keeps values), or a title and a text.
  """
  def open_start(socket, process, prefill) do
    attributes = start_attributes(process)
    types = (process.graph || %{})["types"] || %{}
    zone = socket.assigns[:calendar_time_zone] || "Etc/UTC"

    params =
      case attributes do
        nil -> %{"title" => prefill["title"] || "", "text" => prefill["text"] || ""}
        attributes -> EntityFields.params(attributes, types, prefill, zone)
      end

    start = %{
      process: process,
      params: params,
      form: to_form(params, as: :start),
      attributes: attributes,
      types: types,
      error: nil,
      error_at: nil
    }

    assign(socket, :processes_start, start)
  end

  defp start_params(start, params),
    do: %{start | params: params, form: to_form(params, as: :start)}

  # The attributes a Start form asks for, as the process was saved with
  # them, or nil for one that takes a title and a text.
  defp start_attributes(%{entry_entity_id: id, graph: %{"types" => types}}) when is_integer(id),
    do: PotokIde.Processes.Types.attributes(types, id)

  defp start_attributes(_process), do: nil

  defp start_error({:invalid_field, name, reason}),
    do: gettext("%{name}: %{problem}.", name: name, problem: ProcessForm.field_problem(reason))

  defp start_error(:invalid_title), do: gettext("Give it a title of up to 120 characters.")
  defp start_error(:invalid_text), do: gettext("The text is at most 2000 characters.")
  defp start_error(:process_inactive), do: gettext("The process is off.")
  defp start_error(:not_permitted), do: gettext("You may not start this process.")
  defp start_error({:rate_limited, ms}), do: PotokIdeWeb.RateLimited.message(ms)
  defp start_error(_reason), do: gettext("That did not work.")

  defp instance_call(socket, id, fun) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> fun.(socket.assigns.group, :any, socket.assigns.access, id)
      _invalid -> {:error, :not_found}
    end
  end

  ## Other people's changes

  @doc """
  What an `{:app_value, ...}` of the group means for the tab: whether the
  group has it, what waits for the viewer there, and a reload when it is on
  screen.
  """
  def app_value(socket, event, payload \\ %{})

  def app_value(socket, event, payload) when event in @reloading_events do
    socket =
      if event in [:config, :drawn_process], do: assign_available(socket), else: socket

    # A drawing that is open is checked against the entities as they are now.
    socket = if event == :entity, do: ProcessEditorState.entities_changed(socket), else: socket

    socket = if theirs?(socket, event, payload), do: recount(socket), else: socket

    cond do
      socket.assigns.active_tab != "processes" ->
        socket

      # Tests wait for nothing (`config/test.exs`), as the calendar and polls.
      @debounce_ms == 0 ->
        load(socket)

      socket.assigns.processes_refresh? ->
        socket

      true ->
        Process.send_after(self(), {:processes, :refresh}, @debounce_ms)
        assign(socket, :processes_refresh?, true)
    end
  end

  def app_value(socket, _event, _payload), do: socket

  # Whether the news may change what waits for the viewer: a run that asks
  # them, or just stopped asking them, as one of a role or as the one who
  # started it (`Processes.Engine`), or the group's processes themselves
  # changing. Every other move of a run is someone else's, and costs no
  # count.
  defp theirs?(socket, :process, %{asks: %{role: role, profile_id: profile_id}}) do
    case socket.assigns do
      %{current_profile: %{id: viewer}, access: access} ->
        profile_id == viewer or (is_binary(role) and role in access.role_keys)

      _guest ->
        false
    end
  end

  defp theirs?(_socket, event, _payload), do: event in [:config, :drawn_process]

  # Counts again after a short wait, so a burst of moves counts once.
  defp recount(socket) do
    cond do
      @debounce_ms == 0 ->
        assign_waiting(socket)

      socket.assigns.processes_recount? ->
        socket

      true ->
        Process.send_after(self(), {:processes, :recount}, @debounce_ms)
        assign(socket, :processes_recount?, true)
    end
  end

  def handle_info(:refresh, socket) do
    if socket.assigns.active_tab == "processes",
      do: {:noreply, load(socket)},
      else: {:noreply, assign(socket, :processes_refresh?, false)}
  end

  def handle_info(:recount, socket), do: {:noreply, assign_waiting(socket)}
end
