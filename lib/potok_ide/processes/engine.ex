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
  - At most 25 elements in a row without waiting and 5,000 in an
    instance's life, so a drawing that runs in a circle stops (`loop`,
    `too_many_steps`). After 100 elements `run/1` leaves the instance due
    and asks the scheduler for a pass, so one long run gives way to the
    others. The steps that write outside the run (a message, a sub-group, a
    push, a field of the group, a signal, a call) are at most what
    `RateLimit` lets one process take in a minute, the rest waiting, out of
    the passes, until the minute turns. A step that raises leaves the instance failed (`crash`)
    rather than tried again on every pass.

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

  A call reaches a process of the caller's group, or a public one of a
  group above or below it (`Reach`). A run started in another group gets
  what the call hands over and nothing else: it has no subject and nobody
  set it off, as the caller's value and people are no part of that group,
  and the caller hears only which end it reached. A caller whose called
  run is gone, with its process or its group, fails as one whose run was
  cancelled (`fail_orphaned_calls/1`).

  A signal (`serviceTask` `signal`) is delivered in the step's transaction:
  the runs of the group's drawn processes that wait for it on a
  `receiveTask` just then get what it carries under that element and are
  due at once, at most 100, the oldest first, skipping one another node
  holds; and the active processes that start on it start, one level deeper
  and on the sender's subject, while there is depth left. A signal is not
  kept for a run that comes to wait later.

  A run reads its texts and conditions in the language of the graph it
  started with: today's (`"v" => 2`, `Expr` over the names of `Scope`) for
  a process drawn so, the first (`Legacy`) for every other. In today's a
  run keeps variables (`vars`): those that start with a value get it on the
  start element, and a `serviceTask` `assign` sets one, or an attribute of
  one, to what an expression gives, as the type of the target takes it
  (`Types.cast/4`), or adds it to the list the target holds (`append`).
  Variables and results together hold at most 64 KB.

  A `loop` reads its list once, on the way in, and keeps it with where it
  stands under its own element (`results`): at most 200 items. Each turn
  hands the body the next item, as a variable by the loop's `item`, and
  starts the count of 25 elements in a row anew; after the last item the
  run goes on by the loop's plain flow, and the item is gone. A body may
  wait, call, and hold a loop of its own.

  A `formTask` stops a run until a person fills in the entity it asks for
  (`complete_form/5`) or its deadline passes: whoever started the run, or
  someone holding its role. What was filled in is taken as the types of
  the entity say, as the graph was saved with them, and kept under the
  form's element (`results`) with who filled it in (`author`); a form the
  run comes to again asks anew. One that asks whoever started a run nobody
  started fails (`no_starter`).

  While a run waits on a step a person finishes it keeps whom it asks
  (`asks_role`, `asks_profile_id`), and says so when it tells that it
  moved (`asks`), also once more as it leaves that wait. So a page counts
  again what waits for its viewer only when the news is theirs.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PotokIde.{RateLimit, Repo}

  alias PotokIde.Processes.{
    Expr,
    Graph,
    GroupFields,
    Legacy,
    Reach,
    Scheduler,
    Scope,
    Triggers,
    Types,
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
  # Elements one call of `run/1` takes before it gives way to other runs.
  @max_pass 100
  @max_steps 5_000
  @max_log 200
  # Instances a pass takes forward at the same time (`run_due/1`); each holds
  # a database connection while it steps.
  @due_at_once 4
  @max_comment 1_000
  @max_group_name 120
  @max_push_text 240
  @max_depth 3
  # Runs other processes started that run or wait, for one process at a time.
  @max_called 200
  @max_field 1_000
  @max_result 8_192
  # What a process may hand back to its caller, as JSON.
  @max_return 16_384
  # What a run keeps in its variables and its results together, in bytes.
  @max_data 65_536
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
  `limit` of them, #{@due_at_once} at a time, so one app's slow step does
  not hold the others back. Returns how many it took up.
  """
  def run_due(limit \\ 200) do
    from(i in ValueProcess,
      where: i.status in [:running, :waiting] and i.wake_at <= ^now(),
      order_by: [asc: i.wake_at, asc: i.id],
      limit: ^limit,
      select: i.id
    )
    |> Repo.all()
    |> then(
      &Task.Supervisor.async_stream_nolink(PotokIde.TaskSupervisor, &1, fn id -> run(id) end,
        max_concurrency: @due_at_once,
        ordered: false,
        timeout: :infinity
      )
    )
    |> Enum.count(fn
      {:ok, instance} ->
        instance != nil

      {:exit, reason} ->
        Logger.error("Process run exited: #{inspect(reason)}")
        false
    end)
  end

  @doc """
  Takes the instance forward while it can: element after element until it
  waits on a task or a timer, ends or fails. Returns the instance as it then
  stands, or nil when another node holds it, it is gone, or nothing was due.
  """
  def run(id) when is_integer(id), do: run(id, @max_run, nil, @max_pass)

  defp run(id, budget, last, left) do
    case guarded(id, budget) do
      {:ok, {:continue, instance, announcements}} ->
        ProcessActions.announce(announcements)
        again(instance, budget - 1, left - 1)

      # A loop took a turn: its body has a run of elements of its own.
      {:ok, {:turn, instance, announcements}} ->
        ProcessActions.announce(announcements)
        again(instance, @max_run, left - 1)

      {:ok, {:stop, instance, announcements}} ->
        ProcessActions.announce(announcements)
        tell(instance)

      {:ok, :skip} ->
        if last == :moved, do: tell(Repo.get(ValueProcess, id))

      {:error, {:failed, element, reason}} ->
        id |> fail(element, reason) |> tell()
    end
  end

  # A run that has gone long without a wait stays due and gives way: the
  # scheduler takes it up again in a pass of its own, after the others.
  defp again(%ValueProcess{} = instance, _budget, left) when left <= 0 do
    Scheduler.nudge()
    tell(instance)
  end

  defp again(%ValueProcess{id: id}, budget, left), do: run(id, budget, :moved, left)

  # The app's open pages hear that an instance moved, and read it again.
  defp tell(nil), do: nil

  defp tell(%ValueProcess{} = instance) do
    case Repo.get(AppProcess, instance.app_process_id) do
      %AppProcess{} = process ->
        AppData.broadcast(%Group{id: process.group_id}, :process, %{
          alt_id: process.alt_description_id,
          collection: process.collection,
          id: instance.id,
          drawn: process.drawn,
          asks: asks(instance)
        })

        if process.drawn, do: tell_asked(process.group_id, instance)

      nil ->
        :ok
    end

    instance
  end

  # Those a wait asks, or asked, count again on every page they have open,
  # in any group: the bar's hand and the rows of their groups.
  defp tell_asked(_group_id, %ValueProcess{asks_role: nil, asks_profile_id: nil}), do: :ok

  defp tell_asked(group_id, %ValueProcess{} = instance) do
    group_id
    |> PotokIde.Processes.asked_profile_ids(instance)
    |> PotokIde.Social.broadcast_profile_waiting_updated()
  end

  # Whom the run asks, or asked on the wait it just left: the news is theirs.
  defp asks(%ValueProcess{asks_role: nil, asks_profile_id: nil}), do: nil

  defp asks(%ValueProcess{asks_role: role, asks_profile_id: profile_id}),
    do: %{role: role, profile_id: profile_id}

  # Those a wait asked hear that it asks no more, whatever the run stops on
  # next: a later wait writes over whom this one asked.
  defp left(%ValueProcess{asks_role: nil, asks_profile_id: nil}), do: []
  defp left(%ValueProcess{} = instance), do: [fn -> tell(instance) end]

  # Whom a wait asks: the people of a role, whoever started the run, or
  # nobody, for a wait no person ends.
  defp asked(%{"type" => "userTask", "role" => role}, _instance),
    do: %{asks_role: role, asks_profile_id: nil}

  defp asked(%{"type" => "formTask", "by" => "role", "role" => role}, _instance),
    do: %{asks_role: role, asks_profile_id: nil}

  defp asked(%{"type" => "formTask"}, instance),
    do: %{asks_role: nil, asks_profile_id: instance.started_by_id}

  defp asked(_element, _instance), do: %{asks_role: nil, asks_profile_id: nil}

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

          retry_after_ms = held_back(instance) ->
            hold(instance, retry_after_ms)

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

  # Over its share of steps that write outside the run, the process waits
  # until its share comes back: how long that is, in ms, or nil to go on.
  # What a run does to itself (a condition, a variable set, a turn of a
  # loop) is not counted.
  defp held_back(%ValueProcess{app_process_id: id} = instance) do
    with true <- writes?(Graph.node(instance.graph, instance.element)),
         {:error, :rate_limited, retry_after_ms} <- RateLimit.hit(:process_step, id) do
      retry_after_ms
    else
      _go_on -> nil
    end
  end

  # A held instance stays where it stands and is due again once its share
  # comes back, so until then the passes leave it out.
  defp hold(%ValueProcess{id: id}, retry_after_ms) do
    wake_at = DateTime.add(now(), ceil(retry_after_ms / 1000), :second)
    from(i in ValueProcess, where: i.id == ^id) |> Repo.update_all(set: [wake_at: wake_at])
    :skip
  end

  defp writes?(%{"type" => "serviceTask", "action" => action}), do: action != "assign"
  defp writes?(%{"type" => "callActivity"}), do: true
  defp writes?(_element), do: false

  defp execute(%ValueProcess{} = instance) do
    node = Graph.node(instance.graph, instance.element)

    case act(node, instance) do
      {:next, to, changes, announcements} ->
        {:continue, move(instance, to, changes), announcements}

      {:turn, to, changes} ->
        {:turn, move(instance, to, changes), []}

      {:wait, changes, announcements} ->
        changes = changes |> Map.put(:status, :waiting) |> Map.merge(asked(node, instance))
        {:stop, update!(instance, changes), announcements}

      :done ->
        done = update!(instance, %{status: :done, wake_at: nil})
        {:stop, done, returned(done, node)}

      {:done, changes} ->
        done = update!(instance, Map.merge(changes, %{status: :done, wake_at: nil}))
        {:stop, done, returned(done, node)}

      {:error, reason} ->
        Repo.rollback({:failed, instance.element, reason})
    end
  end

  # The start: the variables that start with a value get it.
  defp act(%{"type" => "startEvent", "id" => id}, instance) do
    with {:ok, changes} <- initial_vars(instance) do
      {:next, plain_next(instance, id), changes, []}
    end
  end

  # An end of a process that hands an entity back fills it in, kept under
  # the end's id for the caller to read.
  defp act(%{"type" => "endEvent", "id" => id} = node, instance) do
    case instance.graph do
      %{"v" => 2, "returns" => entity_id, "types" => types} when is_integer(entity_id) ->
        with {:ok, values} <- handing_back(node, entity_id, types, instance) do
          {:done, %{results: Map.put(instance.results || %{}, id, values)}}
        end

      _hands_back_nothing ->
        :done
    end
  end

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

  # A form asks anew each time the run comes to it.
  defp act(%{"type" => "formTask", "id" => id} = form, instance) do
    if form["by"] == "starter" and is_nil(instance.started_by_id) do
      {:error, :no_starter}
    else
      {:wait,
       %{
         wake_at: form["deadline"] && later(form["deadline"]),
         results: Map.delete(instance.results, id)
       }, []}
    end
  end

  defp act(%{"type" => "callActivity", "id" => id} = call, instance) do
    process = Repo.get!(AppProcess, instance.app_process_id)

    with :ok <- if(process.active, do: :ok, else: {:error, :process_inactive}),
         :ok <- if(instance.depth < @max_depth, do: :ok, else: {:error, :too_deep}),
         {:ok, callee} <- callee(call["process"], process.group_id),
         :ok <- room(callee),
         {:ok, fields} <- handed(callee, call["fields"] || %{}, value_data(instance)) do
      # In its own group the run shares the caller's subject and people; in
      # another it gets what is handed over and nothing else.
      shared =
        if callee.group_id == process.group_id do
          [
            value_id: instance.value_id,
            subject_group_id: instance.subject_group_id,
            started_by: instance.started_by_id,
            triggered_by: instance.triggered_by_id
          ]
        else
          []
        end

      child =
        start_drawn_on(
          callee,
          shared ++ [depth: instance.depth + 1, data: Map.put(fields, "from", process.name)]
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

  # A loop: on the way in it reads its list, each turn it hands its body
  # the next item, and after the last it goes on.
  defp act(%{"type" => "loop", "id" => id, "item" => name} = loop, instance) do
    out = Graph.out(instance.graph, id)
    vars = instance.vars || %{}

    with {:ok, items, at} <- standing(loop, instance) do
      count = length(items)

      if at < count do
        vars = Map.put(vars, name, Enum.at(items, at))
        state = %{"items" => items, "index" => at + 1, "count" => count}
        results = Map.put(instance.results, id, state)

        with :ok <- room_for(vars, results) do
          {:turn, Enum.find(out, & &1["each"])["to"], %{vars: vars, results: results}}
        end
      else
        done = %{"index" => count, "count" => count}

        {:next, plain(out)["to"],
         %{vars: Map.delete(vars, name), results: Map.put(instance.results, id, done)}, []}
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
    name = task["name"]

    with :ok <- if(step.process.active, do: :ok, else: {:error, :process_inactive}),
         {:ok, fields} <- carried(task, instance.graph, data) do
      carried = Map.merge(fields, %{"from" => step.process.name, "signal" => name})
      woken = wake_receivers(group, instance, name, carried)
      started = start_on_signal(group, instance, name, carried)

      {:ok, %{},
       fn ->
         Scheduler.nudge()
         Enum.each(woken, &tell(Repo.get(ValueProcess, &1)))
         Enum.each(started, &tell/1)
       end}
    end
  end

  # A variable of the run, or an attribute of one, set to what its value
  # gives, as the type of the target takes it.
  defp service("assign", task, _step, _group, instance, {:names, data, opts}) do
    graph = instance.graph
    op = task["op"]

    with {:ok, target} <- Expr.parse(task["target"]),
         {:ok, type} <- Expr.check(target, Scope.scope(graph)),
         {:ok, type} <- written_as(op, type),
         {:ok, value} <- worked_out(task["value"], type, data, opts),
         {:ok, value} <- Types.cast(value, type, graph["types"] || %{}, zone: opts.zone),
         {:ok, value} <- placed(op, target, value, data, opts),
         vars = put_path(instance.vars || %{}, path(target), Types.dump(value)),
         :ok <- room_for(vars, instance.results) do
      {:ok, %{vars: vars}, fn -> :ok end}
    else
      {:error, reason} -> {:error, expression_error(reason)}
    end
  end

  # Only a graph of today sets variables.
  defp service("assign", _task, _step, _group, _instance, _data), do: {:error, :bad_expression}

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

  # What the value of a step that sets is taken as: what the target holds,
  # or an item of the list for a step that adds to one.
  defp written_as("append", {:list, item}), do: {:ok, item}
  defp written_as("append", :any), do: {:ok, :any}
  defp written_as("append", _other), do: {:error, :not_a_list}
  defp written_as(_set, type), do: {:ok, type}

  # What the target then holds: the value, or the list with it at its end.
  defp placed("append", target, value, data, opts) do
    with {:ok, held} <- Expr.eval(target, data, opts) do
      cond do
        not (is_list(held) or is_nil(held)) -> {:error, :not_a_list}
        length(held || []) >= Types.max_items() -> {:error, :too_many_items}
        true -> {:ok, (held || []) ++ [value]}
      end
    end
  end

  defp placed(_set, _target, value, _data, _opts), do: {:ok, value}

  # Where a loop stands: the items it goes through and how many it has
  # handed out. On the way in it reads its list, once; what the body does to
  # the list after that changes no turn.
  defp standing(%{"id" => id} = loop, instance) do
    case instance.results[id] do
      %{"items" => items, "index" => at} when is_list(items) and is_integer(at) ->
        {:ok, items, at}

      _on_the_way_in ->
        with {:ok, items} <- listed(loop, instance), do: {:ok, items, 0}
    end
  end

  defp listed(%{"list" => list} = loop, instance) do
    {:names, data, opts} = value_data(instance)
    type = {:list, Types.of(loop["of"] || %{})}
    entities = instance.graph["types"] || %{}

    with {:ok, tree} <- Expr.parse(list),
         {:ok, value} <- Expr.eval(tree, data, opts),
         {:ok, items} <- Types.cast(value, type, entities, zone: opts.zone) do
      {:ok, Types.dump(items || [])}
    else
      {:error, reason} -> {:error, expression_error(reason)}
    end
  end

  # What a signal carries: the attributes of the entity it names, each
  # worked out and taken as its type, or texts where it names none.
  defp carried(%{"entity" => id, "fields" => fields}, %{"types" => types}, data)
       when is_integer(id) do
    case Types.attributes(types, id) do
      nil ->
        {:error, :unknown_entity}

      attributes ->
        filled(attributes, id, types, Map.new(fields, &{&1["name"], &1["value"]}), data)
    end
  end

  defp carried(task, _graph, data) do
    {:ok,
     for %{"name" => field, "value" => value} <- task["fields"] || [], into: %{} do
       {field, value |> render(data) |> String.slice(0, @max_field)}
     end}
  end

  # What a call hands the process it starts: the attributes of the entity
  # that process takes, as it was saved, or texts for the fields of one
  # that takes no entity.
  defp handed(%AppProcess{entry_entity_id: id, graph: %{"types" => types}}, given, data)
       when is_integer(id) do
    case Types.attributes(types, id) do
      nil -> {:error, :call_unknown}
      attributes -> filled(attributes, id, types, given, data)
    end
  end

  defp handed(%AppProcess{} = callee, given, data) do
    {:ok,
     for name <- callee.trigger_config["fields"] || [], into: %{} do
       {name, (given[name] || "") |> render(data) |> String.slice(0, @max_field)}
     end}
  end

  # What an end hands back: the entity its process hands back, filled in as
  # the end says, within `@max_return`.
  defp handing_back(node, entity_id, types, instance) do
    with attributes when is_list(attributes) <-
           Types.attributes(types, entity_id) || {:error, :return_unknown},
         {:ok, values} <-
           filled(attributes, entity_id, types, node["values"] || %{}, value_data(instance)) do
      if byte_size(JSON.encode!(values)) <= @max_return,
        do: {:ok, values},
        else: {:error, :return_too_big}
    end
  end

  # An entity filled in from what is written for each attribute, kept as
  # plain JSON: nothing for an attribute left blank, and an error when a
  # required one is, or when a value is not of its type.
  defp filled(attributes, id, types, given, data) do
    worked =
      Enum.reduce_while(attributes, {:ok, %{}}, fn %{"name" => name} = attribute, {:ok, held} ->
        case given |> Map.get(name, "") |> to_string() |> String.trim() do
          "" ->
            {:cont, {:ok, held}}

          written ->
            case attribute_value(written, Types.of(attribute), data) do
              {:ok, value} -> {:cont, {:ok, Map.put(held, name, value)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)

    with {:ok, held} <- worked,
         {:ok, value} <- Types.cast(held, {:entity, id}, types, required: true, zone: zone(data)) do
      {:ok, Types.dump(value)}
    else
      {:error, reason} -> {:error, expression_error(reason)}
    end
  end

  # A run in the first language hands over texts, which the type then reads.
  defp attribute_value(written, type, {:names, data, opts}),
    do: worked_out(written, type, data, opts)

  defp attribute_value(written, _type, {:fields, data}), do: {:ok, Legacy.render(written, data)}

  defp zone({:names, _data, opts}), do: opts.zone
  defp zone(_fields), do: "Etc/UTC"

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
      where: p.id == ^id and p.drawn and p.trigger == "process",
      lock: "FOR SHARE"
    )
    |> Repo.one()
    |> case do
      %AppProcess{} = callee ->
        cond do
          # One of another group that is private again is as good as gone.
          not Reach.callable?(callee, group_id) -> {:error, :call_unknown}
          not callee.active -> {:error, :call_inactive}
          true -> {:ok, callee}
        end

      nil ->
        {:error, :call_unknown}
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
        result = result(child, end_node, same_group?(child, caller))

        caller =
          update!(caller, %{
            results: Map.put(caller.results, caller.element, result),
            awaiting_id: nil,
            wake_at: now()
          })

        [fn -> Scheduler.nudge() end, fn -> tell(caller) end]
    end
  end

  defp same_group?(%ValueProcess{app_process_id: a}, %ValueProcess{app_process_id: b}) do
    groups =
      from(p in AppProcess, where: p.id in ^[a, b], distinct: true, select: p.group_id)
      |> Repo.all()

    length(groups) == 1
  end

  # What a called run ended with: the end it reached and what that end filled
  # in of the entity its process hands back, to a caller of any group. Of a
  # process that hands nothing back, the end, with the fields it was given
  # and what its waits brought back to a caller of its own group, unless
  # that is too much.
  defp result(%ValueProcess{graph: %{"returns" => entity_id}} = child, end_node, _same_group?)
       when is_integer(entity_id) do
    child.results
    |> Kernel.||(%{})
    |> Map.get(end_node["id"], %{})
    |> Map.put("outcome", Graph.label(end_node))
  end

  defp result(%ValueProcess{}, end_node, false), do: %{"outcome" => Graph.label(end_node)}

  defp result(%ValueProcess{} = child, end_node, true) do
    outcome = Graph.label(end_node)

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
      %{"type" => type} when type in ~w(userTask formTask) ->
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
    do: {:continue, move(instance, flow["to"], %{triggered_by_id: nil}), left(instance)}

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

  # The flow an element goes on by when nothing else takes it: not its
  # deadline's, and not the one into a loop's body.
  defp plain(flows),
    do: Enum.find(flows, &(not Map.has_key?(&1, "deadline") and not Map.has_key?(&1, "each")))

  defp plain_next(%ValueProcess{graph: graph}, id), do: plain(Graph.out(graph, id))["to"]

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

  @doc """
  Finishes the form an instance waits on with what `profile` filled in:
  `answers` holds the attributes of the form's entity by name, as a form
  posts them, and `zone` is the time zone a time without one is read in.
  Only whoever the form asks may, a member of the process's group who
  started the run or holds the form's role, and only while the instance
  waits on that very `element`. Whoever filled it in sets off the steps
  that follow, and the log keeps who it was.

  Returns `{:ok, instance}`, moved on and due, or `{:error, {:invalid_field,
  name, reason}}` for an attribute that is missing or not of its type.
  """
  def complete_form(%Profile{} = profile, id, element, answers, zone \\ nil) do
    Repo.transaction(fn ->
      instance = lock(id) || Repo.rollback(:not_found)
      form = Graph.node(instance.graph, instance.element)

      if instance.status != :waiting or instance.element != element or
           form["type"] != "formTask",
         do: Repo.rollback(:not_waiting)

      process = Repo.get!(AppProcess, instance.app_process_id)

      unless process.active, do: Repo.rollback(:process_inactive)

      access = Access.for_profile(profile, Repo.get!(Group, process.group_id))

      unless asked?(form, instance, profile, access), do: Repo.rollback(:not_permitted)

      results =
        with {:ok, filled} <- filled_in(form, instance.graph, answers, zone),
             results = Map.put(instance.results, element, filled),
             :ok <- room_for(instance.vars || %{}, results) do
          Map.update!(results, element, &Map.put(&1, "author", profile.username))
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      entry = %{
        "at" => DateTime.to_iso8601(now()),
        "element" => element,
        "by" => profile.id,
        "form" => true
      }

      move(instance, plain_next(instance, element), %{
        triggered_by_id: profile.id,
        log: Enum.take(instance.log ++ [entry], -@max_log),
        results: results
      })
    end)
    |> told()
  end

  @doc """
  What the form an instance waits on shows its person, worked out from what
  the run holds just now: its `intro`, the form's text with that put in,
  and the `values` it starts with, by the name of an attribute, each taken
  as the attribute's type and kept as plain JSON. One that cannot be worked
  out, or is no value of its type, starts empty, and an intro that cannot be
  read is left out, as the person fills in the rest. Nil for an instance
  that waits on no form.
  """
  def form_view(%ValueProcess{status: :waiting, graph: %{"v" => 2} = graph} = instance) do
    case Graph.node(graph, instance.element) do
      %{"type" => "formTask"} = form ->
        {:names, data, opts} = value_data(instance)
        types = graph["types"] || %{}
        written = form["values"] || %{}

        values =
          for attribute <- Types.attributes(types, form["entity"]) || [],
              text = written[attribute["name"]],
              is_binary(text),
              {:ok, value} <- [start_value(text, attribute, types, data, opts)],
              value not in [nil, ""],
              into: %{},
              do: {attribute["name"], value}

        %{intro: intro(form["intro"], data, opts), values: values}

      _other ->
        nil
    end
  end

  def form_view(_instance), do: nil

  defp start_value(text, attribute, types, data, opts) do
    type = Types.of(attribute)

    with {:ok, value} <- worked_out(text, type, data, opts),
         {:ok, value} <- Types.cast(value, type, types, zone: opts.zone) do
      {:ok, Types.dump(value)}
    else
      _cannot -> :error
    end
  end

  defp intro(nil, _data, _opts), do: nil

  defp intro(text, data, opts) do
    with {:ok, parts} <- Expr.template(text),
         {:ok, rendered} <- Expr.render(parts, data, opts),
         rendered when rendered != "" <- String.trim(rendered) do
      rendered
    else
      _cannot -> nil
    end
  end

  defp asked?(%{"by" => "role", "role" => role}, _instance, _profile, access),
    do: access.member? and role in access.role_keys

  defp asked?(_form, instance, profile, access),
    do: access.member? and instance.started_by_id == profile.id

  # What a form was filled in with, as the entity it asks for takes it and
  # as plain JSON: every attribute by its type, nothing for one left blank,
  # and an error for a required one that is.
  defp filled_in(%{"entity" => id}, %{"types" => types}, answers, zone)
       when is_integer(id) and is_map(answers) do
    names = for attribute <- Types.attributes(types, id) || [], do: attribute["name"]

    given =
      for {name, answer} <- Map.take(answers, names), into: %{}, do: {name, written(answer)}

    zone = if is_binary(zone), do: zone, else: "Etc/UTC"

    case Types.cast(given, {:entity, id}, types, required: true, zone: zone) do
      {:ok, value} -> {:ok, Types.dump(value)}
      {:error, {reason, name}} -> {:error, {:invalid_field, name, reason}}
    end
  end

  defp filled_in(_form, _graph, _answers, _zone), do: {:error, :invalid_form}

  # A text a person wrote: trimmed, and no longer than a field may be.
  defp written(answer) when is_binary(answer),
    do: answer |> String.trim() |> String.slice(0, @max_field)

  defp written(answer), do: answer

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

  @doc """
  Fails the runs that wait for a run that is gone, deleted with its process
  or its group, as those whose run was cancelled do (`call_cancelled`): at
  most `limit` in one go, skipping one another node holds. Returns how many
  it failed.
  """
  def fail_orphaned_calls(limit \\ 200) do
    {:ok, failed} =
      Repo.transaction(fn ->
        from(i in ValueProcess,
          where: i.status == :waiting and is_nil(i.awaiting_id),
          where:
            fragment(
              "jsonb_path_exists(?, '$.nodes[*] \\? (@.id == $e && @.type == \"callActivity\")', jsonb_build_object('e', ?))",
              i.graph,
              i.element
            ),
          # One whose run ended has heard of it, and only waits to go on.
          where: fragment("(? -> ?) IS NULL", i.results, i.element),
          order_by: [asc: i.id],
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()
        |> Enum.map(fn caller ->
          update!(caller, %{
            status: :failed,
            wake_at: nil,
            error: %{"element" => caller.element, "reason" => "call_cancelled"}
          })
        end)
      end)

    Enum.each(failed, &tell/1)
    length(failed)
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
      (instance.vars || %{})
      |> Map.merge(results || %{})
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

  # A graph is checked when it is saved, so only what it holds can fail it:
  # a number that is none, or a value its type does not take.
  defp expression_error(reason) when is_atom(reason), do: reason
  defp expression_error({reason, path}) when is_atom(reason) and is_binary(path), do: reason
  defp expression_error(_syntax), do: :bad_expression

  # What a text or an expression gives: a text for what is written as one.
  defp worked_out(text, type, data, opts) do
    if Types.textual?(type) do
      with {:ok, parts} <- Expr.template(text), do: Expr.render(parts, data, opts)
    else
      with {:ok, tree} <- Expr.parse(text), do: Expr.eval(tree, data, opts)
    end
  end

  # The variables of a graph of today that start with a value, each worked
  # out in turn, so one may start from another before it.
  defp initial_vars(
         %ValueProcess{graph: %{"v" => 2, "variables" => [_ | _] = variables} = graph} = instance
       ) do
    {:names, data, opts} = value_data(instance)
    entities = graph["types"] || %{}

    variables
    |> Enum.filter(&is_binary(&1["initial"]))
    |> Enum.reduce_while({:ok, instance.vars || %{}, data}, fn variable, {:ok, vars, data} ->
      %{"name" => name, "initial" => initial} = variable
      type = Types.of(variable)

      with {:ok, value} <- worked_out(initial, type, data, opts),
           {:ok, value} <- Types.cast(value, type, entities, zone: opts.zone) do
        {:cont, {:ok, Map.put(vars, name, Types.dump(value)), Map.put(data, name, value)}}
      else
        {:error, reason} -> {:halt, {:error, expression_error(reason)}}
      end
    end)
    |> case do
      {:ok, vars, _data} -> {:ok, %{vars: vars}}
      {:error, _reason} = error -> error
    end
  end

  defp initial_vars(_instance), do: {:ok, %{}}

  # The names of a target, the variable first: `prijava.sprat`.
  defp path({:name, name}), do: [name]
  defp path({:attribute, tree, name}), do: path(tree) ++ [name]

  # Sets what stands at the path, making the entities on the way to it.
  defp put_path(held, [name], value), do: Map.put(fields_of(held), name, value)

  defp put_path(held, [name | rest], value) do
    held = fields_of(held)
    Map.put(held, name, put_path(Map.get(held, name), rest, value))
  end

  # What an entity holds so far; nothing yet where there is none.
  defp fields_of(%{} = held) when not is_struct(held), do: held
  defp fields_of(_nothing), do: %{}

  # A run keeps so much and no more, in its variables and what its waits
  # brought back.
  defp room_for(vars, results) do
    size = byte_size(JSON.encode!(vars)) + byte_size(JSON.encode!(results || %{}))
    if size <= @max_data, do: :ok, else: {:error, :too_much_data}
  end

  defp later(duration), do: DateTime.add(now(), Graph.seconds(duration), :second)

  defp now, do: DateTime.utc_now(:second)
end
