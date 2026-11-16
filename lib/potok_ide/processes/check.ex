defmodule PotokIde.Processes.Check do
  @moduledoc """
  Checks what a process drawn in Potok says against what it has
  (`PotokIde.Processes.Scope`), when it is saved and as it is drawn: every
  expression in its texts and conditions must name what is there, and give
  what is asked for (`PotokIde.Processes.Expr`). `Graph.normalize/2` has
  checked the drawing's shape before.

  `run/2` takes what the graph cannot know by itself, as `env`:

  - `:trigger` and `:config`: what sets the process going
    (`PotokIde.Processes.Triggers`), and `:entry_entity`, the id of the
    entity it takes then, if it takes one. A test may give `:entry`, the
    type of what the trigger hands a run, instead of the three.
  - `:entities`: the entities of its group, by id
    (`PotokIde.Processes.GroupEntities.definitions/1`).
  - `:callable`: the processes it may call, by id, each as `%{attributes:
    [_], types: %{}}`: the attributes of the entity it takes, with the
    entities those name, as that process was saved. One that takes fields
    with no entity has no attributes.
  - `:signals`: the entities the other processes of the group wait for a
    signal with, by the signal's name (nil for one that names none).

  It returns the graph as it is kept, with that written into it (`entry`,
  and `types`: the entities the graph names and those nest, as they are
  just now), so a run reads its names with no look elsewhere, and goes on
  reading them so after an entity changed.

  What it checks beside the expressions:

  - A variable, a wait for a signal and a signal sent hold entities the
    group has; a process started by hand takes one whose attributes are
    all plain, as a form fills it in.
  - A step that sets names a variable, or an attribute of one; one that
    adds to a list names a list, and gives what the list holds.
  - A loop goes through a list: its `list` gives one, and what an item of
    it is gets written into the loop (`of`), so the steps of its body read
    the item by its type. A loop may go through what an outer loop's item
    holds.
  - A call hands the process it calls what its entity takes: each attribute
    a value of its type, and every required one a value.
  - A signal is sent with the entity those who wait for it expect, where
    someone does, and carries its attributes the same way.

  Errors come as `{path, reason}`, as the graph's do, such as
  `{"nodes.3.text", {:unknown_name, "naslov"}}`: the reasons of
  `Expr.parse/1` and `Expr.check/2`, and `:unknown_entity`, `:not_flat`,
  `{:not_a_variable, name}`, `:required`, `:signal_entity` and `:no_list`.

  A graph without a version says nothing that could be checked
  (`PotokIde.Processes.Legacy`), and comes back as it is.
  """

  alias PotokIde.Processes.{Expr, Scope, Triggers, Types}

  def run(%{"v" => 2, "flows" => flows} = graph, env) when is_map(env) do
    variables = graph["variables"] || []

    with {:ok, types} <- types(graph, env),
         {:ok, entry} <- entry(env, types),
         graph = graph |> Map.put("entry", Types.json(entry)) |> Map.put("types", types),
         {:ok, %{"nodes" => nodes} = graph} <- items(graph) do
      scope = Scope.scope(graph)

      context = %{
        scope: scope,
        callable: Map.get(env, :callable, %{}),
        receivers: receivers(graph, env)
      }

      with :ok <- each(variables, "variables", &variable(&1, &2, scope)),
           :ok <- each(nodes, "nodes", &step(&1, &2, context)),
           :ok <- each(flows, "flows", &flow(&1, &2, scope)) do
        {:ok, graph}
      end
    end
  end

  def run(graph, _env), do: {:ok, graph}

  @doc """
  The graph with what an item of each loop is written into the loop (`of`),
  from the list it goes through: `{:ok, graph}`, or `{:error, {path,
  reason}}` for the first loop whose list cannot be told. A loop inside
  another may go through what the outer item holds, so they are read until
  no more can be.

  `loose: true` never fails: a loop that cannot be told yet reads its item
  as anything, for a drawing in the making.
  """
  def items(%{"nodes" => nodes} = graph, opts \\ []) do
    # What a kept graph said about its items says nothing about this one.
    nodes = Enum.map(nodes, &Map.delete(&1, "of"))
    loops = for {%{"type" => "loop"}, i} <- Enum.with_index(nodes), do: i

    case told(%{graph | "nodes" => nodes}, loops) do
      {graph, []} -> {:ok, graph}
      {graph, [_ | _]} when opts == [loose: true] -> {:ok, graph}
      {_graph, [{i, reason} | _rest]} -> {:error, {"nodes.#{i}.list", reason}}
    end
  end

  # Loops are told while one more can be: each pass reads those left against
  # the names the earlier passes gave.
  defp told(graph, []), do: {graph, []}

  defp told(graph, left) do
    # The item of a loop not told yet is no name: a list that goes through
    # it waits for the pass after its loop's.
    pending = for i <- left, do: Enum.at(graph["nodes"], i)["item"]
    scope = Map.update!(Scope.scope(graph), :names, &Map.drop(&1, pending))

    {graph, failed} =
      Enum.reduce(left, {graph, []}, fn i, {graph, failed} ->
        case item(Enum.at(graph["nodes"], i), scope) do
          {:ok, type} ->
            nodes = List.update_at(graph["nodes"], i, &Map.put(&1, "of", Types.json(type)))
            {%{graph | "nodes" => nodes}, failed}

          {:error, reason} ->
            {graph, failed ++ [{i, reason}]}
        end
      end)

    if length(failed) < length(left),
      do: told(graph, Enum.map(failed, &elem(&1, 0))),
      else: {graph, failed}
  end

  # What an item of the list a loop goes through is.
  defp item(%{"list" => list}, scope) do
    if String.trim(list) == "" do
      {:error, :no_list}
    else
      with {:ok, tree} <- Expr.parse(list),
           {:ok, type} <- Expr.check(tree, scope) do
        case type do
          {:list, item} -> {:ok, item}
          any when any in [:any, :empty] -> {:ok, :any}
          other -> {:error, {:mismatch, :list, other}}
        end
      end
    end
  end

  defp each(items, path, fun) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, i}, :ok ->
      case fun.(item, "#{path}.#{i}") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ---------
  # Entities
  # ---------

  # The entities the graph names (its variables, what its trigger takes, its
  # waits and its signals) and those nest, as the group has them.
  defp types(graph, env) do
    entities = Map.get(env, :entities, %{})

    named =
      for(
        {%{"type" => "entity", "entity" => id}, i} <- Enum.with_index(graph["variables"] || []),
        do: {id, "variables.#{i}.entity"}
      ) ++
        for(
          {%{"entity" => id}, i} <- Enum.with_index(graph["nodes"]),
          is_integer(id),
          do: {id, "nodes.#{i}.entity"}
        ) ++
        for(id <- List.wrap(env[:entry_entity]), do: {id, "entry"})

    Enum.reduce_while(named, {:ok, %{}}, fn {id, path}, {:ok, types} ->
      case nested(to_string(id), entities, types) do
        {:ok, types} -> {:cont, {:ok, types}}
        :error -> {:halt, {:error, {path, :unknown_entity}}}
      end
    end)
  end

  defp nested(id, _entities, types) when is_map_key(types, id), do: {:ok, types}

  defp nested(id, entities, types) do
    case Map.fetch(entities, id) do
      {:ok, %{"attributes" => attributes} = entity} ->
        Enum.reduce_while(attributes, {:ok, Map.put(types, id, entity)}, fn
          %{"type" => "entity", "entity" => held}, {:ok, types} ->
            case nested(to_string(held), entities, types) do
              {:ok, types} -> {:cont, {:ok, types}}
              :error -> {:halt, :error}
            end

          _plain, acc ->
            {:cont, acc}
        end)

      _unknown ->
        :error
    end
  end

  # What the trigger hands a run: as given, or worked out from the trigger
  # and the entity it takes.
  defp entry(%{entry: entry}, _types), do: {:ok, entry}

  defp entry(%{trigger: trigger} = env, types) do
    config = Map.get(env, :config) || %{}

    case env[:entry_entity] do
      nil ->
        {:ok, Triggers.entry(trigger, config)}

      id ->
        definition = Map.fetch!(types, to_string(id))

        cond do
          not Triggers.typed?(trigger) -> {:error, {"entry", :invalid}}
          trigger == "manual" and not flat?(definition) -> {:error, {"entry", :not_flat}}
          true -> {:ok, Triggers.entry(trigger, config, definition)}
        end
    end
  end

  # Whether a form can fill the entity in: plain attributes only.
  defp flat?(%{"attributes" => attributes}),
    do: Enum.all?(attributes, &(&1["type"] != "entity" and &1["list"] != true))

  # The entities those who wait for each signal expect it with: the waits
  # of this graph, its own start, and the other processes of the group.
  defp receivers(graph, env) do
    waits =
      for %{"type" => "receiveTask", "signal" => name} = wait <- graph["nodes"],
          do: {name, wait["entity"]}

    start =
      if env[:trigger] == "signal",
        do: [{(env[:config] || %{})["name"], env[:entry_entity]}],
        else: []

    others =
      for {name, expected} <- Map.get(env, :signals, %{}), entity <- expected, do: {name, entity}

    Enum.group_by(waits ++ start ++ others, &elem(&1, 0), &elem(&1, 1))
  end

  # ---------
  # Variables
  # ---------

  # What a variable starts with gives what the variable holds.
  defp variable(%{"initial" => initial} = variable, path, scope) do
    case written(initial, Types.of(variable), scope) do
      :ok -> :ok
      {:error, reason} -> {:error, {path <> ".initial", reason}}
    end
  end

  defp variable(_variable, _path, _scope), do: :ok

  # A text for what is written as one, an expression of the type otherwise.
  defp written(text, type, scope) do
    if Types.textual?(type) do
      template(text, scope)
    else
      with {:ok, tree} <- Expr.parse(text),
           {:ok, given} <- Expr.check(tree, scope) do
        if Types.fits?(given, type, scope.entities),
          do: :ok,
          else: {:error, {:mismatch, type, given}}
      end
    end
  end

  # ---------
  # Steps
  # ---------

  # A step that sets: its target is a variable, or an attribute of one, and
  # its value gives what the target holds.
  defp step(%{"action" => "assign", "target" => target, "value" => value} = step, path, context) do
    scope = context.scope

    with {:ok, tree} <- Expr.parse(target),
         :ok <- variable?(tree, scope),
         {:ok, type} <- Expr.check(tree, scope),
         {:ok, type} <- taken(step["op"], type) do
      case written(value, type, scope) do
        :ok -> :ok
        {:error, reason} -> {:error, {path <> ".value", reason}}
      end
    else
      {:error, reason} -> {:error, {path <> ".target", reason}}
    end
  end

  # A call hands over what the called process takes: the attributes of its
  # entity, or texts for the fields of one that takes no entity.
  defp step(%{"type" => "callActivity", "process" => id, "fields" => fields}, path, context) do
    case context.callable[id] do
      %{attributes: [_ | _] = attributes, types: types} ->
        handed(attributes, fields, types, path <> ".fields", context.scope)

      _takes_fields ->
        texts(
          for({name, text} <- Enum.sort(fields), do: {"fields.#{name}", text}),
          path,
          context.scope
        )
    end
  end

  # A signal goes with the entity those who wait for it expect, and carries
  # its attributes; one with no entity carries texts.
  defp step(%{"action" => "signal", "name" => name, "fields" => fields} = step, path, context) do
    entity = step["entity"]
    expected = Map.get(context.receivers, name, [])

    cond do
      expected != [] and entity not in expected ->
        {:error, {path <> ".entity", :signal_entity}}

      is_nil(entity) ->
        fields
        |> Enum.with_index()
        |> Enum.map(fn {%{"value" => value}, i} -> {"fields.#{i}.value", value} end)
        |> texts(path, context.scope)

      true ->
        attributes = Types.attributes(context.scope.entities, entity) || []
        names = Enum.map(attributes, & &1["name"])

        case Enum.find(fields, &(&1["name"] not in names)) do
          nil ->
            given = Map.new(fields, &{&1["name"], &1["value"]})
            handed(attributes, given, %{}, path <> ".fields", context.scope)

          %{"name" => unknown} ->
            {:error, {path <> ".fields", {:unknown_attribute, unknown}}}
        end
    end
  end

  defp step(step, path, %{scope: scope}), do: texts(own_texts(step), path, scope)

  # What the value of a step that sets must give: what the target holds,
  # or an item of it for a step that adds to a list.
  defp taken("append", {:list, item}), do: {:ok, item}
  defp taken("append", any) when any in [:any, :empty], do: {:ok, :any}
  defp taken("append", other), do: {:error, {:mismatch, :list, other}}
  defp taken(_set, type), do: {:ok, type}

  # The texts of a step that may hold expressions, each with where it stands.
  defp own_texts(%{"action" => "message", "text" => text}), do: [{"text", text}]
  defp own_texts(%{"action" => "subgroup", "name" => name}), do: [{"name", name}]
  defp own_texts(%{"action" => "push", "text" => text}), do: [{"text", text}]
  defp own_texts(%{"action" => "set", "value" => value}), do: [{"value", value}]
  defp own_texts(_step), do: []

  defp texts(texts, path, scope) do
    Enum.reduce_while(texts, :ok, fn {key, text}, :ok ->
      case template(text, scope) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {"#{path}.#{key}", reason}}}
      end
    end)
  end

  defp template(text, scope) do
    with {:ok, parts} <- Expr.template(text), do: Expr.check_template(parts, scope)
  end

  # What is handed over for an entity: each attribute a value of its type,
  # and every required one a value. `types` are the entities the attributes
  # name, beside those the graph has.
  defp handed(attributes, given, types, path, scope) do
    scope = %{scope | entities: Map.merge(scope.entities, types)}

    Enum.reduce_while(attributes, :ok, fn %{"name" => name} = attribute, :ok ->
      value = given |> Map.get(name, "") |> to_string() |> String.trim()

      result =
        cond do
          value == "" and attribute["required"] == true -> {:error, :required}
          value == "" -> :ok
          true -> written(value, Types.of(attribute), scope)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {"#{path}.#{name}", reason}}}
      end
    end)
  end

  # Only what a run keeps for itself can be set: not what set it going, what
  # a step brought back or a field of the group.
  defp variable?({:name, name}, scope) do
    if name in Map.get(scope, :variables, []), do: :ok, else: {:error, {:not_a_variable, name}}
  end

  defp variable?({:attribute, tree, _name}, scope), do: variable?(tree, scope)
  defp variable?(_tree, _scope), do: {:error, {:not_a_variable, ""}}

  # ---------
  # Flows
  # ---------

  defp flow(%{"condition" => %{"expr" => expression}}, path, scope) do
    with {:ok, tree} <- Expr.parse(expression),
         {:ok, type} <- Expr.check(tree, scope),
         true <- Types.fits?(type, :boolean) || {:error, {:mismatch, :boolean, type}} do
      :ok
    else
      {:error, reason} -> {:error, {path <> ".condition", reason}}
    end
  end

  defp flow(_flow, _path, _scope), do: :ok
end
