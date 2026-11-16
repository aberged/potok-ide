defmodule PotokIde.Processes.Check do
  @moduledoc """
  Checks what a process drawn in Potok says against what it has
  (`PotokIde.Processes.Scope`), when it is saved and as it is drawn: every
  expression in its texts and conditions must name what is there, and give
  what is asked for (`PotokIde.Processes.Expr`). `Graph.normalize/2` has
  checked the drawing's shape before.

  `run/2` takes what the graph cannot know by itself, as `env`:

  - `:entry`: the type of what its trigger hands a run
    (`PotokIde.Processes.Triggers.entry/2`);
  - `:entities`: the entities of its group, by id
    (`PotokIde.Processes.GroupEntities.definitions/1`).

  It returns the graph as it is kept, with that written into it (`entry`,
  and `types`: the entities its variables hold and those nest, as they are
  just now), so a run reads its names with no look elsewhere, and goes on
  reading them so after an entity changed.

  Errors come as `{path, reason}`, as the graph's do, such as
  `{"nodes.3.text", {:unknown_name, "naslov"}}`: the reasons of
  `Expr.parse/1` and `Expr.check/2`, `:unknown_entity` for a variable whose
  entity the group no longer has, and `{:not_a_variable, name}` for a step
  that sets what is no variable.

  A graph without a version says nothing that could be checked
  (`PotokIde.Processes.Legacy`), and comes back as it is.
  """

  alias PotokIde.Processes.{Expr, Scope, Types}

  def run(%{"v" => 2, "nodes" => nodes, "flows" => flows} = graph, %{entry: entry} = env) do
    variables = graph["variables"] || []

    with {:ok, types} <- types(variables, Map.get(env, :entities, %{})) do
      graph = graph |> Map.put("entry", Types.json(entry)) |> Map.put("types", types)
      scope = Scope.scope(graph)

      with :ok <- each(variables, "variables", &variable(&1, &2, scope)),
           :ok <- each(nodes, "nodes", &step(&1, &2, scope)),
           :ok <- each(flows, "flows", &flow(&1, &2, scope)) do
        {:ok, graph}
      end
    end
  end

  def run(graph, _env), do: {:ok, graph}

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

  # The entities the variables hold, and those nest, as the group has them.
  defp types(variables, entities) do
    variables
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{"type" => "entity", "entity" => id}, i}, {:ok, types} ->
        case nested(to_string(id), entities, types) do
          {:ok, types} -> {:cont, {:ok, types}}
          :error -> {:halt, {:error, {"variables.#{i}.entity", :unknown_entity}}}
        end

      _plain, acc ->
        {:cont, acc}
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
        if Types.fits?(given, type), do: :ok, else: {:error, {:mismatch, type, given}}
      end
    end
  end

  # A step that sets: its target is a variable, or an attribute of one, and
  # its value gives what the target holds.
  defp step(%{"action" => "assign", "target" => target, "value" => value}, path, scope) do
    with {:ok, tree} <- Expr.parse(target),
         :ok <- variable?(tree, scope),
         {:ok, type} <- Expr.check(tree, scope) do
      case written(value, type, scope) do
        :ok -> :ok
        {:error, reason} -> {:error, {path <> ".value", reason}}
      end
    else
      {:error, reason} -> {:error, {path <> ".target", reason}}
    end
  end

  defp step(step, path, scope) do
    Enum.reduce_while(texts(step), :ok, fn {key, text}, :ok ->
      case template(text, scope) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {"#{path}.#{key}", reason}}}
      end
    end)
  end

  # The texts of a step that may hold expressions, each with where it stands.
  defp texts(%{"action" => "message", "text" => text}), do: [{"text", text}]
  defp texts(%{"action" => "subgroup", "name" => name}), do: [{"name", name}]
  defp texts(%{"action" => "push", "text" => text}), do: [{"text", text}]
  defp texts(%{"action" => "set", "value" => value}), do: [{"value", value}]

  defp texts(%{"action" => "signal", "fields" => fields}) do
    for {%{"value" => value}, i} <- Enum.with_index(fields), do: {"fields.#{i}.value", value}
  end

  defp texts(%{"type" => "callActivity", "fields" => fields}) do
    for {name, text} <- Enum.sort(fields), do: {"fields.#{name}", text}
  end

  defp texts(_step), do: []

  defp template(text, scope) do
    with {:ok, parts} <- Expr.template(text), do: Expr.check_template(parts, scope)
  end

  # Only what a run keeps for itself can be set: not what set it going, what
  # a step brought back or a field of the group.
  defp variable?({:name, name}, scope) do
    if name in Map.get(scope, :variables, []), do: :ok, else: {:error, {:not_a_variable, name}}
  end

  defp variable?({:attribute, tree, _name}, scope), do: variable?(tree, scope)
  defp variable?(_tree, _scope), do: {:error, {:not_a_variable, ""}}

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
