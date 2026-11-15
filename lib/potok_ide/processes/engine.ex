defmodule PotokIde.Processes.Engine do
  @moduledoc """
  Runs the instances of apps' processes (`ValueProcess`) over their graphs
  (`Graph`), doing what they say through `PotokIde.Social.ProcessActions`.

  - A new value of a collection whose process has a graph starts an instance
    in the transaction that writes the value (`start/3`), due at once.
  - Each element runs in a transaction of its own, with the instance's move to
    the next, so what it writes happens exactly once; a crash leaves the
    instance on the element, to be done again. What the actions did is
    announced after each commit.
  - An instance stops on a `userTask` until someone holding its role picks an
    outcome (`complete_task/5`) or its deadline passes, and on a `timer` until
    it is due. `run_due/1` takes forward those whose time has come.
  - An action that fails rolls back its element and leaves the instance
    failed, with the element and the reason, for an editor to `retry/1`.
  - At most 25 elements in one run without waiting and 1,000 in an
    instance's life, so a loop stops; at most what `RateLimit` lets one
    process take in a minute, the rest waiting for the next pass. A step
    that raises leaves the instance failed (`crash`) rather than tried again
    on every pass.

  Who set off the step on hand (`triggered_by`) is the value's author at the
  start (nobody for an anonymous value), whoever finished a task, and nobody
  after a timer or a deadline.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PotokIde.{RateLimit, Repo}
  alias PotokIde.Processes.{Graph, ValueProcess}

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    Group,
    ProcessActions,
    ProcessStep,
    Profile,
    Value
  }

  @max_run 25
  @max_steps 1_000
  @max_log 200
  @max_comment 1_000
  @max_group_name 120
  @max_push_text 240
  @placeholder ~r/\{\{\s*([\p{L}\p{Nd}_.-]+)\s*\}\}/u

  # ---------
  # Starting
  # ---------

  @doc """
  Starts an instance for `value`, just written to a collection whose rule
  (`ValueRules.rule/2`) has a process with a graph, inside the transaction
  that writes it. Returns the instance, or nil when there is no graph or the
  process does not run.
  """
  def start(%Value{} = value, %{process: %{"graph" => graph}} = rule, %Profile{} = author) do
    case app_process(value) do
      %AppProcess{active: true} = process ->
        started_by = if rule.anonymous, do: nil, else: author.id

        Repo.insert!(%ValueProcess{
          app_process_id: process.id,
          value_id: value.id,
          status: :running,
          element: Graph.start(graph),
          graph: graph,
          started_by_id: started_by,
          triggered_by_id: started_by,
          wake_at: now()
        })

      _none_or_stopped ->
        nil
    end
  end

  def start(%Value{}, _rule, _author), do: nil

  defp app_process(%Value{group_id: group_id, collection: collection} = value) do
    query = from(p in AppProcess, where: p.group_id == ^group_id and p.collection == ^collection)

    query =
      case value.alt_description_id do
        nil -> where(query, [p], is_nil(p.alt_description_id))
        alt_id -> where(query, [p], p.alt_description_id == ^alt_id)
      end

    Repo.one(query)
  end

  # ---------
  # Running
  # ---------

  @doc """
  Takes the instances that are due forward, the longest due first, at most
  `limit` of them. Returns how many it took up.
  """
  def run_due(limit \\ 200) do
    from(i in ValueProcess,
      where: i.status in [:running, :waiting] and i.wake_at <= ^now(),
      order_by: [asc: i.wake_at, asc: i.id],
      limit: ^limit,
      select: i.id
    )
    |> Repo.all()
    |> Enum.count(&run/1)
  end

  @doc """
  Takes the instance forward while it can: element after element until it
  waits on a task or a timer, ends or fails. Returns the instance as it then
  stands, or nil when another node holds it, it is gone, or nothing was due.
  """
  def run(id) when is_integer(id), do: run(id, @max_run, nil)

  defp run(id, budget, last) do
    case guarded(id, budget) do
      {:ok, {:continue, _instance, announcements}} ->
        ProcessActions.announce(announcements)
        run(id, budget - 1, :moved)

      {:ok, {:stop, instance, announcements}} ->
        ProcessActions.announce(announcements)
        tell(instance)

      {:ok, :skip} ->
        if last == :moved, do: tell(Repo.get(ValueProcess, id))

      {:error, {:failed, element, reason}} ->
        id |> fail(element, reason) |> tell()
    end
  end

  # The app's open pages hear that an instance moved, and read it again.
  defp tell(nil), do: nil

  defp tell(%ValueProcess{} = instance) do
    case Repo.get(AppProcess, instance.app_process_id) do
      %AppProcess{} = process ->
        AppData.broadcast(%Group{id: process.group_id}, :process, %{
          alt_id: process.alt_description_id,
          collection: process.collection,
          id: instance.id
        })

      nil ->
        :ok
    end

    instance
  end

  defp told({:ok, instance}), do: {:ok, tell(instance)}
  defp told(error), do: error

  defp guarded(id, budget) do
    Repo.transaction(fn -> step(id, budget) end)
  rescue
    exception ->
      Logger.error(
        "Process instance #{id} crashed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:failed, nil, :crash}}
  end

  # One element, or the end of a wait, in the transaction of the caller.
  defp step(id, budget) do
    case try_lock(id) do
      %ValueProcess{status: :running} = instance ->
        cond do
          budget <= 0 ->
            Repo.rollback({:failed, instance.element, :loop})

          instance.steps >= @max_steps ->
            Repo.rollback({:failed, instance.element, :too_many_steps})

          held_back?(instance) ->
            :skip

          true ->
            execute(instance)
        end

      %ValueProcess{status: :waiting, wake_at: %DateTime{} = at} = instance ->
        if DateTime.compare(at, now()) == :gt, do: :skip, else: wake(instance)

      _held_gone_or_still ->
        :skip
    end
  end

  # The instance, unless another node holds it: that node takes it on.
  defp try_lock(id),
    do: from(i in ValueProcess, where: i.id == ^id, lock: "FOR UPDATE SKIP LOCKED") |> Repo.one()

  defp lock(id), do: from(i in ValueProcess, where: i.id == ^id, lock: "FOR UPDATE") |> Repo.one()

  # Over its share of steps, the process waits for the next pass.
  defp held_back?(%ValueProcess{app_process_id: id}),
    do: match?({:error, :rate_limited, _}, RateLimit.hit(:process_step, id))

  defp execute(%ValueProcess{} = instance) do
    node = Graph.node(instance.graph, instance.element)

    case act(node, instance) do
      {:next, to, changes, announcements} ->
        {:continue, move(instance, to, changes), announcements}

      {:wait, changes} ->
        {:stop, update!(instance, Map.put(changes, :status, :waiting)), []}

      :done ->
        {:stop, update!(instance, %{status: :done, wake_at: nil}), []}

      {:error, reason} ->
        Repo.rollback({:failed, instance.element, reason})
    end
  end

  defp act(%{"type" => "startEvent", "id" => id}, instance),
    do: {:next, plain_next(instance, id), %{}, []}

  defp act(%{"type" => "endEvent"}, _instance), do: :done

  defp act(%{"type" => "userTask"} = task, _instance),
    do: {:wait, %{wake_at: task["deadline"] && later(task["deadline"])}}

  defp act(%{"type" => "timer", "duration" => duration}, _instance),
    do: {:wait, %{wake_at: later(duration)}}

  defp act(%{"type" => "exclusiveGateway", "id" => id}, instance) do
    data = value_data(instance)
    flows = Graph.out(instance.graph, id)

    flow =
      Enum.find(flows, &(&1["condition"] && holds?(&1["condition"], data))) ||
        Enum.find(flows, & &1["default"])

    {:next, flow["to"], %{}, []}
  end

  defp act(%{"type" => "serviceTask", "action" => action, "id" => id} = task, instance) do
    process = Repo.get!(AppProcess, instance.app_process_id)
    group = Repo.get!(Group, process.group_id)
    step = process_step(instance, process)
    data = value_data(instance)

    case service(action, task, step, group, instance, data) do
      {:ok, changes, announce} -> {:next, plain_next(instance, id), changes, [announce]}
      {:error, _reason} = error -> error
    end
  end

  defp service("message", task, step, group, instance, data) do
    text = render(task["text"], data)

    with {:ok, target} <- target(task["in"], group, instance),
         :ok <- if(text == "", do: {:error, :empty_text}, else: :ok),
         {:ok, _value, announce} <- ProcessActions.post_value(step, target, %{"content" => text}) do
      {:ok, %{}, announce}
    end
  end

  defp service("subgroup", task, step, group, instance, data) do
    name = task["name"] |> render(data) |> String.slice(0, @max_group_name)
    name = if name == "", do: step.process.name, else: name

    with {:ok, sub, announce} <-
           ProcessActions.create_subgroup(step, group, %{"name" => name}, task["admins"]) do
      {:ok, %{groups: Map.put(instance.groups, task["id"], sub.id)}, announce}
    end
  end

  defp service("push", task, step, group, _instance, data) do
    text = task["text"] |> render(data) |> String.slice(0, @max_push_text)

    with {:ok, _count, announce} <- ProcessActions.push(step, group, task["role"], text) do
      {:ok, %{}, announce}
    end
  end

  # A message goes to the app's group or to a sub-group the instance made.
  defp target("app", group, _instance), do: {:ok, group}

  defp target(element, _group, %ValueProcess{groups: groups}) do
    with id when is_integer(id) <- Map.get(groups, element),
         %Group{} = sub <- Repo.get(Group, id) do
      {:ok, sub}
    else
      _gone -> {:error, :no_subgroup}
    end
  end

  defp process_step(%ValueProcess{} = instance, %AppProcess{} = process) do
    %ProcessStep{
      process: process,
      instance: instance.id,
      element: instance.element,
      triggered_by: instance.triggered_by_id,
      groups: Map.values(instance.groups)
    }
  end

  # A deadline or a timer is due: the instance goes on, set off by nobody.
  defp wake(%ValueProcess{} = instance) do
    flow =
      case Graph.node(instance.graph, instance.element) do
        %{"type" => "userTask"} ->
          Enum.find(Graph.out(instance.graph, instance.element), & &1["deadline"])

        %{"type" => "timer"} ->
          hd(Graph.out(instance.graph, instance.element))

        _other ->
          nil
      end

    if flow,
      do: {:continue, move(instance, flow["to"], %{triggered_by_id: nil}), []},
      else: :skip
  end

  defp plain_next(%ValueProcess{graph: graph}, id), do: hd(Graph.out(graph, id))["to"]

  defp move(%ValueProcess{} = instance, to, changes) do
    update!(
      instance,
      Map.merge(
        %{element: to, status: :running, wake_at: now(), steps: instance.steps + 1},
        changes
      )
    )
  end

  defp update!(%ValueProcess{} = instance, changes),
    do: instance |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp fail(id, element, reason) do
    {:ok, instance} =
      Repo.transaction(fn ->
        case lock(id) do
          nil ->
            nil

          instance ->
            update!(instance, %{
              status: :failed,
              wake_at: nil,
              error: %{"element" => element || instance.element, "reason" => reason_text(reason)}
            })
        end
      end)

    instance
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(%Ecto.Changeset{}), do: "invalid"
  defp reason_text(_reason), do: "error"

  # ---------
  # People and editors
  # ---------

  @doc """
  Finishes the task an instance waits on, as `profile` picks `outcome`: only
  someone holding the task's role in the app's group, only while the instance
  waits on that very `element`, and only an outcome of the graph. Whoever
  finished it sets off the steps that follow, and the log keeps who it was.
  Returns `{:ok, instance}`, moved on and due; the caller runs it or leaves it
  to the scheduler.
  """
  def complete_task(%Profile{} = profile, id, element, outcome, comment \\ nil) do
    Repo.transaction(fn ->
      instance = lock(id) || Repo.rollback(:not_found)
      task = Graph.node(instance.graph, instance.element)

      cond do
        instance.status != :waiting or instance.element != element or
            task["type"] != "userTask" ->
          Repo.rollback(:not_waiting)

        outcome not in task["outcomes"] ->
          Repo.rollback(:invalid_outcome)

        true ->
          process = Repo.get!(AppProcess, instance.app_process_id)

          unless process.active, do: Repo.rollback(:process_inactive)

          access = Access.for_profile(profile, Repo.get!(Group, process.group_id))

          unless task["role"] in access.role_keys, do: Repo.rollback(:not_permitted)

          flow = Enum.find(Graph.out(instance.graph, element), &(&1["outcome"] == outcome))

          entry = %{
            "at" => DateTime.to_iso8601(now()),
            "element" => element,
            "outcome" => outcome,
            "by" => profile.id,
            "comment" => comment_text(comment)
          }

          move(instance, flow["to"], %{
            triggered_by_id: profile.id,
            log: Enum.take(instance.log ++ [entry], -@max_log)
          })
      end
    end)
    |> told()
  end

  defp comment_text(comment) when is_binary(comment) do
    case String.trim(comment) do
      "" -> nil
      text -> String.slice(text, 0, @max_comment)
    end
  end

  defp comment_text(_comment), do: nil

  @doc "Takes a failed instance up again on the element where it stopped, due at once."
  def retry(id) do
    Repo.transaction(fn ->
      case lock(id) do
        %ValueProcess{status: :failed} = instance ->
          update!(instance, %{status: :running, error: nil, wake_at: now()})

        _other ->
          Repo.rollback(:not_failed)
      end
    end)
    |> told()
  end

  @doc "Cancels an instance that runs or waits."
  def cancel(id) do
    Repo.transaction(fn ->
      case lock(id) do
        %ValueProcess{status: status} = instance when status in [:running, :waiting] ->
          update!(instance, %{status: :cancelled, wake_at: nil})

        _other ->
          Repo.rollback(:not_running)
      end
    end)
    |> told()
  end

  @doc """
  Cancels every instance of a process that runs or waits, as its rule goes
  (`PotokIde.Social.AppProcesses`). Returns how many.
  """
  def cancel_all(%AppProcess{id: id}) do
    {count, _} =
      from(i in ValueProcess, where: i.app_process_id == ^id and i.status in [:running, :waiting])
      |> Repo.update_all(set: [status: :cancelled, wake_at: nil, updated_at: now()])

    count
  end

  # ---------
  # Values
  # ---------

  defp value_data(%ValueProcess{value_id: value_id}) do
    case Repo.get(Value, value_id) do
      %Value{data: data} when is_map(data) -> data
      _none -> %{}
    end
  end

  # Fields of the value in a text, such as `{{naslov}}`; nothing else.
  defp render(text, data) do
    @placeholder
    |> Regex.replace(text, fn _whole, field -> field_text(field(data, field)) end)
    |> String.trim()
  end

  defp field(data, path) do
    path
    |> String.split(".")
    |> Enum.reduce(data, fn key, acc -> if is_map(acc), do: Map.get(acc, key) end)
  end

  defp field_text(value) when is_binary(value), do: value
  defp field_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp field_text(_value), do: ""

  defp holds?(%{"op" => "empty", "field" => field}, data),
    do: field(data, field) in [nil, "", [], %{}] or blank?(field(data, field))

  defp holds?(%{"op" => op, "field" => field, "value" => expected}, data) do
    actual = field(data, field)

    case op do
      "=" -> same?(actual, expected)
      "!=" -> not same?(actual, expected)
      "<" -> compare(actual, expected) == :lt
      ">" -> compare(actual, expected) == :gt
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp same?(actual, expected) do
    case {number(actual), number(expected)} do
      {a, b} when is_number(a) and is_number(b) -> a == b
      _otherwise -> field_text(actual) |> String.trim() == field_text(expected) |> String.trim()
    end
  end

  defp compare(actual, expected) do
    case {number(actual), number(expected)} do
      {a, b} when is_number(a) and is_number(b) ->
        if(a < b, do: :lt, else: if(a > b, do: :gt, else: :eq))

      _not_numbers ->
        nil
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp number(_value), do: nil

  defp later(duration), do: DateTime.add(now(), Graph.seconds(duration), :second)

  defp now, do: DateTime.utc_now(:second)
end
