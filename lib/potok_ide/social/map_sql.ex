defmodule PotokIde.Social.MapSql do
  @moduledoc """
  SQL with named parameters, for the root map's queries, whose text changes
  with the filters picked: `$name` marks a parameter, and `bind/2` numbers
  them in the order they first appear, so a statement holds only the
  parameters its text uses and no one counts `$1` to `$18` by hand.
  """

  @marker ~r/\$([a-z][a-z0-9_]*)/

  @doc """
  The SQL with `$name` marks numbered, and the values in that order:
  `{sql, params}`. Every name needs a value in `values` (atom keys).

      iex> PotokIde.Social.MapSql.bind("SELECT $a, $b, $a", %{a: 1, b: 2})
      {"SELECT $1, $2, $1", [1, 2]}
  """
  def bind(sql, values) when is_binary(sql) and is_map(values) do
    names =
      @marker
      |> Regex.scan(sql, capture: :all_but_first)
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    numbers = names |> Enum.with_index(1) |> Map.new()
    values = Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end)

    numbered =
      Regex.replace(@marker, sql, fn _whole, name -> "$#{Map.fetch!(numbers, name)}" end)

    params =
      Enum.map(names, fn name ->
        case Map.fetch(values, name) do
          {:ok, value} -> value
          :error -> raise ArgumentError, "no value for $#{name}"
        end
      end)

    {numbered, params}
  end
end
