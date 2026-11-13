defmodule PotokIde.CountMark do
  @window 100

  @moduledoc """
  What a count already holds, so that a page can add later rows to it one by
  one, from their broadcasts, instead of counting again.

  A count reads the newest ids of the table it counts in the same statement,
  and so in the same snapshot. Ids are handed out before a row's transaction
  commits, so a row with a lower id than the newest can still be on its way:
  a later row committed first, and this one's broadcast comes after the
  count. Such an id is missing from what the count saw, and the mark keeps
  the missing ids among the newest #{@window}: a broadcast of one of them is new
  to the count.

  Most missing ids are rows deleted or never committed. No broadcast comes for
  them, so keeping them changes nothing.
  """

  @typedoc "The newest id the count saw, and the ids below it that it did not see."
  @type t :: {newest :: non_neg_integer(), unseen :: [pos_integer()]}

  @doc """
  SQL for the ids of `table` (a name written in code, never input) among the
  newest #{@window}, as an array for `from_ids/1`. It goes into the count's own
  statement, so that both read one snapshot.
  """
  def ids_sql(table) when is_binary(table) do
    "(SELECT COALESCE(array_agg(id ORDER BY id), '{}') FROM #{table} " <>
      "WHERE id > (SELECT COALESCE(MAX(id), 0) FROM #{table}) - #{@window})"
  end

  @doc "The mark of what `ids_sql/1` read. Nil (no count) stays nil."
  @spec from_ids([pos_integer()] | nil) :: t() | nil
  def from_ids(nil), do: nil
  def from_ids([]), do: {0, []}

  def from_ids(ids) when is_list(ids) do
    newest = List.last(ids)
    seen = MapSet.new(ids)
    unseen = for id <- max(newest - @window + 1, 1)..newest//1, id not in seen, do: id
    {newest, unseen}
  end

  @doc "Whether a count with this mark already holds the row with `id`."
  @spec counted?(t(), integer()) :: boolean()
  def counted?({newest, unseen}, id) when is_integer(id), do: id <= newest and id not in unseen
end
