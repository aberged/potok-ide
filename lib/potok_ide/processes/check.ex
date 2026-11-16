defmodule PotokIde.Processes.Check do
  @moduledoc """
  Checks what a process drawn in Potok says against what it has
  (`PotokIde.Processes.Scope`), when it is saved and as it is drawn: every
  expression in its texts and conditions must name what is there, and give
  what is asked for (`PotokIde.Processes.Expr`). `Graph.normalize/2` has
  checked the drawing's shape before.

  `run/2` takes what the graph cannot know by itself, as `env`:

  - `:entry`: the type of what its trigger hands a run
    (`PotokIde.Processes.Triggers.entry/2`).

  It returns the graph as it is kept, with that written into it (`entry`,
  and `types`, the entities its types name), so a run reads its names with
  no look elsewhere. Errors come as `{path, reason}`, as the graph's do,
  such as `{"nodes.3.text", {:unknown_name, "naslov"}}` (the reasons of
  `Expr.parse/1` and `Expr.check/2`).

  A graph without a version says nothing that could be checked
  (`PotokIde.Processes.Legacy`), and comes back as it is.
  """

  alias PotokIde.Processes.{Expr, Scope, Types}

  def run(%{"v" => 2, "nodes" => nodes, "flows" => flows} = graph, %{entry: entry}) do
    graph = graph |> Map.put("entry", Types.json(entry)) |> Map.put("types", %{})
    scope = Scope.scope(graph)

    with :ok <- each(nodes, "nodes", &step(&1, &2, scope)),
         :ok <- each(flows, "flows", &flow(&1, &2, scope)) do
      {:ok, graph}
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
