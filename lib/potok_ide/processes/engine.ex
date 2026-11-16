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

  A process drawn in Potok calls another (`callActivity`) in the step's
  transaction: the run it starts is one level deeper, at most 3, shares
  the caller's subject and gets the fields the call hands over, with the
  caller's name as `from`. A caller that waits holds the run it called
  (`awaiting`) until that run ends, which wakes it with what it ended with
  under the call's element (`results`), or until the call's deadline, which
  cancels the called run. Cancelling a run cancels the run it waits for, and
  a run that waits for one cancelled fails (`call_cancelled`). Locks are
  taken deeper runs first.

  A signal (`serviceTask` `signal`) is delivered in the step's transaction:
  the runs of the group's drawn processes that wait for it on a
  `receiveTask` just then get what it carries under that element and are
  due at once, at most 100, the oldest first, skipping one another node
  holds; and the active processes that start on it start, one level deeper
  and on the sender's subject, while there is depth left. A signal is not
  kept for a run that comes to wait later.

  A run reads its texts and conditions in the language of the graph it
  started with: today's (`"v" => 2`, `Expr` over the names of `Scope`) for
  a process drawn so, the first (`Legacy`) for every other.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PotokIde.{RateLimit, Repo}

  alias PotokIde.Processes.{
    Expr,
    Graph,
    GroupFields,
    Legacy,
    Scheduler,
    Scope,
    Triggers,
    ValueProcess
  }

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
  @max_depth 3
  # Runs other processes started that run or wait, for one process at a time.
  @max_called 200
  @max_field 1_000
  @max_result 8_192
  @max_woken 100

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

  defp app_process(%Value{} = value),
    do: value |> processes_of() |> where([p], not p.drawn) |> Repo.one()

  @doc """
  Starts an instance for `value` of every active process drawn in Potok on
  its collection (`PotokIde.Social.DrawnProcesses`), each with a copy of its
  graph, in the transaction that writes the value. They are read `FOR SHARE`,
  so a process being stopped waits for this write and then cancels what it
  started. Returns the instances.
  """
  def start_drawn(%Value{} = value, rule, %Profile{} = author) do
    started_by = if rule.anonymous, do: nil, else: author.id

    value
    |> processes_of()
    |> where([p], p.drawn and p.active and p.trigger == "value")
    |> order_by([p], asc: p.id)
    |> lock("FOR SHARE")
    |> Repo.all()
    |> Enum.map(&start_drawn_on(&1, value_id: value.id, started_by: started_by))
  end

  @doc """
  Starts an instance of the drawn `process` on its subject, in the caller's
  transaction: `attrs` holds `:value_id` or `:subject_group_id`, the `:data`
  its texts read when the subject is no value of a collection, and who set
  it going (`:started_by`, nil for a schedule, and `:triggered_by`, the same
  unless given). A run another process starts is `:depth` levels deep.
  """
  def start_drawn_on(%AppProcess{drawn: true} = process, attrs) do
    Repo.insert!(%ValueProcess{
      app_process_id: process.id,
      value_id: attrs[:value_id],
      subject_group_id: attrs[:subject_group_id],
      data: attrs[:data] || %{},
      status: :running,
      element: Graph.start(process.graph),
      graph: process.graph,
      started_by_id: attrs[:started_by],
      triggered_by_id: Keyword.get(attrs, :triggered_by, attrs[:started_by]),
      depth: attrs[:depth] || 0,
      wake_at: now()
    })
  end

  @doc """
  Starts the processes drawn in `group` on chat messages that `value`, just
  written by a person, sets going (`Triggers.matches_message?/3`), in the
  transaction that writes it. A reply in a thread, the root's chat and what
  a process writes start nothing. Returns the instances.
  """
  def start_on_message(
        %Value{parent_id: nil} = value,
        %Group{is_root: false} = group,
        %Profile{kind: :person} = author
      ) do
    case drawn_on(group, "message") do
      [] ->
        []

      processes ->
        manifest = Access.effective_manifest(group)

        role_keys =
          Map.new(if(manifest, do: manifest.roles, else: []), &{String.downcase(&1.name), &1.key})

        for process <- processes,
            Triggers.matches_message?(process.trigger_config, value, role_keys) do
          start_drawn_on(process,
            value_id: value.id,
            started_by: author.id,
            data: %{"text" => value.content || "", "author" => author.username}
          )
        end
    end
  end

  def start_on_message(_value, _group, _author), do: []

  @doc """
  Starts the processes drawn in `parent` on new sub-groups for `child`, just
  made by a person or an app in the transaction that makes it. Returns the
  instances.
  """
  def start_on_subgroup(%Group{} = child, %Group{} = parent, %Profile{kind: :person} = creator) do
    for process <- drawn_on(parent, "subgroup"),
        not process.trigger_config["placed"] or not is_nil(child.latitude) do
      start_drawn_on(process,
        subject_group_id: child.id,
        started_by: creator.id,
        data: %{
          "name" => child.name,
          "description" => plain_text(child.description),
          "author" => creator.username
        }
      )
    end
  end

  def start_on_subgroup(_child, _parent, _creator), do: []

  @doc """
  Starts the scheduled processes whose time has come, at most `limit`, each
  once, and sets when each starts next. A run more than a day late, after the
  servers were down, is skipped. Rows are taken `FOR UPDATE SKIP LOCKED`, so
  two servers never start one twice. Returns how many started.
  """
  def start_scheduled(limit \\ 200) do
    now = now()

    {:ok, started} =
      Repo.transaction(fn ->
        from(p in AppProcess,
          where:
            p.drawn and p.active and p.trigger == "schedule" and not is_nil(p.next_run_at) and
              p.next_run_at <= ^now,
          order_by: [asc: p.next_run_at],
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()
        |> Enum.count(fn process ->
          due = process.next_run_at
          fresh? = DateTime.diff(now, due) < 86_400

          if fresh?,
            do: start_drawn_on(process, data: Triggers.schedule_data(process.trigger_config, due))

          process
          |> Ecto.Changeset.change(next_run_at: Triggers.next_run(process.trigger_config, now))
          |> Repo.update!()

          fresh?
        end)
      end)

    started
  end

  # The active processes drawn in a group on a trigger, read `FOR SHARE`, so
  # one being switched off waits for this write and then cancels what it
  # started.
  defp drawn_on(%Group{id: group_id}, trigger) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn and p.active and p.trigger == ^trigger,
      order_by: [asc: p.id],
      lock: "FOR SHARE"
    )
    |> Repo.all()
  end

  # A description's text without its markup, cut short, for a text's field.
  defp plain_text(nil), do: ""

  defp plain_text(text) do
    text
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/[#*_>`\[\]]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp processes_of(%Value{group_id: group_id, collection: collection} = value) do
    query = from(p in AppProcess, where: p.group_id == ^group_id and p.collection == ^collection)

    case value.alt_description_id do
      nil -> where(query, [p], is_nil(p.alt_description_id))
      alt_id -> where(query, [p], p.alt_description_id == ^alt_id)
    end
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
          id: instance.id,
          drawn: process.drawn
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

      {:wait, changes, announcements} ->
        {:stop, update!(instance, Map.put(changes, :status, :waiting)), announcements}

      :done ->
        done = update!(instance, %{status: :done, wake_at: nil})
        {:stop, done, returned(done, node)}

      {:error, reason} ->
        Repo.rollback({:failed, instance.element, reason})
    end
  end

  defp act(%{"type" => "startEvent", "id" => id}, instance),
    do: {:next, plain_next(instance, id), %{}, []}

  defp act(%{"type" => "endEvent"}, _instance), do: :done

  defp act(%{"type" => "userTask"} = task, _instance),
    do: {:wait, %{wake_at: task["deadline"] && later(task["deadline"])}, []}

  defp act(%{"type" => "timer", "duration" => duration}, _instance),
    do: {:wait, %{wake_at: later(duration)}, []}

  defp act(%{"type" => "receiveTask", "id" => id} = receive, instance) do
    {:wait,
     %{
       wake_at: receive["deadline"] && later(receive["deadline"]),
       results: Map.delete(instance.results, id)
     }, []}
  end

  defp act(%{"type" => "callActivity", "id" => id} = call, instance) do
    process = Repo.get!(AppProcess, instance.app_process_id)

    with :ok <- if(process.active, do: :ok, else: {:error, :process_inactive}),
         :ok <- if(instance.depth < @max_depth, do: :ok, else: {:error, :too_deep}),
         {:ok, callee} <- callee(call["process"], process.group_id),
         :ok <- room(callee) do
      data = value_data(instance)

      fields =
        for name <- callee.trigger_config["fields"] || [], into: %{} do
          {name, (call["fields"][name] || "") |> render(data) |> String.slice(0, @max_field)}
        end

      child =
        start_drawn_on(callee,
          value_id: instance.value_id,
          subject_group_id: instance.subject_group_id,
          started_by: instance.started_by_id,
          triggered_by: instance.triggered_by_id,
          depth: instance.depth + 1,
          data: Map.put(fields, "from", process.name)
        )

      announcements = [fn -> Scheduler.nudge() end, fn -> tell(child) end]

      if call["wait"] == false do
        {:next, plain_next(instance, id), %{}, announcements}
      else
        {:wait,
         %{
           wake_at: call["deadline"] && later(call["deadline"]),
           awaiting_id: child.id,
           results: Map.delete(instance.results, id)
         }, announcements}
      end
    end
  end

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

  # A signal: the runs waiting for it in the group wake, and the processes
  # that start on it start.
  defp service("signal", task, step, group, instance, data) do
    if step.process.active do
      name = task["name"]

      fields =
        for %{"name" => field, "value" => value} <- task["fields"] || [], into: %{} do
          {field, value |> render(data) |> String.slice(0, @max_field)}
        end

      carried = Map.merge(fields, %{"from" => step.process.name, "signal" => name})
      woken = wake_receivers(group, instance, name, carried)
      started = start_on_signal(group, instance, name, carried)

      {:ok, %{},
       fn ->
         Scheduler.nudge()
         Enum.each(woken, &tell(Repo.get(ValueProcess, &1)))
         Enum.each(started, &tell/1)
       end}
    else
      {:error, :process_inactive}
    end
  end

  # A field of the group, which every drawn process of it reads.
  defp service("set", task, step, _group, _instance, data) do
    value = render(task["value"], data)

    result =
      cond do
        not step.process.active -> {:error, :process_inactive}
        task["op"] == "add" -> GroupFields.add(step.process, task["field"], value)
        true -> GroupFields.put(step.process, task["field"], value)
      end

    case result do
      {:ok, _field} -> {:ok, %{}, fn -> :ok end}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_field}
      {:error, _reason} = error -> error
    end
  end

  # The runs of the group's drawn processes that wait for the signal now:
  # those that wait for it on the same subject only when the sender has one.
  # Their rows are taken without waiting, so a run in a step of its own just
  # now misses it, as one that comes to wait later does.
  defp wake_receivers(%Group{id: group_id}, %ValueProcess{} = sender, name, carried) do
    same_subject =
      cond do
        sender.value_id -> dynamic([i], i.value_id == ^sender.value_id)
        sender.subject_group_id -> dynamic([i], i.subject_group_id == ^sender.subject_group_id)
        true -> false
      end

    any_subject =
      dynamic(
        [i],
        not fragment(
          "jsonb_path_exists(?, '$.nodes[*] \\? (@.id == $e && @.same_subject == true)', jsonb_build_object('e', ?))",
          i.graph,
          i.element
        )
      )

    ids =
      from(i in ValueProcess,
        join: p in AppProcess,
        on: p.id == i.app_process_id,
        where:
          p.group_id == ^group_id and p.drawn and p.active and i.status == :waiting and
            i.id != ^sender.id,
        where:
          fragment(
            "jsonb_path_exists(?, '$.nodes[*] \\? (@.id == $e && @.type == \"receiveTask\" && @.signal == $s)', jsonb_build_object('e', ?, 's', ?::text))",
            i.graph,
            i.element,
            ^name
          ),
        where: fragment("(? -> ?) IS NULL", i.results, i.element),
        where: ^dynamic([i], ^any_subject or ^same_subject),
        order_by: [asc: i.id],
        limit: @max_woken,
        lock: "FOR UPDATE OF v0 SKIP LOCKED",
        select: i.id
      )
      |> Repo.all()

    now = now()

    from(i in ValueProcess,
      where: i.id in ^ids,
      update: [
        set: [
          results:
            fragment("? || jsonb_build_object(?, ?::jsonb)", i.results, i.element, ^carried),
          wake_at: ^now,
          updated_at: ^now
        ]
      ]
    )
    |> Repo.update_all([])

    ids
  end

  # The active processes of the group that start on the signal, each a run
  # one level deeper on the sender's subject, while there is depth and room.
  defp start_on_signal(group, %ValueProcess{depth: depth} = sender, name, carried)
       when depth < @max_depth do
    for process <- drawn_on(group, "signal"),
        process.trigger_config["name"] == name,
        room(process) == :ok do
      start_drawn_on(process,
        value_id: sender.value_id,
        subject_group_id: sender.subject_group_id,
        started_by: sender.started_by_id,
        triggered_by: sender.triggered_by_id,
        depth: depth + 1,
        data: carried
      )
    end
  end

  defp start_on_signal(_group, _sender, _name, _carried), do: []

  # The process a call starts, read `FOR SHARE`, so one being switched off
  # waits for this step and then cancels what it started.
  defp callee(id, group_id) when is_integer(id) do
    from(p in AppProcess,
      where: p.id == ^id and p.group_id == ^group_id and p.drawn and p.trigger == "process",
      lock: "FOR SHARE"
    )
    |> Repo.one()
    |> case do
      %AppProcess{active: true} = callee -> {:ok, callee}
      %AppProcess{} -> {:error, :call_inactive}
      nil -> {:error, :call_unknown}
    end
  end

  defp callee(_id, _group_id), do: {:error, :call_unknown}

  defp room(%AppProcess{id: id}) do
    running =
      from(i in ValueProcess,
        where: i.app_process_id == ^id and i.status in [:running, :waiting] and i.depth > 0
      )
      |> Repo.aggregate(:count)

    if running < @max_called, do: :ok, else: {:error, :too_many_runs}
  end

  # A run another started has ended: the run that waits for it, if any, hears
  # what it ended with, in the same transaction.
  defp returned(%ValueProcess{depth: 0}, _end), do: []

  defp returned(%ValueProcess{} = child, end_node) do
    from(i in ValueProcess,
      where: i.awaiting_id == ^child.id and i.status == :waiting,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      nil ->
        []

      caller ->
        result = result(child, Graph.label(end_node))

        caller =
          update!(caller, %{
            results: Map.put(caller.results, caller.element, result),
            awaiting_id: nil,
            wake_at: now()
          })

        [fn -> Scheduler.nudge() end, fn -> tell(caller) end]
    end
  end

  # What a called run ended with: the end it reached, the fields it was given
  # and what its waits brought back, or only the end when that is too much.
  defp result(%ValueProcess{} = child, outcome) do
    result =
      child.data
      |> Map.merge(child.results)
      |> Map.delete("from")
      |> Map.put("outcome", outcome)

    if byte_size(JSON.encode!(result)) <= @max_result, do: result, else: %{"outcome" => outcome}
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
  # A call goes on by its plain flow once the run it called has ended, set
  # off by whoever set off the call.
  defp wake(%ValueProcess{} = instance) do
    out = Graph.out(instance.graph, instance.element)

    case Graph.node(instance.graph, instance.element) do
      %{"type" => "userTask"} ->
        deadline(instance, Enum.find(out, & &1["deadline"]))

      %{"type" => "timer"} ->
        deadline(instance, hd(out))

      %{"type" => "callActivity", "id" => id} ->
        if Map.has_key?(instance.results, id),
          do: {:continue, move(instance, plain(out)["to"], %{}), []},
          else: call_deadline(instance, Enum.find(out, & &1["deadline"]))

      # A signal came, set off by no one person.
      %{"type" => "receiveTask", "id" => id} ->
        if Map.has_key?(instance.results, id),
          do: {:continue, move(instance, plain(out)["to"], %{triggered_by_id: nil}), []},
          else: deadline(instance, Enum.find(out, & &1["deadline"]))

      _other ->
        :skip
    end
  end

  defp deadline(_instance, nil), do: :skip

  defp deadline(instance, flow),
    do: {:continue, move(instance, flow["to"], %{triggered_by_id: nil}), []}

  # The call's deadline cancels the run it waits for, unless that run is in a
  # step of its own just now, which may end it: the next pass sees.
  defp call_deadline(_instance, nil), do: :skip

  defp call_deadline(instance, flow) do
    case cancel_awaited(instance) do
      {:ok, cancelled} ->
        moved = move(instance, flow["to"], %{triggered_by_id: nil, awaiting_id: nil})
        {:continue, moved, Enum.map(cancelled, fn run -> fn -> tell(run) end end)}

      :busy ->
        :skip
    end
  end

  # The runs `instance` waits for, down the chain, cancelled without waiting
  # for a lock; `:busy` when one is held.
  defp cancel_awaited(%ValueProcess{awaiting_id: nil}), do: {:ok, []}

  defp cancel_awaited(%ValueProcess{awaiting_id: id}) do
    chain = awaited_chain(id)

    locked =
      from(i in ValueProcess, where: i.id in ^chain, lock: "FOR UPDATE SKIP LOCKED")
      |> Repo.all()

    if length(locked) == length(chain),
      do: {:ok, Enum.map(locked, &cancelled!/1)},
      else: :busy
  end

  defp plain(flows), do: Enum.find(flows, &(not Map.has_key?(&1, "deadline")))

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
            log: Enum.take(instance.log ++ [entry], -@max_log),
            results:
              Map.put(instance.results, element, %{
                "outcome" => outcome,
                "comment" => entry["comment"],
                "by" => profile.username
              })
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

  @doc """
  Cancels an instance that runs, waits or has failed, with the runs it waits
  for; a run that waits for it fails (`call_cancelled`).
  """
  def cancel(id) do
    Repo.transaction(fn ->
      # Deeper runs first, as a run that ends locks the one waiting for it.
      chain = id |> awaiting_of() |> awaited_chain()
      Enum.each(Enum.reverse(chain), &lock/1)

      case lock(id) do
        %ValueProcess{status: status} = instance when status in [:running, :waiting, :failed] ->
          below = Enum.flat_map(chain, &List.wrap(cancel_live(&1)))
          instance = cancelled!(instance)
          {instance, below ++ fail_callers([instance.id])}

        _other ->
          Repo.rollback(:not_running)
      end
    end)
    |> case do
      {:ok, {instance, others}} ->
        Enum.each(others, &tell/1)
        {:ok, tell(instance)}

      error ->
        error
    end
  end

  @doc """
  Cancels every instance of a process that runs or waits, as its rule goes
  (`PotokIde.Social.AppProcesses`), with the runs they wait for; the runs
  that wait for one of its instances fail (`call_cancelled`), also for one
  that had failed. Returns how many of its own it cancelled.
  """
  def cancel_all(%AppProcess{id: id}) do
    own =
      from(i in ValueProcess,
        where: i.app_process_id == ^id and i.status in [:running, :waiting],
        select: i.id
      )
      |> Repo.all()

    below = own |> Enum.flat_map(&(&1 |> awaiting_of() |> awaited_chain())) |> Enum.uniq()
    below = below -- own
    lock_deepest_first(below)
    lock_deepest_first(own)

    from(i in ValueProcess,
      where: i.id in ^below and i.status in [:running, :waiting, :failed]
    )
    |> Repo.update_all(
      set: [status: :cancelled, wake_at: nil, awaiting_id: nil, updated_at: now()]
    )

    {count, _} =
      from(i in ValueProcess, where: i.id in ^own and i.status in [:running, :waiting])
      |> Repo.update_all(
        set: [status: :cancelled, wake_at: nil, awaiting_id: nil, updated_at: now()]
      )

    failed =
      from(i in ValueProcess,
        where: i.app_process_id == ^id and i.status == :failed,
        select: i.id
      )
      |> Repo.all()

    fail_callers(own ++ failed)
    count
  end

  defp lock_deepest_first([]), do: :ok

  defp lock_deepest_first(ids) do
    from(i in ValueProcess,
      where: i.id in ^ids,
      order_by: [desc: i.depth, asc: i.id],
      lock: "FOR UPDATE",
      select: i.id
    )
    |> Repo.all()

    :ok
  end

  defp awaiting_of(id),
    do: from(i in ValueProcess, where: i.id == ^id, select: i.awaiting_id) |> Repo.one()

  # The run `id` and those it waits for in turn, the nearest first.
  defp awaited_chain(id, depth \\ 0)
  defp awaited_chain(nil, _depth), do: []
  defp awaited_chain(_id, depth) when depth > @max_depth, do: []
  defp awaited_chain(id, depth), do: [id | awaited_chain(awaiting_of(id), depth + 1)]

  # A locked run, cancelled when it still runs, waits or has failed.
  defp cancel_live(id) do
    case Repo.get(ValueProcess, id) do
      %ValueProcess{status: status} = run when status in [:running, :waiting, :failed] ->
        cancelled!(run)

      _done_or_gone ->
        nil
    end
  end

  defp cancelled!(%ValueProcess{} = run),
    do: update!(run, %{status: :cancelled, wake_at: nil, awaiting_id: nil})

  # The runs that wait for one of `ids` fail where they wait.
  defp fail_callers(ids) do
    from(i in ValueProcess,
      where: i.awaiting_id in ^ids and i.status == :waiting,
      order_by: [desc: i.depth, asc: i.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.map(fn caller ->
      update!(caller, %{
        status: :failed,
        wake_at: nil,
        awaiting_id: nil,
        error: %{"element" => caller.element, "reason" => "call_cancelled"}
      })
    end)
  end

  # ---------
  # Values
  # ---------

  # What a run's texts and conditions read, in the language of its graph.
  #
  # Today's (`"v" => 2`) reads by name (`Scope`): what set the run going
  # under the id of its start, what each wait brought back under its
  # element's id, and the fields of the group under `group`, each as its
  # type says.
  #
  # The first reads the fields kept with the run, or the data of its value
  # of a collection, as it is now, and what its waits brought back
  # (`results`), which never hide a field of either; and for a drawn
  # process, the fields of its group under `group`.
  defp value_data(%ValueProcess{graph: %{"v" => 2} = graph, results: results} = instance) do
    values =
      (results || %{})
      |> Map.put(Graph.start(graph), base_data(instance))
      |> Map.put("group", GroupFields.for_process(instance.app_process_id))

    {:names, Scope.load(values, graph), %{zone: graph["zone"], now: now()}}
  end

  defp value_data(%ValueProcess{results: results} = instance) do
    data = Map.merge(results || %{}, base_data(instance))

    case GroupFields.for_process(instance.app_process_id) do
      fields when map_size(fields) == 0 -> {:fields, data}
      fields -> {:fields, Map.put(data, "group", fields)}
    end
  end

  # A run another process started reads only the fields it was given.
  defp base_data(%ValueProcess{depth: depth, data: data}) when depth > 0, do: data || %{}
  defp base_data(%ValueProcess{data: data}) when is_map(data) and map_size(data) > 0, do: data
  defp base_data(%ValueProcess{value_id: nil}), do: %{}

  defp base_data(%ValueProcess{value_id: value_id}) do
    case Repo.get(Value, value_id) do
      %Value{data: data} when is_map(data) -> data
      _none -> %{}
    end
  end

  # A text with what the run holds put in. An expression that cannot be
  # worked out, such as a division by nothing, fails the step with why.
  defp render(text, {:fields, data}), do: Legacy.render(text, data)

  defp render(text, {:names, data, opts}) do
    with {:ok, parts} <- Expr.template(text),
         {:ok, text} <- Expr.render(parts, data, opts) do
      text
    else
      {:error, reason} -> Repo.rollback({:failed, nil, expression_error(reason)})
    end
  end

  defp holds?(condition, {:fields, data}), do: Legacy.holds?(condition, data)

  defp holds?(%{"expr" => expression}, {:names, data, opts}) do
    with {:ok, tree} <- Expr.parse(expression),
         {:ok, value} <- Expr.eval(tree, data, opts) do
      value in [true, "true"]
    else
      {:error, reason} -> Repo.rollback({:failed, nil, expression_error(reason)})
    end
  end

  # A graph is checked when it is saved, so only what it holds can fail it.
  defp expression_error(reason) when is_atom(reason), do: reason
  defp expression_error(_syntax), do: :bad_expression

  defp later(duration), do: DateTime.add(now(), Graph.seconds(duration), :second)

  defp now, do: DateTime.utc_now(:second)
end
