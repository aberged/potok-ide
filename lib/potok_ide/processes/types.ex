defmodule PotokIde.Processes.Types do
  @moduledoc """
  The types of what the processes drawn in a group work with: what an
  attribute of an entity (`PotokIde.Processes.GroupEntity`) may hold.

  - `text`, `number`, `boolean`, `date` and `datetime` hold one plain value.
  - `choice` holds one of the `options` the attribute lists.
  - `entity` holds another entity of the same group, by its id.

  Any of them may be a list. Entities nest at most #{4} deep and never in a
  circle, so a value of one always has an end.

  Names of attributes are written in the texts and conditions of a process,
  so they are plain: a letter or `_`, then letters, digits and `_`, up to 40,
  and none of the words a process keeps for itself (`reserved/0`).
  """

  @kinds ~w(text number boolean date datetime choice entity)
  @name_format ~r/^[\p{L}_][\p{L}\p{Nd}_]{0,39}$/u
  # What a run always gets beside its fields, and the words of a condition.
  @reserved ~w(from signal outcome author and or not true false empty)
  @max_depth 4

  @doc "Every type an attribute may have, in the order the editor offers them."
  def kinds, do: @kinds

  @doc "The words no attribute may be named."
  def reserved, do: @reserved

  @doc "How deep entities may nest: an entity with plain attributes is 1 deep."
  def max_depth, do: @max_depth

  @doc "Whether `name` may name an attribute."
  def name?(name) when is_binary(name),
    do: Regex.match?(@name_format, name) and name not in @reserved

  def name?(_name), do: false

  @doc """
  Checks how the entities of a group nest, given the entities each holds as
  `%{id => [id]}`: `:ok`, `{:error, :cycle}` when one comes back to itself,
  or `{:error, :too_deep}` past #{@max_depth} levels. An id the map does not
  know holds nothing.
  """
  def nesting(holds) when is_map(holds) do
    Enum.reduce_while(Map.keys(holds), :ok, fn id, :ok ->
      case depth(holds, id, []) do
        :cycle -> {:halt, {:error, :cycle}}
        depth when depth > @max_depth -> {:halt, {:error, :too_deep}}
        _depth -> {:cont, :ok}
      end
    end)
  end

  defp depth(holds, id, path) do
    if id in path do
      :cycle
    else
      holds
      |> Map.get(id, [])
      |> Enum.reduce_while(0, fn held, deepest ->
        case depth(holds, held, [id | path]) do
          :cycle -> {:halt, :cycle}
          depth -> {:cont, max(deepest, depth)}
        end
      end)
      |> case do
        :cycle -> :cycle
        deepest -> deepest + 1
      end
    end
  end
end
