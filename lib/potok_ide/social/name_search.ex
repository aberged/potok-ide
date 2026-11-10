defmodule PotokIde.Social.NameSearch do
  @moduledoc """
  One search by a group's name for every list that has one (the root's map,
  the sub-groups list and folders, the area menu, sharing into Potok): a part
  of the name, in any case, with or without diacritics, in Latin or Cyrillic.
  "cacak" finds "Čačak", "beograd" finds "Београд", "đurđ" finds "Djurdjevo".

  Both sides go through the database's `potok_fold/1`: the name once, kept in
  `groups.name_folded` by Postgres, and the term in each query. `%` and `_`
  are escaped first, so they mean themselves and not "anything".
  """

  import Ecto.Query, only: [where: 3]

  @max_length 120

  @doc """
  The term a search takes: trimmed, at most #{@max_length} characters, with
  LIKE's own characters escaped; nil when there is nothing to look for.
  """
  def term(text) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, @max_length) do
      "" -> nil
      term -> String.replace(term, ["\\", "%", "_"], &("\\" <> &1))
    end
  end

  def term(_other), do: nil

  @doc """
  SQL that keeps the rows of `table` whose name holds the term in the
  parameter `param` (a `term/1`), such as `sql("g", "$4")`.
  """
  def sql(table, param),
    do: "#{table}.name_folded LIKE '%' || potok_fold(#{param}::text) || '%'"

  @doc "Keeps the groups (the query's first binding) whose name holds `term`."
  def where_matches(query, nil), do: query

  def where_matches(query, term) when is_binary(term),
    do: where(query, [g], fragment("? LIKE '%' || potok_fold(?) || '%'", g.name_folded, ^term))
end
