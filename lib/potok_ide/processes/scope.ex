defmodule PotokIde.Processes.Scope do
  @moduledoc """
  The names a process drawn in Potok may use in its expressions
  (`PotokIde.Processes.Expr`), and the type of what each stands for
  (`PotokIde.Processes.Types`):

  - the id of its start is what set it going (`start.naslov`), of the type
    the graph keeps as `entry`;
  - the id of a decision is what it ended with (`odluka.outcome`, `.by`,
    `.comment`), of a call that waits how the called process ended
    (`poziv.outcome`), and of a wait for a signal what the signal carried
    (`prijem.from`, and its fields);
  - `group` holds the fields of the group (`group.kvarova`).

  A graph is self-contained: with the `entry` and `types` it was saved with
  (`PotokIde.Processes.Check`), its names are known with no look elsewhere,
  so a run reads them the same way long after the drawing changed.
  """

  alias PotokIde.Processes.Types

  # Names a step cannot have as its id.
  @reserved ~w(group and or not true false empty)
  @identifier ~r/^[\p{L}_][\p{L}\p{Nd}_]*$/u

  @doc "The names no step of a process may take as its id."
  def reserved, do: @reserved

  @doc "The types of the names of a graph, by name."
  def names(%{"nodes" => nodes} = graph) do
    entry = Types.of(graph["entry"] || %{})

    nodes
    |> Enum.flat_map(&result(&1, entry))
    |> Map.new()
    |> Map.put("group", {:record, %{}, true})
  end

  @doc "What `Expr.check/2` checks an expression of the graph against."
  def scope(graph), do: %{names: names(graph), entities: graph["types"] || %{}}

  defp result(%{"type" => "startEvent", "id" => id}, entry), do: [{id, entry}]

  defp result(%{"type" => "userTask", "id" => id}, _entry),
    do: [{id, {:record, %{"outcome" => :text, "comment" => :text, "by" => :text}, false}}]

  defp result(%{"type" => "callActivity", "wait" => false}, _entry), do: []

  # A call brings back how it ended, and may bring more.
  defp result(%{"type" => "callActivity", "id" => id}, _entry),
    do: [{id, {:record, %{"outcome" => :text}, true}}]

  defp result(%{"type" => "receiveTask", "id" => id}, _entry),
    do: [{id, {:record, %{"from" => :text, "signal" => :text}, true}}]

  defp result(_step, _entry), do: []

  @doc """
  The values of a run, as it keeps them by name, as a step works on them:
  each read by the type of its name (`Types.load/3`).
  """
  def load(values, graph) when is_map(values) do
    types = names(graph)
    entities = graph["types"] || %{}

    Map.new(values, fn {name, value} ->
      {name, Types.load(value, Map.get(types, name, :any), entities)}
    end)
  end

  @doc """
  How an expression names `field` of `name`: `start.naslov`, or
  `group["broj-kvarova"]` for a field whose name is no plain word.
  """
  def path(name, field) do
    if Regex.match?(@identifier, field),
      do: "#{name}.#{field}",
      else: ~s(#{name}["#{String.replace(field, ["\\", "\""], &("\\" <> &1))}"])
  end
end
