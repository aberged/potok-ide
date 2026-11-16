defmodule PotokIde.Processes.GraphEdit do
  @moduledoc """
  The changes an editor makes to a process's graph while drawing it in Potok
  (`PotokIdeWeb.GroupLive.Show.ProcessEditorState`), on the graph's own shape
  (`Graph`). Each keeps the graph one an instance can finish where it can:
  a new step goes into a flow, a branch goes where its siblings go, a deleted
  step gives its place to what came after it. What still needs the editor
  (a text left empty, a step left unreachable) `Graph.normalize/1` names.

  While drawing, every flow carries a `"key"` of its own, so it can be picked
  and changed although flows have no ids; `Graph.normalize/1` drops it.

  It draws in today's language (`"v" => 2`): a new step's id is a name an
  expression may use, such as `task_2`, and a condition is an expression. A
  drawing in the first language is turned into it before it is drawn on
  (`Graph.upgrade/1`).
  Texts that the editor sees first (a message, the outcomes of a decision)
  come from the caller, in the editor's language.
  """

  alias PotokIde.Processes.Graph

  @max_outcomes 10
  @prefixes %{
    "message" => "message",
    "subgroup" => "subgroup",
    "push" => "push",
    "task" => "task",
    "timer" => "timer",
    "gateway" => "gateway",
    "call" => "call",
    "set" => "set",
    "assign" => "assign",
    "signal" => "signal",
    "receive" => "receive",
    "end" => "end"
  }
  @kinds ~w(message subgroup push task timer gateway call set assign signal receive)

  @doc "The kinds of step `insert/4` makes."
  def kinds, do: @kinds

  @doc "A graph that only starts and ends, ready to draw on."
  def new do
    %{
      "v" => 2,
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "end", "type" => "endEvent"}
      ],
      "flows" => [%{"key" => "f1", "from" => "start", "to" => "end"}]
    }
  end

  @doc "A saved graph with a key on every flow, to draw on."
  def with_keys(%{"flows" => flows} = graph) do
    flows =
      flows
      |> Enum.with_index(1)
      |> Enum.map(fn {flow, i} -> Map.put(flow, "key", "f#{i}") end)

    %{graph | "flows" => flows}
  end

  @doc "The flow with `key`, or nil."
  def flow(%{"flows" => flows}, key), do: Enum.find(flows, &(&1["key"] == key))

  @doc "The index of the flow with `key`, or nil."
  def flow_index(%{"flows" => flows}, key), do: Enum.find_index(flows, &(&1["key"] == key))

  @doc """
  Puts a new step of `kind` into the flow `key`: the flow now leads to it,
  and it leads on to where the flow led. A decision leaves by each of its
  outcomes, a condition by one condition and by default, all to that same
  place. `defaults` holds the step's first texts and role, and the process
  a call starts with the fields it takes, the group's field a step sets,
  what a new condition asks, the variable a step sets, and the entity its
  signal is waited for with: `%{text, name, role, outcomes, condition,
  process, call_fields, group_field, signal, signal_entity, variable}`.
  """
  def insert(graph, key, kind, defaults) when kind in @kinds do
    case flow(graph, key) do
      nil ->
        {:error, :no_flow}

      %{"to" => to} ->
        id = fresh_id(graph, kind)
        node = step(kind, id, defaults)

        graph
        |> update_flow!(key, &Map.put(&1, "to", id))
        |> add_node(node)
        |> add_exits(node, to, defaults)
        |> ok()
    end
  end

  def insert(_graph, _key, _kind, _defaults), do: {:error, :invalid}

  defp step("message", id, d),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "message",
      "text" => d[:text],
      "in" => "app"
    }

  defp step("subgroup", id, d),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "subgroup",
      "name" => d[:name],
      "admins" => ["owner", "triggered_by"]
    }

  defp step("push", id, d),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "push",
      "role" => d[:role],
      "text" => d[:text]
    }

  defp step("task", id, d),
    do: %{"id" => id, "type" => "userTask", "role" => d[:role], "outcomes" => d[:outcomes]}

  defp step("timer", id, _d), do: %{"id" => id, "type" => "timer", "duration" => "P1D"}
  defp step("gateway", id, _d), do: %{"id" => id, "type" => "exclusiveGateway"}

  defp step("set", id, d),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "set",
      "field" => d[:group_field],
      "op" => "set",
      "value" => ""
    }

  # A step that sets a variable, the first one the drawing has.
  defp step("assign", id, d),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "assign",
      "target" => d[:variable] || "",
      "op" => "set",
      "value" => ""
    }

  defp step("signal", id, d) do
    with_entity(
      %{
        "id" => id,
        "type" => "serviceTask",
        "action" => "signal",
        "name" => d[:signal],
        "fields" => []
      },
      d[:signal_entity]
    )
  end

  defp step("receive", id, d) do
    with_entity(
      %{"id" => id, "type" => "receiveTask", "signal" => d[:signal], "same_subject" => false},
      d[:signal_entity]
    )
  end

  defp step("call", id, d),
    do: %{
      "id" => id,
      "type" => "callActivity",
      "process" => d[:process],
      "wait" => true,
      "fields" => d[:call_fields] || %{}
    }

  # The entity a signal is sent or waited for with, where it has one.
  defp with_entity(step, nil), do: step
  defp with_entity(step, entity), do: Map.put(step, "entity", entity)

  defp add_exits(graph, %{"type" => "userTask", "id" => id, "outcomes" => outcomes}, to, _d) do
    Enum.reduce(outcomes, graph, &add_flow(&2, %{"from" => id, "to" => to, "outcome" => &1}))
  end

  defp add_exits(graph, %{"type" => "exclusiveGateway", "id" => id}, to, d) do
    graph
    |> add_flow(%{"from" => id, "to" => to, "condition" => condition(d)})
    |> add_flow(%{"from" => id, "to" => to, "default" => true})
  end

  defp add_exits(graph, %{"id" => id}, to, _d), do: add_flow(graph, %{"from" => id, "to" => to})

  # A new condition holds until its editor writes what it asks.
  defp condition(d), do: %{"expr" => d[:condition] || "true"}

  @doc """
  One more branch for a decision (a new `outcome`) or a condition (a new
  condition before its default), going where the last branch goes.
  """
  def add_branch(graph, id, defaults) do
    case Graph.node(graph, id) do
      %{"type" => "userTask", "outcomes" => outcomes} when length(outcomes) >= @max_outcomes ->
        {:error, :too_many}

      %{"type" => "userTask", "outcomes" => outcomes} = task ->
        outcome = unique_outcome(defaults[:outcome], outcomes)

        to =
          (graph
           |> Graph.out(id)
           |> Enum.filter(&Map.has_key?(&1, "outcome"))
           |> List.last())["to"]

        graph
        |> put_node(%{task | "outcomes" => outcomes ++ [outcome]})
        |> add_flow(%{"from" => id, "to" => to, "outcome" => outcome})
        |> ok()

      %{"type" => "exclusiveGateway"} ->
        default = graph |> Graph.out(id) |> Enum.find(&Map.has_key?(&1, "default"))
        to = (default || hd(Graph.out(graph, id)))["to"]
        flow = %{"from" => id, "to" => to, "condition" => condition(defaults)}

        {:ok, insert_flow_before(graph, flow, default && default["key"])}

      _other ->
        {:error, :no_branches}
    end
  end

  defp unique_outcome(base, outcomes) do
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base} #{n}"
    end)
    |> Enum.find(&(&1 not in outcomes))
  end

  @doc """
  Gives a decision, a call or a wait for a signal a deadline, or takes it
  away with `nil`. A new deadline of a decision reminds the people of the
  task's role and comes back to the task (`defaults[:text]`), as Forma does;
  a call's or a wait's goes where it goes on. A deadline it already has only changes its duration.
  Taking it away drops what only the deadline reached.
  """
  def set_deadline(graph, id, duration, defaults \\ %{}) do
    case Graph.node(graph, id) do
      %{"type" => type} = element when type in ~w(userTask callActivity receiveTask) ->
        {:ok, deadline(graph, element, duration, defaults)}

      _other ->
        {:error, :not_a_task}
    end
  end

  defp deadline(graph, %{"id" => id} = task, nil, _defaults) do
    graph
    |> put_node(Map.delete(task, "deadline"))
    |> drop_flows(&(&1["from"] == id and &1["deadline"] == true))
    |> prune()
  end

  defp deadline(graph, %{"deadline" => _old} = task, duration, _defaults),
    do: put_node(graph, %{task | "deadline" => duration})

  defp deadline(graph, %{"type" => type, "id" => id} = call, duration, _defaults)
       when type in ~w(callActivity receiveTask) do
    to = graph |> Graph.out(id) |> Enum.find(&(not Map.has_key?(&1, "deadline")))

    graph
    |> put_node(Map.put(call, "deadline", duration))
    |> add_flow(%{"from" => id, "to" => to["to"], "deadline" => true})
  end

  defp deadline(graph, %{"id" => id, "role" => role} = task, duration, defaults) do
    push = %{
      "id" => fresh_id(graph, "push"),
      "type" => "serviceTask",
      "action" => "push",
      "role" => role,
      "text" => defaults[:text]
    }

    graph
    |> put_node(Map.put(task, "deadline", duration))
    |> add_node(push)
    |> add_flow(%{"from" => id, "to" => push["id"], "deadline" => true})
    |> add_flow(%{"from" => push["id"], "to" => id})
  end

  @doc "Renames an outcome of a decision, and its flow with it."
  def rename_outcome(graph, id, old, new) do
    new = String.trim(new)

    case Graph.node(graph, id) do
      %{"type" => "userTask", "outcomes" => outcomes} = task ->
        cond do
          old not in outcomes ->
            {:error, :no_outcome}

          new == old ->
            {:ok, graph}

          new in outcomes ->
            {:error, :duplicate}

          true ->
            graph
            |> put_node(%{
              task
              | "outcomes" => Enum.map(outcomes, &if(&1 == old, do: new, else: &1))
            })
            |> map_flows(fn flow ->
              if flow["from"] == id and flow["outcome"] == old,
                do: %{flow | "outcome" => new},
                else: flow
            end)
            |> ok()
        end

      _other ->
        {:error, :not_a_task}
    end
  end

  @doc """
  Takes a branch away: an outcome of a decision (its last stays), a
  condition (its last stays), or a deadline. What only that branch reached
  goes with it. A plain flow cannot go: its step needs a way on.
  """
  def delete_flow(graph, key) do
    case flow(graph, key) do
      nil ->
        {:error, :no_flow}

      %{"outcome" => outcome, "from" => id} ->
        task = Graph.node(graph, id)

        if length(task["outcomes"]) > 1 do
          graph
          |> put_node(%{task | "outcomes" => List.delete(task["outcomes"], outcome)})
          |> drop_flows(&(&1["key"] == key))
          |> prune()
          |> ok()
        else
          {:error, :last_branch}
        end

      %{"condition" => _condition, "from" => id} ->
        conditions = graph |> Graph.out(id) |> Enum.count(&Map.has_key?(&1, "condition"))

        if conditions > 1,
          do: graph |> drop_flows(&(&1["key"] == key)) |> prune() |> ok(),
          else: {:error, :last_branch}

      %{"deadline" => true, "from" => id} ->
        set_deadline(graph, id, nil)

      _plain_or_default ->
        {:error, :needed}
    end
  end

  @doc """
  Draws a flow from `from` to `to`, as a pointer dragged between two steps
  does: a step with one way on now goes there, a decision gets an outcome
  that goes there (`defaults[:outcome]`), a condition a condition.
  """
  def connect(graph, from, to, defaults \\ %{}) do
    source = Graph.node(graph, from)
    target = Graph.node(graph, to)

    cond do
      is_nil(source) or is_nil(target) -> {:error, :no_node}
      from == to -> {:error, :self}
      target["type"] == "startEvent" -> {:error, :to_start}
      source["type"] == "endEvent" -> {:error, :from_end}
      source["type"] == "userTask" -> branch_to(graph, from, to, defaults)
      source["type"] == "exclusiveGateway" -> branch_to(graph, from, to, defaults)
      true -> retarget_only_exit(graph, from, to)
    end
  end

  # A call's deadline keeps where it goes.
  defp retarget_only_exit(graph, from, to) do
    case graph |> Graph.out(from) |> Enum.reject(&Map.has_key?(&1, "deadline")) do
      [%{"key" => key}] -> retarget(graph, key, to)
      _none_or_more -> {:error, :no_flow}
    end
  end

  defp branch_to(graph, from, to, defaults) do
    with {:ok, graph} <- add_branch(graph, from, defaults) do
      # The branch just added is the one before a condition's default, or the last.
      branch =
        graph
        |> Graph.out(from)
        |> Enum.reject(&(Map.has_key?(&1, "default") or Map.has_key?(&1, "deadline")))
        |> List.last()

      retarget(graph, branch["key"], to)
    end
  end

  @doc """
  Sends the flow `key` to `to` instead, or to a new end of its own with
  `:new_end`. What it reached before stays, for another flow to reach.
  """
  def retarget(graph, key, :new_end) do
    case flow(graph, key) do
      nil ->
        {:error, :no_flow}

      _flow ->
        id = fresh_id(graph, "end")

        graph
        |> add_node(%{"id" => id, "type" => "endEvent"})
        |> retarget(key, id)
    end
  end

  def retarget(graph, key, to) do
    flow = flow(graph, key)
    target = Graph.node(graph, to)

    cond do
      is_nil(flow) -> {:error, :no_flow}
      is_nil(target) -> {:error, :no_node}
      target["type"] == "startEvent" -> {:error, :to_start}
      flow["from"] == to -> {:error, :self}
      true -> {:ok, update_flow!(graph, key, &Map.put(&1, "to", to))}
    end
  end

  @doc """
  Deletes a step. A step with one way on gives its place to what follows; a
  decision or a condition keeps its first branch; an end sends what reached
  it to another end. The start and the last end stay. What no longer can be
  reached from the start goes too, and the ids of all that went come back.
  """
  def delete_node(graph, id) do
    node = Graph.node(graph, id)
    ends = Enum.count(graph["nodes"], &(&1["type"] == "endEvent"))

    cond do
      is_nil(node) ->
        {:error, :no_node}

      node["type"] == "startEvent" ->
        {:error, :start}

      node["type"] == "endEvent" and ends == 1 ->
        {:error, :last_end}

      true ->
        next = next_of(graph, node)
        before = MapSet.new(graph["nodes"], & &1["id"])

        graph =
          graph
          |> drop_flows(&(&1["from"] == id))
          |> map_flows(&if(&1["to"] == id, do: %{&1 | "to" => next}, else: &1))
          |> drop_nodes(&(&1["id"] == id))
          |> map_nodes(&if(&1["in"] == id, do: %{&1 | "in" => "app"}, else: &1))
          |> prune()

        removed = MapSet.difference(before, MapSet.new(graph["nodes"], & &1["id"]))
        {:ok, graph, MapSet.to_list(removed)}
    end
  end

  defp next_of(graph, %{"type" => "endEvent", "id" => id}),
    do:
      Enum.find_value(graph["nodes"], &(&1["type"] == "endEvent" and &1["id"] != id and &1["id"]))

  defp next_of(graph, %{"id" => id}) do
    out = Graph.out(graph, id)
    first = Enum.find(out, &(not Map.has_key?(&1, "deadline"))) || hd(out)
    first["to"]
  end

  @doc """
  Changes what an editor may change on a step: its `label`, and per type its
  texts, target, sub-group name and admins, role, duration, or the process
  a call starts, whether it waits and the fields it hands over, or the
  entity a signal is sent or waited for with (none with `nil`). A blank
  label is none, and a call that no longer waits has no deadline.
  """
  def update_node(graph, id, attrs) do
    case Graph.node(graph, id) do
      nil ->
        {:error, :no_node}

      node ->
        changed =
          attrs
          |> Map.take(editable_keys(node))
          |> Enum.reduce(node, fn
            {"label", label}, node -> put_label(node, label)
            # A signal with no entity names none.
            {"entity", nil}, node -> Map.delete(node, "entity")
            {key, value}, node -> Map.put(node, key, value)
          end)

        graph = put_node(graph, changed)

        case changed do
          %{"type" => "callActivity", "wait" => false, "deadline" => _} ->
            {:ok, deadline(graph, changed, nil, %{})}

          _other ->
            {:ok, graph}
        end
    end
  end

  defp editable_keys(%{"type" => "serviceTask", "action" => "message"}), do: ~w(label text in)

  defp editable_keys(%{"type" => "serviceTask", "action" => "subgroup"}),
    do: ~w(label name admins)

  defp editable_keys(%{"type" => "serviceTask", "action" => "push"}), do: ~w(label role text)

  defp editable_keys(%{"type" => "serviceTask", "action" => "set"}),
    do: ~w(label field op value)

  defp editable_keys(%{"type" => "serviceTask", "action" => "assign"}),
    do: ~w(label target op value)

  defp editable_keys(%{"type" => "serviceTask", "action" => "signal"}),
    do: ~w(label name fields entity)

  defp editable_keys(%{"type" => "receiveTask"}), do: ~w(label signal same_subject entity)

  defp editable_keys(%{"type" => "userTask"}), do: ~w(label role)
  defp editable_keys(%{"type" => "timer"}), do: ~w(label duration)
  defp editable_keys(%{"type" => "callActivity"}), do: ~w(label process wait fields)
  defp editable_keys(_node), do: ~w(label)

  defp put_label(node, label) when is_binary(label) do
    case String.trim(label) do
      "" -> Map.delete(node, "label")
      label -> Map.put(node, "label", label)
    end
  end

  defp put_label(node, _label), do: Map.delete(node, "label")

  @doc """
  Sets the variables of the drawing, what a run keeps for itself, as its
  editor lists them; `Graph.normalize/2` says what is wrong with one.
  """
  def put_variables(graph, variables) when is_list(variables),
    do: Map.put(graph, "variables", variables)

  @doc "Changes what a condition's flow asks: an expression that is true or false."
  def update_condition(graph, key, %{"expr" => expression}) when is_binary(expression) do
    case flow(graph, key) do
      %{"condition" => _old} ->
        condition = %{"expr" => String.trim(expression)}
        {:ok, update_flow!(graph, key, &Map.put(&1, "condition", condition))}

      _other ->
        {:error, :not_a_condition}
    end
  end

  def update_condition(_graph, _key, _condition), do: {:error, :not_a_condition}

  # ---------
  # Helpers
  # ---------

  # A new id for a step of `kind`, such as `task_2`.
  defp fresh_id(graph, kind) do
    prefix = Map.fetch!(@prefixes, kind)
    ids = MapSet.new(graph["nodes"], & &1["id"])

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&"#{prefix}_#{&1}")
    |> Enum.find(&(not MapSet.member?(ids, &1)))
  end

  defp fresh_key(%{"flows" => flows}) do
    n =
      flows
      |> Enum.map(fn flow ->
        case flow["key"] do
          "f" <> digits -> String.to_integer(digits)
          _none -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    "f#{n + 1}"
  end

  defp add_node(graph, node), do: Map.update!(graph, "nodes", &(&1 ++ [node]))

  defp add_flow(graph, flow),
    do: Map.update!(graph, "flows", &(&1 ++ [Map.put(flow, "key", fresh_key(graph))]))

  defp insert_flow_before(graph, flow, nil), do: add_flow(graph, flow)

  defp insert_flow_before(graph, flow, key) do
    flow = Map.put(flow, "key", fresh_key(graph))
    i = flow_index(graph, key)
    Map.update!(graph, "flows", &List.insert_at(&1, i, flow))
  end

  defp put_node(graph, %{"id" => id} = node),
    do: map_nodes(graph, &if(&1["id"] == id, do: node, else: &1))

  defp update_flow!(graph, key, fun),
    do: map_flows(graph, &if(&1["key"] == key, do: fun.(&1), else: &1))

  defp map_nodes(graph, fun), do: Map.update!(graph, "nodes", &Enum.map(&1, fun))
  defp map_flows(graph, fun), do: Map.update!(graph, "flows", &Enum.map(&1, fun))
  defp drop_nodes(graph, fun), do: Map.update!(graph, "nodes", &Enum.reject(&1, fun))
  defp drop_flows(graph, fun), do: Map.update!(graph, "flows", &Enum.reject(&1, fun))

  # Drops what the start no longer reaches, with its flows and what pointed
  # a message at it.
  defp prune(graph) do
    start = Graph.start(graph)
    out = Enum.group_by(graph["flows"], & &1["from"], & &1["to"])
    seen = walk([start], MapSet.new([start]), out)

    graph
    |> drop_nodes(&(not MapSet.member?(seen, &1["id"])))
    |> drop_flows(&(not MapSet.member?(seen, &1["from"]) or not MapSet.member?(seen, &1["to"])))
    |> map_nodes(fn node ->
      if is_binary(node["in"]) and node["in"] != "app" and not MapSet.member?(seen, node["in"]),
        do: %{node | "in" => "app"},
        else: node
    end)
  end

  defp walk([], seen, _out), do: seen

  defp walk([id | rest], seen, out) do
    fresh = out |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(rest ++ fresh, Enum.into(fresh, seen), out)
  end

  defp ok(graph), do: {:ok, graph}
end
