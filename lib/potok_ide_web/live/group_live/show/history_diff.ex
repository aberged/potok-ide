defmodule PotokIdeWeb.GroupLive.Show.HistoryDiff do
  @moduledoc """
  What differs between two versions, for a page to show: a text line by line,
  a record path by path, a drawing step by step. Each gives up, and says so,
  on what is too much to read anyway, such as an app of 300 KB.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  @context 2
  @max_bytes 60_000
  @max_lines 600
  @max_paths 120

  @doc """
  Two texts line by line: `[{:same | :removed | :added, line} | :gap]`, with a
  few unchanged lines around each change, or `:too_long`.
  """
  def lines(before, after_text) do
    before = before || ""
    after_text = after_text || ""

    with true <- byte_size(before) <= @max_bytes and byte_size(after_text) <= @max_bytes,
         old = split(before),
         new = split(after_text),
         true <- length(old) <= @max_lines and length(new) <= @max_lines do
      old
      |> List.myers_difference(new)
      |> Enum.flat_map(fn
        {:eq, lines} -> [{:same, lines}]
        {:del, lines} -> [{:removed, lines}]
        {:ins, lines} -> [{:added, lines}]
      end)
      |> folded()
    else
      false -> :too_long
    end
  end

  # HTML is often one line; a block on each line reads better, and differs better.
  defp split(text) do
    text
    |> String.replace(
      ~r/(<\/(?:p|div|li|ul|ol|h[1-6]|section|article|tr|table|style|script)>)(?=.)/i,
      "\\1\n"
    )
    |> String.split("\n")
  end

  defp folded(parts) do
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:same, lines}, index} -> fold_same(lines, index == 0, index == last)
      {{kind, lines}, _index} -> Enum.map(lines, &{kind, &1})
    end)
  end

  defp fold_same(lines, first?, last?) do
    head = if first?, do: 0, else: @context
    tail = if last?, do: 0, else: @context

    if length(lines) <= head + tail + 1 do
      Enum.map(lines, &{:same, &1})
    else
      Enum.map(Enum.take(lines, head), &{:same, &1}) ++
        [:gap] ++ Enum.map(Enum.take(lines, -tail), &{:same, &1})
    end
  end

  @doc """
  Two JSON values as the paths that differ: `[{path, before, after}]`, `nil`
  for a side that has no such path, and whether some were left out.
  """
  def paths(before, after_value) do
    old = flat(before)
    new = flat(after_value)

    differing =
      (Map.keys(old) ++ Map.keys(new))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
      |> Enum.sort()

    {Enum.take(differing, @max_paths)
     |> Enum.map(&{Enum.join(&1, " › "), Map.get(old, &1), Map.get(new, &1)}),
     length(differing) > @max_paths}
  end

  defp flat(value, path \\ [])

  defp flat(%{} = map, path) when map_size(map) > 0 do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.merge(acc, flat(value, path ++ [to_string(key)]))
    end)
  end

  defp flat([_ | _] = list, path) do
    if Enum.all?(list, &(is_binary(&1) or is_number(&1))) do
      %{path => Enum.join(list, ", ")}
    else
      list
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {value, index}, acc ->
        Map.merge(acc, flat(value, path ++ [item(value, index)]))
      end)
    end
  end

  defp flat(nil, []), do: %{}
  defp flat(value, _path) when value in [nil, %{}, []], do: %{}
  defp flat(value, path) when is_binary(value), do: %{path => value}
  defp flat(true, path), do: %{path => gettext("yes")}
  defp flat(false, path), do: %{path => gettext("no")}
  defp flat(value, path), do: %{path => to_string(value)}

  # A thing with a name goes by it, so one put before it does not move the rest.
  defp item(%{"name" => name}, _index) when is_binary(name) and name != "", do: name
  defp item(_value, index), do: to_string(index)

  @doc """
  Two drawings of a process by their steps: `[{:added | :removed | :changed,
  label}]`, and whether what connects them changed.
  """
  def steps(before, after_graph) do
    old = nodes(before)
    new = nodes(after_graph)

    steps =
      for(
        {id, node} <- old,
        not Map.has_key?(new, id),
        do: {:removed, label(node)}
      ) ++
        for({id, node} <- new, not Map.has_key?(old, id), do: {:added, label(node)}) ++
        for({id, node} <- new, old[id] && old[id] != node, do: {:changed, label(node)})

    {Enum.sort(steps), flows(before) != flows(after_graph)}
  end

  defp nodes(%{"nodes" => nodes}) when is_list(nodes), do: Map.new(nodes, &{&1["id"], &1})
  defp nodes(_graph), do: %{}

  defp flows(%{"flows" => flows}) when is_list(flows), do: Enum.sort(flows)
  defp flows(_graph), do: []

  defp label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp label(node), do: node["id"] || ""
end
