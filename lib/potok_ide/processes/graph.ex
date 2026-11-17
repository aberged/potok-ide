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

  Only a process drawn in Potok (`normalize(graph, drawn: true)`) may also
  talk to the group's other drawn processes:

  - `callActivity`: starts the drawn `process` (its id) that starts when
    another process calls it, with `fields` (the names it takes, each a text
    as above), and waits for it to end unless `wait` is false, until an
    optional `deadline`. What it ended with comes back as
    `{{element.outcome}}`, with its fields and results.
  - `serviceTask` with the `action` `set`: sets the group's `field` to
    `value` (a text as above), or adds it as a number with `op` `add`, for
    every drawn process of the group to read as `{{group.field}}`
    (`PotokIde.Processes.GroupFields`).
  - `serviceTask` with the `action` `signal`: sends the signal `name` in the
    group, with `fields` (`[%{"name", "value"}]`, each value a text as
    above). It wakes the runs waiting for it there and starts the drawn
    processes that start on it.
  - `receiveTask`: waits for the `signal`, from a run on the same subject
    only when `same_subject`, until an optional `deadline`. What came is
    `{{element.from}}` and the fields it carried, as `{{element.field}}`.

  Any element may carry a `label`, the name it shows on a drawing and where
  an instance waits or stopped; its `id` stands in for it otherwise.

  There are no parallel flows: an instance stands on one element at a time.
  Durations are ISO 8601 (`PT30M`, `PT1H`, `P3D`, `P1W`). Texts may hold
  fields of the value, as `{{naslov}}`, and nothing else. A condition compares
  one field of the value: `=`, `!=`, `<`, `>` or `empty`.

  Errors come as `{path, reason}`, the path counted from the graph, such as
  `{"nodes.3.outcomes", :no_flow}`.

  ## Two languages

  A graph that names no version speaks the first language, described above
  (`PotokIde.Processes.Legacy`): an app's own process always does. A process
  drawn in Potok speaks today's with `"v" => 2`:

  - Texts hold expressions between `{{` and `}}`, and a condition is one
    expression, `%{"expr" => "ukupno > 10"}` (`PotokIde.Processes.Expr`).
  - An id is a name an expression may use: small letters, digits and `_`,
    and none of the words `PotokIde.Processes.Scope` keeps.
  - `variables` are what a run keeps for itself, each a name with the type
    of what it holds (`PotokIde.Processes.Types`), as an attribute of an
    entity has, and for a plain one an `initial` value: a text for a text,
    an expression for anything else.
  - `serviceTask` with the `action` `assign` sets its `target`, a variable
    or an attribute of one (`prijava.sprat`), to its `value`: a text for a
    text, an expression for anything else.
  - A `receiveTask` and a `serviceTask` `signal` may name the `entity` the
    signal carries, by its id: the wait then brings its attributes, and the
    signal's `fields` are its attributes, each a text for a text and an
    expression for anything else.
  - `loop` goes through a list an item at a time: `list` is an expression
    that gives the list, and `item` the name each item is read by while its
    turn lasts. It leaves by two flows: one with `"each" => true` into its
    body, taken once for every item, and a plain one, taken after the last.
    The body is closed: it comes back to the loop and nowhere else, reaches
    no end, and nothing but the loop leads into it (`body/2`). The loop's
    own id reads where it stands (`petlja.index`, from 1, and
    `petlja.count`). `of` is the type of an item, which
    `PotokIde.Processes.Check` wrote into it.
  - A `serviceTask` `assign` with the `op` `append` adds its `value` to the
    list its `target` holds.
  - `formTask` waits for a person to fill in the `entity` it names, by its
    id: whoever started the run (`by` `starter`), or someone holding `role`
    (`by` `role`), until an optional `deadline`. It may say something first
    (`intro`, a text) and start with something in some attributes
    (`values`, by name, each a text for a text and an expression for
    anything else), which the person may change. What was filled in is read
    under its id, an attribute at a time (`prijava.sprat`), with who filled
    it in (`prijava.author`).
  - An `endEvent` of a process that hands an entity back to its caller
    says what each attribute is (`values`, as a `formTask` starts with
    them); the graph keeps that entity's id as `returns`, and a
    `callActivity` that waits keeps the id of the entity its process hands
    back as `returns` too, both written by `PotokIde.Processes.Check`.
  - `zone` is the time zone it reads days and hours in, and `entry` and
    `types` are what `PotokIde.Processes.Check` wrote into it.

  `upgrade/1` turns the first into today's.
  """

  alias PotokIde.Processes.{Legacy, Scope, Types}

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
  @name_id_format ~r/^[a-z][a-z0-9_]{0,39}$/
  @target_format ~r/^[\p{L}_][\p{L}\p{Nd}_]*(\.[\p{L}_][\p{L}\p{Nd}_]*)*$/u
  @max_variables 30
  @max_options 30
  @max_option 60
  @field_format ~r/^[\p{L}\p{Nd}_.-]{1,64}$/u
  @duration_format ~r/^P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?)$/
  @ops ~w(= != < > empty)
  @default_admins ["owner", "triggered_by"]
  @max_call_fields 10
  @max_template 1_000
  @name_format ~r/^[\p{L}\p{Nd}_-]{1,40}$/u
  @signal_format ~r/^[\p{L}\p{Nd}_-]{2,40}$/u
  @max_signal_fields 10
  # The attributes a form may start with something in.
  @max_form_values 50
  # What a signal always carries besides its fields.
  @signal_reserved ~w(from signal)

  # What each action needs the process profile to hold in the app's group.
  @action_permissions %{
    "message" => :post_values,
    "subgroup" => :create_subgroups,
    "push" => :mention_roles
  }

  @doc """
  The graph as Potok keeps it: known keys only, defaults filled in, and every
  element able to reach an end. `{:error, {path, reason}}` otherwise. With
  `drawn: true`, for a process drawn in Potok, it may call another.
  """
  def normalize(graph, opts \\ [])

  def normalize(%{"nodes" => nodes, "flows" => flows} = graph, opts)
      when is_list(nodes) and is_list(flows) do
    drawn? = Keyword.get(opts, :drawn, false)

    cond do
      nodes == [] ->
        {:error, {"nodes", :empty}}

      length(nodes) > @max_nodes ->
        {:error, {"nodes", :too_many}}

      length(flows) > @max_flows ->
        {:error, {"flows", :too_many}}

      true ->
        with {:ok, version} <- version(graph, drawn?),
             {:ok, nodes} <- each(nodes, "nodes", &element(&1, &2, drawn?, version)),
             :ok <- unique_ids(nodes),
             ids = MapSet.new(nodes, & &1["id"]),
             {:ok, flows} <- each(flows, "flows", &flow(&1, &2, ids, version)),
             :ok <- of_its_language(nodes, version),
             {:ok, names} <- with_items(nodes, ids),
             :ok <- shape(nodes, flows),
             {:ok, kept} <- kept(graph, version, names) do
          {:ok, Map.merge(kept, %{"nodes" => nodes, "flows" => flows})}
        end
    end
  end

  def normalize(_graph, _opts), do: {:error, {"", :invalid}}

  # Only a process drawn in Potok speaks today's language (`"v" => 2`); a
  # graph that names no version speaks the first (`Legacy`).
  defp version(%{"v" => 2}, true), do: {:ok, 2}
  defp version(%{"v" => _other}, _drawn?), do: {:error, {"v", :invalid}}
  defp version(_graph, _drawn?), do: {:ok, 1}

  # What a graph of today keeps beside its elements: its version, the time
  # zone it reads days and hours in, and what `Check.run/2` wrote into it.
  defp kept(_graph, 1, _ids), do: {:ok, %{}}

  defp kept(graph, 2, ids) do
    zone = Map.get(graph, "zone", "Etc/UTC")

    with true <-
           (is_binary(zone) and match?({:ok, _now}, DateTime.now(zone))) ||
             {:error, {"zone", :invalid}},
         {:ok, variables} <- variables(Map.get(graph, "variables", []), ids) do
      {:ok,
       %{"v" => 2, "zone" => zone, "variables" => variables}
       |> put_map("entry", graph["entry"])
       |> put_map("types", graph["types"])
       |> put_id("returns", graph["returns"])}
    end
  end

  # Only today's language sets variables, goes through lists and asks forms.
  defp of_its_language(_nodes, 2), do: :ok

  defp of_its_language(nodes, 1) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn
      {%{"type" => type}, i} when type in ~w(loop formTask) ->
        {:error, {"nodes.#{i}.type", :invalid}}

      {%{"action" => "assign"}, i} ->
        {:error, {"nodes.#{i}.action", :invalid}}

      _other ->
        nil
    end)
  end

  # The names the steps take: their ids, and the item of each loop, which
  # no step and no other loop may share.
  defp with_items(nodes, ids) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, ids}, fn
      {%{"type" => "loop", "item" => item}, i}, {:ok, taken} ->
        if MapSet.member?(taken, item),
          do: {:halt, {:error, {"nodes.#{i}.item", :taken}}},
          else: {:cont, {:ok, MapSet.put(taken, item)}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  # What a run keeps for itself: each a name no step and no other variable
  # has, with the type of what it holds.
  defp variables(variables, ids)
       when is_list(variables) and length(variables) <= @max_variables do
    variables
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], ids}, fn {variable, i}, {:ok, acc, taken} ->
      case variable(variable, "variables.#{i}", taken) do
        {:ok, variable} -> {:cont, {:ok, [variable | acc], MapSet.put(taken, variable["name"])}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, variables, _taken} -> {:ok, Enum.reverse(variables)}
      error -> error
    end
  end

  defp variables(variables, _ids) when is_list(variables), do: {:error, {"variables", :too_many}}
  defp variables(_variables, _ids), do: {:error, {"variables", :invalid}}

  defp variable(%{"name" => name, "type" => type} = variable, path, taken) when is_binary(name) do
    name = String.trim(name)
    list = Map.get(variable, "list", false)

    cond do
      not Types.name?(name) or name in Scope.reserved() -> {:error, {path <> ".name", :invalid}}
      MapSet.member?(taken, name) -> {:error, {path <> ".name", :taken}}
      type not in Types.kinds() -> {:error, {path <> ".type", :invalid}}
      not is_boolean(list) -> {:error, {path <> ".list", :invalid}}
      true -> held(%{"name" => name, "type" => type, "list" => list}, variable, path)
    end
  end

  defp variable(_variable, path, _taken), do: {:error, {path, :invalid}}

  defp held(%{"type" => "choice"} = base, variable, path) do
    case variable["options"] do
      [_ | _] = options when length(options) <= @max_options ->
        if Enum.all?(options, &(is_binary(&1) and String.length(&1) in 1..@max_option)) and
             options == Enum.uniq(options),
           do: initial(Map.put(base, "options", options), variable, path),
           else: {:error, {path <> ".options", :invalid}}

      _none_or_too_many ->
        {:error, {path <> ".options", :invalid}}
    end
  end

  defp held(%{"type" => "entity"} = base, variable, path) do
    case variable["entity"] do
      id when is_integer(id) and id > 0 -> {:ok, Map.put(base, "entity", id)}
      _other -> {:error, {path <> ".entity", :invalid}}
    end
  end

  defp held(base, variable, path), do: initial(base, variable, path)

  # A plain variable may start with a value; a list starts empty.
  defp initial(%{"list" => true} = base, _variable, _path), do: {:ok, base}

  defp initial(base, variable, path) do
    case variable["initial"] do
      nil ->
        {:ok, base}

      text when is_binary(text) ->
        case String.trim(text) do
          "" -> {:ok, base}
          text when byte_size(text) <= @max_template -> {:ok, Map.put(base, "initial", text)}
          _too_long -> {:error, {path <> ".initial", :invalid}}
        end

      _other ->
        {:error, {path <> ".initial", :invalid}}
    end
  end

  defp put_map(map, key, %{} = value), do: Map.put(map, key, value)
  defp put_map(map, _key, _none), do: map

  defp put_id(map, key, id) when is_integer(id), do: Map.put(map, key, id)
  defp put_id(map, _key, _none), do: map

  @doc """
  A graph in today's language (`"v" => 2`, `PotokIde.Processes.Expr`), from
  one that names no version, saying the same: a field of what set the
  process going is now read under the id of its start (`{{naslov}}` becomes
  `{{start.naslov}}`), a condition is an expression (`start.sprat > "2"`),
  and the ids of its elements hold `_` where they held `-`, as an id is now
  a name an expression may use. Flows keep the keys an editor gave them.

  Returns `{graph, ids}`, `ids` being the new id of each element by its old
  one. A graph of today comes back as it is.
  """
  def upgrade(%{"v" => 2, "nodes" => nodes} = graph),
    do: {graph, Map.new(nodes, &{&1["id"], &1["id"]})}

  def upgrade(%{"nodes" => nodes, "flows" => flows} = graph) do
    ids = new_ids(nodes)
    path = &upgrade_path(&1, ids, ids[start(graph)])

    nodes = Enum.map(nodes, &upgrade_node(&1, ids, path))

    flows =
      Enum.map(flows, fn flow ->
        flow = %{flow | "from" => ids[flow["from"]], "to" => ids[flow["to"]]}

        case flow do
          %{"condition" => condition} ->
            %{flow | "condition" => upgrade_condition(condition, path)}

          _other ->
            flow
        end
      end)

    {Map.merge(graph, %{"v" => 2, "nodes" => nodes, "flows" => flows}), ids}
  end

  # Each id as a name: `_` for `-`, and aside from the words expressions keep.
  defp new_ids(nodes) do
    Enum.reduce(nodes, %{}, fn %{"id" => id}, ids ->
      base = String.replace(id, "-", "_")
      base = if base in Scope.reserved(), do: base <> "_1", else: base
      taken = ids |> Map.values() |> MapSet.new()

      new =
        Stream.iterate(1, &(&1 + 1))
        |> Stream.map(fn
          1 -> base
          n -> String.slice(base, 0, 36) <> "_#{n}"
        end)
        |> Enum.find(&(not MapSet.member?(taken, &1)))

      Map.put(ids, id, new)
    end)
  end

  defp upgrade_node(%{"id" => id} = node, ids, path) do
    node = %{node | "id" => ids[id]}
    text = &Regex.replace(Legacy.placeholder(), &1, fn _whole, field -> "{{#{path.(field)}}}" end)

    case node do
      %{"action" => "message", "text" => old, "in" => target} ->
        %{node | "text" => text.(old), "in" => Map.get(ids, target, target)}

      %{"action" => action, "text" => old} when action in ~w(message push) ->
        %{node | "text" => text.(old)}

      %{"action" => "subgroup", "name" => old} ->
        %{node | "name" => text.(old)}

      %{"action" => "set", "value" => old} ->
        %{node | "value" => text.(old)}

      %{"action" => "signal", "fields" => fields} ->
        %{node | "fields" => Enum.map(fields, &%{&1 | "value" => text.(&1["value"])})}

      %{"type" => "callActivity", "fields" => fields} ->
        %{node | "fields" => Map.new(fields, fn {name, old} -> {name, text.(old)} end)}

      _other ->
        node
    end
  end

  # A path of the first language as an expression: under the id of an
  # element, under `group`, or else a field of what set the process going.
  defp upgrade_path(path, ids, start) do
    [first | rest] = String.split(path, ".")

    cond do
      first == "group" -> Enum.reduce(rest, "group", &Scope.path(&2, &1))
      is_map_key(ids, first) -> Enum.reduce(rest, ids[first], &Scope.path(&2, &1))
      true -> Enum.reduce([first | rest], start, &Scope.path(&2, &1))
    end
  end

  # The value stays a text, as it always compared: as numbers when both
  # sides are numbers.
  defp upgrade_condition(%{"field" => field, "op" => "empty"}, path),
    do: %{"expr" => "empty(#{path.(field)})"}

  defp upgrade_condition(%{"field" => field, "op" => op, "value" => value}, path) do
    value = value |> to_string() |> String.replace(["\\", "\""], &("\\" <> &1))
    %{"expr" => ~s(#{path.(field)} #{op} "#{value}")}
  end

  defp upgrade_condition(condition, _path), do: condition

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

      {%{"type" => "formTask", "by" => "role", "role" => role}, i} ->
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

  @doc """
  The drawn processes the graph calls, as `{path, id, names}`: the path of
  the element, the process's id and the names of the fields it hands over.
  """
  def process_refs(%{"nodes" => nodes}) do
    for {%{"type" => "callActivity"} = call, i} <- Enum.with_index(nodes),
        do: {"nodes.#{i}", call["process"], Map.keys(call["fields"])}
  end

  @doc """
  The first call of the graph to a process that is not among `callable` (a
  map of the ids of the group's processes that another may call to the
  names of the fields each takes), as `{path, :unknown_process}`, or to a
  field that process does not take, as `{path, :unknown_field}`; or nil.
  """
  def unknown_process(graph, callable) when is_map(callable) do
    Enum.find_value(process_refs(graph), fn {path, id, names} ->
      case Map.fetch(callable, id) do
        {:ok, taken} ->
          case Enum.find(names, &(&1 not in taken)) do
            nil -> nil
            name -> {"#{path}.fields.#{name}", :unknown_field}
          end

        :error ->
          {path <> ".process", :unknown_process}
      end
    end)
  end

  @doc """
  A signal's name as Potok keeps it: trimmed and in small letters, 2 to 40
  letters, digits, `-` or `_`. `:error` otherwise.
  """
  def signal_name(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()
    if Regex.match?(@signal_format, name), do: {:ok, name}, else: :error
  end

  def signal_name(_name), do: :error

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

  @doc """
  The ids of the steps in the body of the loop `id`: what its `each` flow
  reaches before coming back to the loop. None for a loop whose flow leads
  nowhere but to itself.
  """
  def body(%{"flows" => flows} = graph, id) do
    next = Enum.group_by(flows, & &1["from"], & &1["to"])

    case Enum.find(out(graph, id), &(&1["each"] == true)) do
      %{"to" => ^id} ->
        []

      %{"to" => first} ->
        [first]
        |> walk(MapSet.new([first, id]), &Map.get(next, &1, []))
        |> MapSet.delete(id)
        |> MapSet.to_list()
        |> Enum.sort()

      nil ->
        []
    end
  end

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

  defp element(%{"id" => id, "type" => type} = node, path, drawn?, version) when is_binary(id) do
    with :ok <- id(id, path <> ".id", version),
         {:ok, element} <- typed(type, node, path, %{"id" => id, "type" => type}, drawn?),
         {:ok, label} <- label(node["label"], path <> ".label") do
      {:ok, put_some(element, "label", label)}
    end
  end

  defp element(_node, path, _drawn?, _version), do: {:error, {path, :invalid}}

  # In today's language an id is a name an expression may use.
  defp id(id, path, 1),
    do: if(Regex.match?(@id_format, id), do: :ok, else: {:error, {path, :invalid}})

  defp id(id, path, 2) do
    cond do
      not Regex.match?(@name_id_format, id) -> {:error, {path, :invalid}}
      id in Scope.reserved() -> {:error, {path, :reserved}}
      true -> :ok
    end
  end

  # An end of a process that hands an entity back to its caller says what
  # each attribute is (`values`, as a form starts with them).
  defp typed("endEvent", node, path, base, true) do
    with {:ok, values} <- form_values(Map.get(node, "values", %{}), path <> ".values") do
      {:ok, put_some(base, "values", if(values == %{}, do: nil, else: values))}
    end
  end

  defp typed(type, _node, _path, base, _drawn?)
       when type in ~w(startEvent endEvent exclusiveGateway),
       do: {:ok, base}

  defp typed("serviceTask", %{"action" => "set"} = node, path, base, true),
    do: set_field(node, path, base)

  defp typed("serviceTask", %{"action" => "assign"} = node, path, base, true) do
    target = node["target"]
    value = node["value"]
    op = Map.get(node, "op", "set")

    cond do
      not (is_binary(target) and Regex.match?(@target_format, String.trim(target))) ->
        {:error, {path <> ".target", :invalid}}

      op not in ~w(set append) ->
        {:error, {path <> ".op", :invalid}}

      not (is_binary(value) and String.length(value) <= @max_template) ->
        {:error, {path <> ".value", :invalid}}

      true ->
        {:ok,
         Map.merge(base, %{
           "action" => "assign",
           "target" => String.trim(target),
           "op" => op,
           "value" => String.trim(value)
         })}
    end
  end

  defp typed("serviceTask", %{"action" => "signal"} = node, path, base, true) do
    with {:ok, name} <- signal(node["name"], path <> ".name"),
         {:ok, fields} <- signal_fields(Map.get(node, "fields", []), path <> ".fields"),
         {:ok, entity} <- entity(node["entity"], path <> ".entity") do
      {:ok,
       base
       |> Map.merge(%{"action" => "signal", "name" => name, "fields" => fields})
       |> put_some("entity", entity)}
    end
  end

  defp typed("receiveTask", node, path, base, true) do
    same_subject = Map.get(node, "same_subject", false)

    with {:ok, signal} <- signal(node["signal"], path <> ".signal"),
         true <- is_boolean(same_subject) || {:error, {path <> ".same_subject", :invalid}},
         {:ok, deadline} <- optional_duration(node["deadline"], path <> ".deadline"),
         {:ok, entity} <- entity(node["entity"], path <> ".entity") do
      {:ok,
       base
       |> Map.merge(%{"signal" => signal, "same_subject" => same_subject})
       |> put_some("deadline", deadline)
       |> put_some("entity", entity)}
    end
  end

  # A form: the entity it asks for and who fills it in. One that names no
  # entity yet is told by `Check`, as a drawing may stand so for a while.
  defp typed("formTask", node, path, base, true) do
    by = Map.get(node, "by", "starter")

    with true <- by in ~w(starter role) || {:error, {path <> ".by", :invalid}},
         {:ok, role} <- form_role(by, node["role"], path <> ".role"),
         {:ok, entity} <- entity(node["entity"], path <> ".entity"),
         {:ok, deadline} <- optional_duration(node["deadline"], path <> ".deadline"),
         {:ok, intro} <- optional_template(node["intro"], path <> ".intro"),
         {:ok, values} <- form_values(Map.get(node, "values", %{}), path <> ".values") do
      {:ok,
       base
       |> Map.put("by", by)
       |> put_some("role", role)
       |> put_some("entity", entity)
       |> put_some("deadline", deadline)
       |> put_some("intro", intro)
       |> put_some("values", if(values == %{}, do: nil, else: values))}
    end
  end

  defp typed("serviceTask", node, path, base, _drawn?),
    do: action(node["action"], node, path, base)

  defp typed("userTask", node, path, base, _drawn?) do
    with {:ok, role} <- key(node["role"], path <> ".role"),
         {:ok, outcomes} <- outcomes(node["outcomes"], path <> ".outcomes"),
         {:ok, deadline} <- optional_duration(node["deadline"], path <> ".deadline") do
      {:ok,
       base
       |> Map.merge(%{"role" => role, "outcomes" => outcomes})
       |> put_some("deadline", deadline)}
    end
  end

  defp typed("timer", node, path, base, _drawn?) do
    with {:ok, duration} <- duration(node["duration"], path <> ".duration") do
      {:ok, Map.put(base, "duration", duration)}
    end
  end

  # A loop: the list it goes through, as an expression `Check` reads, and
  # the name of an item. A blank list is told by `Check`, as a drawing may
  # stand so for a while.
  defp typed("loop", node, path, base, true) do
    list = node["list"]
    item = node["item"]

    cond do
      not (is_binary(list) and String.length(list) <= @max_template) ->
        {:error, {path <> ".list", :invalid}}

      not (is_binary(item) and Types.name?(String.trim(item))) or
          String.trim(item) in Scope.reserved() ->
        {:error, {path <> ".item", :invalid}}

      true ->
        {:ok,
         base
         |> Map.merge(%{"list" => String.trim(list), "item" => String.trim(item)})
         |> put_map("of", node["of"])}
    end
  end

  defp typed("callActivity", node, path, base, true) do
    wait = Map.get(node, "wait", true)

    with {:ok, process} <- process_id(node["process"], path <> ".process"),
         true <- is_boolean(wait) || {:error, {path <> ".wait", :invalid}},
         {:ok, fields} <- call_fields(Map.get(node, "fields", %{}), path <> ".fields"),
         {:ok, deadline} <- optional_duration(node["deadline"], path <> ".deadline"),
         true <- (wait or is_nil(deadline)) || {:error, {path <> ".deadline", :invalid}} do
      {:ok,
       base
       |> Map.merge(%{"process" => process, "wait" => wait, "fields" => fields})
       |> put_some("deadline", deadline)
       |> put_id("returns", node["returns"])}
    end
  end

  defp typed(_type, _node, path, _base, _drawn?), do: {:error, {path <> ".type", :invalid}}

  # A text that may be left out: blank is none.
  defp optional_template(nil, _path), do: {:ok, nil}

  defp optional_template(text, path) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, nil}
      text when byte_size(text) <= @max_template -> {:ok, text}
      _too_long -> {:error, {path, :invalid}}
    end
  end

  defp optional_template(_text, path), do: {:error, {path, :invalid}}

  # What a form starts with, by the name of an attribute, each a text or an
  # expression as `Check` reads it; one left blank starts empty.
  defp form_values(values, path) when is_map(values) and map_size(values) <= @max_form_values do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, written}, {:ok, acc} ->
      cond do
        not (is_binary(name) and Types.name?(name)) ->
          {:halt, {:error, {"#{path}.#{name}", :invalid}}}

        not (is_binary(written) and String.length(written) <= @max_template) ->
          {:halt, {:error, {"#{path}.#{name}", :invalid}}}

        String.trim(written) == "" ->
          {:cont, {:ok, acc}}

        true ->
          {:cont, {:ok, Map.put(acc, name, String.trim(written))}}
      end
    end)
  end

  defp form_values(_values, path), do: {:error, {path, :invalid}}

  # A field of the group, set or added to. Adding needs a number, or a text
  # that may come out as one.
  defp set_field(node, path, base) do
    op = Map.get(node, "op", "set")
    value = node["value"]

    cond do
      not (is_binary(node["field"]) and Regex.match?(@name_format, node["field"])) ->
        {:error, {path <> ".field", :invalid}}

      op not in ~w(set add) ->
        {:error, {path <> ".op", :invalid}}

      not (is_binary(value) and String.length(value) <= @max_template) ->
        {:error, {path <> ".value", :invalid}}

      op == "add" and not number_or_field?(String.trim(value)) ->
        {:error, {path <> ".value", :not_a_number}}

      true ->
        {:ok,
         Map.merge(base, %{
           "action" => "set",
           "field" => node["field"],
           "op" => op,
           "value" => String.trim(value)
         })}
    end
  end

  # Only a form the people of a role fill in names one.
  defp form_role("role", role, path), do: key(role, path)
  defp form_role(_starter, _role, _path), do: {:ok, nil}

  # The entity a signal carries or a form asks for, by its id; none where it
  # names none.
  defp entity(nil, _path), do: {:ok, nil}
  defp entity(id, _path) when is_integer(id) and id > 0, do: {:ok, id}
  defp entity(_id, path), do: {:error, {path, :invalid}}

  defp signal(name, path) do
    case signal_name(name) do
      {:ok, name} -> {:ok, name}
      :error -> {:error, {path, :invalid}}
    end
  end

  # The fields a signal carries, in order, each name once.
  defp signal_fields(fields, path)
       when is_list(fields) and length(fields) <= @max_signal_fields do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn
      {%{"name" => name, "value" => value}, i}, {:ok, acc, seen}
      when is_binary(name) and is_binary(value) ->
        name = String.trim(name)

        cond do
          not Regex.match?(@name_format, name) or name in @signal_reserved or
              MapSet.member?(seen, name) ->
            {:halt, {:error, {"#{path}.#{i}.name", :invalid}}}

          String.length(value) > @max_template ->
            {:halt, {:error, {"#{path}.#{i}.value", :invalid}}}

          true ->
            field = %{"name" => name, "value" => String.trim(value)}
            {:cont, {:ok, [field | acc], MapSet.put(seen, name)}}
        end

      {_field, i}, _acc ->
        {:halt, {:error, {"#{path}.#{i}", :invalid}}}
    end)
    |> case do
      {:ok, fields, _seen} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp signal_fields(_fields, path), do: {:error, {path, :invalid}}

  defp number_or_field?(text) do
    String.contains?(text, "{{") or
      match?({_n, ""}, Float.parse(String.replace(text, ",", "."))) or
      match?({_n, ""}, Integer.parse(text))
  end

  defp process_id(id, _path) when is_integer(id) and id > 0, do: {:ok, id}
  defp process_id(_id, path), do: {:error, {path, :invalid}}

  # The fields a call hands over, by the names the called process takes, each
  # a text that may be empty.
  defp call_fields(fields, path) when is_map(fields) and map_size(fields) <= @max_call_fields do
    Enum.reduce_while(fields, {:ok, %{}}, fn {name, text}, {:ok, acc} ->
      cond do
        not (is_binary(name) and Regex.match?(@name_format, name)) ->
          {:halt, {:error, {"#{path}.#{name}", :invalid}}}

        not (is_binary(text) and String.length(text) <= @max_template) ->
          {:halt, {:error, {"#{path}.#{name}", :invalid}}}

        true ->
          {:cont, {:ok, Map.put(acc, name, String.trim(text))}}
      end
    end)
  end

  defp call_fields(_fields, path), do: {:error, {path, :invalid}}

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

  defp flow(%{"from" => from, "to" => to} = flow, path, ids, version)
       when is_binary(from) and is_binary(to) do
    cond do
      not MapSet.member?(ids, from) -> {:error, {path <> ".from", :unknown}}
      not MapSet.member?(ids, to) -> {:error, {path <> ".to", :unknown}}
      true -> flow_kind(flow, path, %{"from" => from, "to" => to}, version)
    end
  end

  defp flow(_flow, path, _ids, _version), do: {:error, {path, :invalid}}

  # A flow is plain, or leaves a task by an outcome or its deadline, or leaves
  # a gateway by a condition or as its default, or a loop into its body.
  defp flow_kind(flow, path, base, version) do
    case Map.take(flow, ~w(outcome deadline condition default each)) do
      empty when map_size(empty) == 0 ->
        {:ok, base}

      %{"outcome" => outcome} = kind when map_size(kind) == 1 and is_binary(outcome) ->
        {:ok, Map.put(base, "outcome", outcome)}

      %{"deadline" => true} = kind when map_size(kind) == 1 ->
        {:ok, Map.put(base, "deadline", true)}

      %{"default" => true} = kind when map_size(kind) == 1 ->
        {:ok, Map.put(base, "default", true)}

      %{"each" => true} = kind when map_size(kind) == 1 ->
        {:ok, Map.put(base, "each", true)}

      %{"condition" => condition} = kind when map_size(kind) == 1 ->
        with {:ok, condition} <- condition(condition, path <> ".condition", version) do
          {:ok, Map.put(base, "condition", condition)}
        end

      _mixed ->
        {:error, {path, :invalid}}
    end
  end

  # Today a condition is one expression, which `Check` reads; in the first
  # language it compares one field.
  defp condition(%{"expr" => expression}, path, 2) when is_binary(expression) do
    expression = String.trim(expression)

    if String.length(expression) in 1..@max_template,
      do: {:ok, %{"expr" => expression}},
      else: {:error, {path, :invalid}}
  end

  defp condition(%{"field" => field, "op" => "empty"}, path, 1) when is_binary(field),
    do: field(field, path, %{"field" => field, "op" => "empty"})

  defp condition(%{"field" => field, "op" => op, "value" => value}, path, 1)
       when is_binary(field) and op in @ops and
              (is_binary(value) or is_number(value) or is_boolean(value)) do
    field(field, path, %{"field" => field, "op" => op, "value" => value})
  end

  defp condition(_condition, path, _version), do: {:error, {path, :invalid}}

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
         :ok <- finishes(indexed, into),
         :ok <- each_ok(indexed, &closed_body(&1, nodes, flows)) do
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

  # A call, a wait or a form goes on by one plain flow, and by a second when
  # its deadline passes.
  defp leaves({%{"type" => type} = element, i}, out, _into)
       when type in ~w(callActivity receiveTask formTask) do
    {deadlines, plain} = Enum.split_with(out, &Map.has_key?(&1, "deadline"))

    cond do
      not plain_one?(plain) ->
        {:error, {"nodes.#{i}", :one_flow}}

      length(deadlines) != if(element["deadline"], do: 1, else: 0) ->
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

  # A loop goes into its body by one flow and on by one plain flow.
  defp leaves({%{"type" => "loop"}, i}, out, _into) do
    {body, others} = Enum.split_with(out, &Map.has_key?(&1, "each"))

    if length(body) == 1 and plain_one?(others),
      do: :ok,
      else: {:error, {"nodes.#{i}", :loop_flows}}
  end

  defp plain_one?([flow]), do: Map.keys(flow) -- ["from", "to"] == []
  defp plain_one?(_flows), do: false

  # The body of a loop is closed: it has a step, reaches no end, and is
  # entered through the loop alone, so every turn comes back to the loop.
  defp closed_body({%{"type" => "loop", "id" => id}, i}, nodes, flows) do
    body = body(%{"nodes" => nodes, "flows" => flows}, id)
    types = Map.new(nodes, &{&1["id"], &1["type"]})

    cond do
      body == [] ->
        {:error, {"nodes.#{i}", :loop_empty}}

      Enum.any?(body, &(types[&1] == "endEvent")) ->
        {:error, {"nodes.#{i}", :loop_open}}

      Enum.any?(flows, fn flow ->
        flow["to"] in body and flow["from"] not in body and
            not (flow["from"] == id and flow["each"] == true)
      end) ->
        {:error, {"nodes.#{i}", :loop_entered}}

      true ->
        :ok
    end
  end

  defp closed_body(_indexed, _nodes, _flows), do: :ok

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
