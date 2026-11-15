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
    they may read it.
  - Other people's changes (`{:app_value, ...}`) reload the tab after a short
    wait, so a burst of moves loads it once.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Processes
  alias PotokIde.Processes.Graph
  alias PotokIde.Social.{Access, AppProcesses, Group, ValueRules}

  @debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @reloading_events [:config, :process, :drawn_process, :created]

  ## Setup

  def init(socket) do
    assign(socket,
      processes_tab?: false,
      processes_apps: [],
      processes_tasks: [],
      processes_refresh?: false
    )
  end

  @doc """
  Whether the group has the tab: for its members, in a group that is neither
  the root nor a conversation, with an app or a process.
  """
  def available?(%Group{is_root: true}, _access), do: false
  def available?(%Group{is_direct: true}, _access), do: false

  def available?(%Group{} = group, %Access{member?: true}),
    do: AppProcesses.any_app_or_process?(group)

  def available?(_group, _access), do: false

  @doc "Sets `processes_tab?` for the group on screen."
  def assign_available(socket) do
    assign(socket, :processes_tab?, available?(socket.assigns.group, socket.assigns.access))
  end

  def maybe_load(socket, %Group{}, "processes"), do: load(socket)

  def maybe_load(socket, %Group{}, _active_tab),
    do: assign(socket, processes_apps: [], processes_tasks: [])

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
      processes_refresh?: false
    )
  end

  # The collections on which more than one process runs.
  defp shared_collections(rows) do
    rows
    |> Enum.filter(& &1.active)
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

  # The default description's app first, then the others in their order.
  defp by_app(entries, group) do
    entries
    |> Enum.group_by(& &1.process.alt_description_id)
    |> Enum.map(fn {alt_id, entries} ->
      alt = hd(entries).process.alt_description

      %{
        id: alt_id || "default",
        name: if(alt, do: alt.name, else: group.description_name),
        position: if(alt, do: {1, alt.position, alt.id}, else: {0, 0, 0}),
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

  def handle_event("processes_cancel", %{"id" => id}, socket) do
    case instance_call(socket, id, &Processes.cancel/4) do
      {:ok, _instance} ->
        {:noreply, socket |> put_flash(:info, gettext("The instance is cancelled.")) |> load()}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not cancel it."))}
    end
  end

  defp instance_call(socket, id, fun) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> fun.(socket.assigns.group, :any, socket.assigns.access, id)
      _invalid -> {:error, :not_found}
    end
  end

  ## Other people's changes

  @doc """
  What an `{:app_value, ...}` of the group means for the tab: whether the
  group has it, and a reload when it is on screen.
  """
  def app_value(socket, event) when event in @reloading_events do
    socket =
      if event in [:config, :drawn_process], do: assign_available(socket), else: socket

    if socket.assigns.active_tab == "processes" and not socket.assigns.processes_refresh? do
      Process.send_after(self(), {:processes, :refresh}, @debounce_ms)
      assign(socket, :processes_refresh?, true)
    else
      socket
    end
  end

  def app_value(socket, _event), do: socket

  def handle_info(:refresh, socket) do
    if socket.assigns.active_tab == "processes",
      do: {:noreply, load(socket)},
      else: {:noreply, assign(socket, :processes_refresh?, false)}
  end
end
