defmodule PotokIde.Processes.Graph do
  @moduledoc """
  The graph of an app's process, as the rule `process.graph` of a collection
  holds it: `%{"nodes" => [...], "flows" => [...]}`, element types named as in
  BPMN. It is checked when an editor saves the rules (`normalize/1`), so an
  instance never starts with a graph it cannot finish.

  - `startEvent`: the instance starts when a value comes to the collection.
  - `serviceTask` with an `action`: `message` (`text`, `in`: `"app"` or a
    `subgroup` element), `subgroup` (`name`, `admins`) or `push` (`role`,
    `text`), done by `PotokIde.Social.ProcessActions`.
  - `userTask`: waits for someone holding `role` to pick one of `outcomes`,
    until an optional `deadline`.
  - `timer`: waits a `duration`.
  - `exclusiveGateway`: takes the first flow whose `condition` holds, else
    its `default` flow.
  - `endEvent`: the instance is done.

  Any element may carry a `label`, the name it shows on a drawing and where
  an instance waits or stopped; its `id` stands in for it otherwise.

  There are no parallel flows: an instance stands on one element at a time.
  Durations are ISO 8601 (`PT30M`, `PT1H`, `P3D`, `P1W`). Texts may hold
  fields of the value, as `{{naslov}}`, and nothing else. A condition compares
  one field of the value: `=`, `!=`, `<`, `>` or `empty`.

  Errors come as `{path, reason}`, the path counted from the graph, such as
  `{"nodes.3.outcomes", :no_flow}`.
  """

  @max_nodes 100
  @max_flows 200
  @max_text 1_000
  @max_push_text 240
  @max_name 120
  @max_label 60
  @max_outcome 40
  @max_outcomes 10
  @max_admins 10
  @max_key 64
  @min_seconds 60
  @max_seconds 366 * 24 * 3600
  @id_format ~r/^[a-z][a-z0-9_-]{0,39}$/
  @field_format ~r/^[\p{L}\p{Nd}_.-]{1,64}$/u
  @duration_format ~r/^P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?)$/
  @ops ~w(= != < > empty)
  @default_admins ["owner", "triggered_by"]

  # What each action needs the process profile to hold in the app's group.
  @action_permissions %{
    "message" => :post_values,
    "subgroup" => :create_subgroups,
    "push" => :mention_roles
  }

  @doc """
  The graph as Potok keeps it: known keys only, defaults filled in, and every
  element able to reach an end. `{:error, {path, reason}}` otherwise.
  """
  def normalize(%{"nodes" => nodes, "flows" => flows}) when is_list(nodes) and is_list(flows) do
    cond do
      nodes == [] ->
        {:error, {"nodes", :empty}}

      length(nodes) > @max_nodes ->
        {:error, {"nodes", :too_many}}

      length(flows) > @max_flows ->
        {:error, {"flows", :too_many}}

      true ->
        with {:ok, nodes} <- each(nodes, "nodes", &element/2),
             :ok <- unique_ids(nodes),
             ids = MapSet.new(nodes, & &1["id"]),
             {:ok, flows} <- each(flows, "flows", &flow(&1, &2, ids)),
             :ok <- shape(nodes, flows) do
          {:ok, %{"nodes" => nodes, "flows" => flows}}
        end
    end
  end

  def normalize(_graph), do: {:error, {"", :invalid}}

  @doc "The permissions the graph's actions need, in a fixed order; none for nil."
  def permissions(nil), do: []

  def permissions(%{"nodes" => nodes}) do
    actions = for %{"type" => "serviceTask", "action" => action} <- nodes, do: action

    for {action, permission} <- Enum.sort_by(@action_permissions, &elem(&1, 1)),
        action in actions,
        do: permission
  end

  @doc """
  The role keys the graph names, as `{path, key}`: who decides a task, who
  gets a push, whose people run a sub-group. They must exist in the app's
  group, which the graph alone cannot tell.
  """
  def role_refs(%{"nodes" => nodes}) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "userTask", "role" => role}, i} ->
        [{"nodes.#{i}.role", role}]

      {%{"action" => "push", "role" => role}, i} ->
        [{"nodes.#{i}.role", role}]

      {%{"action" => "subgroup", "admins" => admins}, i} ->
        for {admin, j} <- Enum.with_index(admins),
            admin not in @default_admins,
            do: {"nodes.#{i}.admins.#{j}", admin}

      _other ->
        []
    end)
  end

  @doc """
  The first role the graph names that is not among `keys` (the role keys of
  the app's group), as `{path, :unknown_role}`, or nil.
  """
  def unknown_role(graph, %MapSet{} = keys) do
    Enum.find_value(role_refs(graph), fn {path, key} ->
      if not MapSet.member?(keys, key), do: {path, :unknown_role}
    end)
  end

  @doc "The label of an element, or its id when it has none."
  def label(%{"label" => label}) when is_binary(label), do: label
  def label(%{"id" => id}), do: id

  @doc "The id of the graph's `startEvent`."
  def start(%{"nodes" => nodes}),
    do: Enum.find_value(nodes, &(&1["type"] == "startEvent" && &1["id"]))

  @doc "The element of the graph with `id`, or nil."
  def node(%{"nodes" => nodes}, id), do: Enum.find(nodes, &(&1["id"] == id))

  @doc "The flows that leave the element `id`, in the order the graph lists them."
  def out(%{"flows" => flows}, id), do: Enum.filter(flows, &(&1["from"] == id))

  @doc "The seconds of a duration the graph holds, such as `\"P3D\"`."
  def seconds(duration) when is_binary(duration) do
    case Regex.run(@duration_format, duration) do
      [_ | parts] when parts != [] ->
        [weeks, days, hours, minutes] = Enum.map(pad(parts, 4), &number/1)
        weeks * 604_800 + days * 86_400 + hours * 3_600 + minutes * 60

      _no_match ->
        nil
    end
  end

  defp pad(parts, n), do: parts ++ List.duplicate("", n - length(parts))

  defp number(""), do: 0
  defp number(digits), do: String.to_integer(digits)

  # ---------
  # Elements
  # ---------

  defp each(items, path, fun) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
      case fun.(item, "#{path}.#{i}") do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp element(%{"id" => id, "type" => type} = node, path) when is_binary(id) do
    with true <- Regex.match?(@id_format, id) || {:error, {path <> ".id", :invalid}},
         {:ok, element} <- typed(type, node, path, %{"id" => id, "type" => type}),
         {:ok, label} <- label(node["label"], path <> ".label") do
      {:ok, put_some(element, "label", label)}
    end
  end

  defp element(_node, path), do: {:error, {path, :invalid}}

  defp typed(type, _node, _path, base) when type in ~w(startEvent endEvent exclusiveGateway),
    do: {:ok, base}

  defp typed("serviceTask", node, path, base), do: action(node["action"], node, path, base)

  defp typed("userTask", node, path, base) do
    with {:ok, role} <- key(node["role"], path <> ".role"),
         {:ok, outcomes} <- outcomes(node["outcomes"], path <> ".outcomes"),
         {:ok, deadline} <- optional_duration(node["deadline"], path <> ".deadline") do
      {:ok,
       base
       |> Map.merge(%{"role" => role, "outcomes" => outcomes})
       |> put_some("deadline", deadline)}
    end
  end

  defp typed("timer", node, path, base) do
    with {:ok, duration} <- duration(node["duration"], path <> ".duration") do
      {:ok, Map.put(base, "duration", duration)}
    end
  end

  defp typed(_type, _node, path, _base), do: {:error, {path <> ".type", :invalid}}

  # A blank label is no label.
  defp label(nil, _path), do: {:ok, nil}

  defp label(label, path) when is_binary(label) do
    case String.trim(label) do
      "" ->
        {:ok, nil}

      label ->
        if String.length(label) <= @max_label, do: {:ok, label}, else: {:error, {path, :invalid}}
    end
  end

  defp label(_label, path), do: {:error, {path, :invalid}}

  defp action("message", node, path, base) do
    with {:ok, text} <- text(node["text"], @max_text, path <> ".text"),
         {:ok, target} <- target(Map.get(node, "in", "app"), path <> ".in") do
      {:ok, Map.merge(base, %{"action" => "message", "text" => text, "in" => target})}
    end
  end

  defp action("subgroup", node, path, base) do
    with {:ok, name} <- text(node["name"], @max_name, path <> ".name"),
         {:ok, admins} <- admins(Map.get(node, "admins", @default_admins), path <> ".admins") do
      {:ok, Map.merge(base, %{"action" => "subgroup", "name" => name, "admins" => admins})}
    end
  end

  defp action("push", node, path, base) do
    with {:ok, role} <- key(node["role"], path <> ".role"),
         {:ok, text} <- text(node["text"], @max_push_text, path <> ".text") do
      {:ok, Map.merge(base, %{"action" => "push", "role" => role, "text" => text})}
    end
  end

  defp action(_action, _node, path, _base), do: {:error, {path <> ".action", :invalid}}

  defp text(text, max, path) when is_binary(text) do
    text = String.trim(text)
    if String.length(text) in 1..max, do: {:ok, text}, else: {:error, {path, :invalid}}
  end

  defp text(_text, _max, path), do: {:error, {path, :invalid}}

  # A role key, as the app's manifest names it.
  defp key(key, _path) when is_binary(key) and byte_size(key) in 1..@max_key, do: {:ok, key}
  defp key(_key, path), do: {:error, {path, :invalid}}

  defp target("app", _path), do: {:ok, "app"}
  defp target(id, path) when is_binary(id), do: id_like(id, path)
  defp target(_target, path), do: {:error, {path, :invalid}}

  defp id_like(id, path),
    do: if(Regex.match?(@id_format, id), do: {:ok, id}, else: {:error, {path, :invalid}})

  defp admins(admins, path) when is_list(admins) and length(admins) in 1..@max_admins do
    with {:ok, admins} <- each(admins, path, &key/2) do
      {:ok, Enum.uniq(admins)}
    end
  end

  defp admins(_admins, path), do: {:error, {path, :invalid}}

  defp outcomes(outcomes, path) when is_list(outcomes) and length(outcomes) in 1..@max_outcomes do
    with {:ok, outcomes} <- each(outcomes, path, &text(&1, @max_outcome, &2)) do
      if length(Enum.uniq(outcomes)) == length(outcomes),
        do: {:ok, outcomes},
        else: {:error, {path, :duplicate}}
    end
  end

  defp outcomes(_outcomes, path), do: {:error, {path, :invalid}}

  defp optional_duration(nil, _path), do: {:ok, nil}
  defp optional_duration(duration, path), do: duration(duration, path)

  defp duration(duration, path) when is_binary(duration) do
    case seconds(duration) do
      seconds when is_integer(seconds) and seconds in @min_seconds..@max_seconds ->
        {:ok, duration}

      _other ->
        {:error, {path, :invalid}}
    end
  end

  defp duration(_duration, path), do: {:error, {path, :invalid}}

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp unique_ids(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {%{"id" => id}, i}, seen ->
      if MapSet.member?(seen, id),
        do: {:halt, {:error, {"nodes.#{i}.id", :duplicate}}},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  # ---------
  # Flows
  # ---------

  defp flow(%{"from" => from, "to" => to} = flow, path, ids)
       when is_binary(from) and is_binary(to) do
    cond do
      not MapSet.member?(ids, from) -> {:error, {path <> ".from", :unknown}}
      not MapSet.member?(ids, to) -> {:error, {path <> ".to", :unknown}}
      true -> flow_kind(flow, path, %{"from" => from, "to" => to})
    end
  end

  defp flow(_flow, path, _ids), do: {:error, {path, :invalid}}

  # A flow is plain, or leaves a task by an outcome or its deadline, or leaves
  # a gateway by a condition or as its default.
  defp flow_kind(flow, path, base) do
    case Map.take(flow, ~w(outcome deadline condition default)) do
      empty when map_size(empty) == 0 ->
        {:ok, base}

      %{"outcome" => outcome} = kind when map_size(kind) == 1 and is_binary(outcome) ->
        {:ok, Map.put(base, "outcome", outcome)}

      %{"deadline" => true} = kind when map_size(kind) == 1 ->
        {:ok, Map.put(base, "deadline", true)}

      %{"default" => true} = kind when map_size(kind) == 1 ->
        {:ok, Map.put(base, "default", true)}

      %{"condition" => condition} = kind when map_size(kind) == 1 ->
        with {:ok, condition} <- condition(condition, path <> ".condition") do
          {:ok, Map.put(base, "condition", condition)}
        end

      _mixed ->
        {:error, {path, :invalid}}
    end
  end

  defp condition(%{"field" => field, "op" => "empty"}, path) when is_binary(field),
    do: field(field, path, %{"field" => field, "op" => "empty"})

  defp condition(%{"field" => field, "op" => op, "value" => value}, path)
       when is_binary(field) and op in @ops and
              (is_binary(value) or is_number(value) or is_boolean(value)) do
    field(field, path, %{"field" => field, "op" => op, "value" => value})
  end

  defp condition(_condition, path), do: {:error, {path, :invalid}}

  defp field(field, path, condition) do
    if Regex.match?(@field_format, field),
      do: {:ok, condition},
      else: {:error, {path <> ".field", :invalid}}
  end

  # ---------
  # Shape
  # ---------

  defp shape(nodes, flows) do
    indexed = Enum.with_index(nodes)
    out = Enum.group_by(flows, & &1["from"])
    into = Enum.group_by(flows, & &1["to"])

    with :ok <- one_start(indexed),
         :ok <- some_end(nodes),
         :ok <- each_ok(indexed, &leaves(&1, Map.get(out, elem(&1, 0)["id"], []), into)),
         :ok <- each_ok(indexed, &subgroup_target(&1, nodes)),
         :ok <- reachable(indexed, out),
         :ok <- finishes(indexed, into) do
      :ok
    end
  end

  defp one_start(indexed) do
    case for({%{"type" => "startEvent"}, i} <- indexed, do: i) do
      [_one] -> :ok
      [] -> {:error, {"nodes", :no_start}}
      [_one, second | _] -> {:error, {"nodes.#{second}", :second_start}}
    end
  end

  defp some_end(nodes) do
    if Enum.any?(nodes, &(&1["type"] == "endEvent")),
      do: :ok,
      else: {:error, {"nodes", :no_end}}
  end

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # What may leave each element.
  defp leaves({%{"type" => "startEvent", "id" => id}, i}, out, into) do
    cond do
      Map.has_key?(into, id) -> {:error, {"nodes.#{i}", :start_incoming}}
      plain_one?(out) -> :ok
      true -> {:error, {"nodes.#{i}", :one_flow}}
    end
  end

  defp leaves({%{"type" => "endEvent"}, i}, out, _into),
    do: if(out == [], do: :ok, else: {:error, {"nodes.#{i}", :end_outgoing}})

  defp leaves({%{"type" => type}, i}, out, _into) when type in ~w(serviceTask timer),
    do: if(plain_one?(out), do: :ok, else: {:error, {"nodes.#{i}", :one_flow}})

  defp leaves({%{"type" => "userTask"} = task, i}, out, _into) do
    by_outcome = for %{"outcome" => outcome} <- out, do: outcome
    deadlines = Enum.count(out, &Map.has_key?(&1, "deadline"))
    others = Enum.reject(out, &(Map.has_key?(&1, "outcome") or Map.has_key?(&1, "deadline")))

    cond do
      others != [] ->
        {:error, {"nodes.#{i}", :plain_flow}}

      Enum.sort(by_outcome) != Enum.sort(task["outcomes"]) ->
        {:error, {"nodes.#{i}.outcomes", :no_flow}}

      deadlines != if(task["deadline"], do: 1, else: 0) ->
        {:error, {"nodes.#{i}.deadline", :no_flow}}

      true ->
        :ok
    end
  end

  defp leaves({%{"type" => "exclusiveGateway"}, i}, out, _into) do
    defaults = Enum.count(out, &Map.has_key?(&1, "default"))
    conditioned = Enum.count(out, &Map.has_key?(&1, "condition"))

    cond do
      defaults != 1 ->
        {:error, {"nodes.#{i}", :no_default}}

      conditioned < 1 or defaults + conditioned != length(out) ->
        {:error, {"nodes.#{i}", :conditions}}

      true ->
        :ok
    end
  end

  defp plain_one?([flow]), do: Map.keys(flow) -- ["from", "to"] == []
  defp plain_one?(_flows), do: false

  # A message goes to the app's group or to a sub-group the graph makes.
  defp subgroup_target({%{"action" => "message", "in" => "app"}, _i}, _nodes), do: :ok

  defp subgroup_target({%{"action" => "message", "in" => target}, i}, nodes) do
    if Enum.any?(nodes, &(&1["id"] == target and &1["action"] == "subgroup")),
      do: :ok,
      else: {:error, {"nodes.#{i}.in", :unknown}}
  end

  defp subgroup_target(_indexed, _nodes), do: :ok

  defp reachable(indexed, out) do
    [{%{"id" => start}, _}] = for {%{"type" => "startEvent"}, _} = item <- indexed, do: item

    seen =
      walk([start], MapSet.new([start]), &Enum.map(Map.get(out, &1, []), fn f -> f["to"] end))

    case Enum.find(indexed, fn {%{"id" => id}, _} -> not MapSet.member?(seen, id) end) do
      nil -> :ok
      {_node, i} -> {:error, {"nodes.#{i}", :unreachable}}
    end
  end

  defp finishes(indexed, into) do
    ends = for {%{"type" => "endEvent", "id" => id}, _} <- indexed, do: id
    seen = walk(ends, MapSet.new(ends), &Enum.map(Map.get(into, &1, []), fn f -> f["from"] end))

    case Enum.find(indexed, fn {%{"id" => id}, _} -> not MapSet.member?(seen, id) end) do
      nil -> :ok
      {_node, i} -> {:error, {"nodes.#{i}", :dead_end}}
    end
  end

  defp walk([], seen, _next), do: seen

  defp walk([id | rest], seen, next) do
    fresh = Enum.reject(next.(id), &MapSet.member?(seen, &1))
    walk(rest ++ fresh, Enum.into(fresh, seen), next)
  end
end
