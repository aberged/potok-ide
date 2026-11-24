defmodule PotokIde.History.State do
  @moduledoc """
  What a thing of a group was, worked out from what it is and what its changes
  kept (`PotokIde.History.GroupChange`).

  A change keeps the values from before it, so what a thing was at a moment is
  what it is now with the changes since taken back, the newest first; and what
  a change made of a value is what the next change of that value found.

  Values are as JSON has them, under the names of their columns: a time is a
  text, an area is GeoJSON. Some are not to be had: emptied by someone
  (`:emptied`), or seen then only by others (`:hidden`).
  """

  import Ecto.Query

  alias PotokIde.History.{GroupChange, Reader, Tracked}
  alias PotokIde.Repo
  alias PotokIde.Social.ValueRules

  @tables Map.new(Tracked.tables(), fn {table, spec} -> {spec.type, {table, spec.kept}} end)

  @type value :: {:value, term()} | :none | :emptied | :hidden

  @doc """
  What the fields of `change` were and became, for `reader`, as `[{field,
  before, after}]` in the order of their names. Each side is `{:value, v}`,
  `:none` (there was no such thing), `:emptied` or `:hidden`.
  """
  def sides(%Reader{} = reader, %GroupChange{} = change) do
    fields =
      case change.op do
        :changed -> change.fields
        :deleted -> shown_of_deleted(change)
        :created -> Tracked.kept(change.subject_type)
      end

    for field <- Enum.sort(fields) do
      {field, before(reader, change, field), later(reader, change, field)}
    end
  end

  # What a deleted thing held, without what only Potok needs to put it back.
  defp shown_of_deleted(%GroupChange{subject_type: "record", before: %{"content" => "data:"}}),
    do: ["data", "managed"]

  defp shown_of_deleted(%GroupChange{subject_type: "record"}), do: ["content", "data", "managed"]

  defp shown_of_deleted(%GroupChange{subject_type: type, before: before}) do
    extra = if is_map(before) and Map.has_key?(before, "options"), do: ["options"], else: []
    Tracked.kept(type) ++ extra
  end

  defp before(_reader, %GroupChange{op: :created}, _field), do: :none

  defp before(reader, change, field) do
    cond do
      not Reader.side?(reader, change, :before) -> :hidden
      change.purged_at -> :emptied
      true -> change.before |> found(field) |> shown(reader, change, field)
    end
  end

  # Marked and never kept, as a group's picture or the secret part of a config.
  defp found(before, field) do
    case before do
      %{^field => value} -> {:value, value}
      _none -> :none
    end
  end

  defp later(_reader, %GroupChange{op: :deleted}, _field), do: :none

  defp later(reader, change, field) do
    cond do
      not Reader.side?(reader, change, :after) ->
        :hidden

      next = next_change(change, field) ->
        cond do
          not Reader.side?(reader, next, :before) -> :hidden
          next.purged_at -> :emptied
          true -> next.before |> found(field) |> shown(reader, change, field)
        end

      true ->
        change.subject_type
        |> current(change.subject_id)
        |> found(field)
        |> shown(reader, change, field)
    end
  end

  # The next change that found the value `change` left: the next one of it,
  # or the deletion of the thing.
  defp next_change(change, field) do
    from(c in GroupChange,
      where:
        c.subject_type == ^change.subject_type and c.subject_id == ^change.subject_id and
          c.id > ^change.id and
          (c.op == :deleted or fragment("? = ANY(?)", ^field, c.fields)),
      order_by: [asc: c.id],
      limit: 1,
      select_merge: %{before: c.before}
    )
    |> Repo.one()
  end

  # A record's grades go by the app's rules: to those who read all of its
  # collection, and to the author as far as they were released.
  defp shown({:value, value}, reader, %GroupChange{subject_type: "record"} = change, "managed") do
    rule = Reader.rule(reader, change.alt_description_id, change.collection)

    row = %{
      creator_id: change.creator_id,
      creator_username: nil,
      anonymous: change.anonymous,
      managed: value
    }

    case ValueRules.present(row, rule, reader.profile_id, reader.access) do
      %{managed: nil} when not is_nil(value) -> :hidden
      %{managed: managed} -> {:value, managed}
    end
  end

  defp shown(value, _reader, _change, _field), do: value

  @doc """
  What the thing is now, as its changes keep it, or nil when it is gone. The
  secret part of an app's config is never in it.
  """
  def current(type, id) do
    with {table, kept} <- @tables[type],
         columns = Enum.map_join(kept, ", ", &~s(t."#{&1}")),
         %{rows: [[row]]} <-
           Repo.query!(
             """
             SELECT to_jsonb(r) FROM (SELECT #{columns} FROM "#{table}" t WHERE t.id = $1) r
             """,
             [id]
           ) do
      current_of(type, id, row)
    else
      _none -> nil
    end
  end

  defp current_of("record", _id, %{"data" => %{"secret" => _} = data} = row),
    do: %{row | "data" => Map.delete(data, "secret")}

  defp current_of("poll", id, row) do
    %{rows: rows} =
      Repo.query!(
        "SELECT text, profile_id FROM poll_options WHERE poll_id = $1 ORDER BY position, id",
        [id]
      )

    options =
      Enum.map(rows, fn
        [text, nil] -> %{"text" => text}
        [_text, profile_id] -> %{"profile_id" => profile_id}
      end)

    Map.put(row, "options", options)
  end

  defp current_of(_type, _id, row), do: row

  @doc """
  What the thing was at `moment`, for `reader`: `{:ok, values}`, or `:none`
  when it was not there then. A value emptied since is `:emptied`, and one the
  reader may not see `:hidden`.
  """
  def at(%Reader{} = reader, type, id, %DateTime{} = moment) do
    from(c in GroupChange,
      where: c.subject_type == ^type and c.subject_id == ^id and c.at > ^moment,
      order_by: [desc: c.id],
      select_merge: %{before: c.before}
    )
    |> Repo.all()
    |> Enum.reduce(current(type, id), &take_back(&1, &2, Reader.side?(reader, &1, :before)))
    |> case do
      nil -> :none
      values -> {:ok, values}
    end
  end

  # `seen?` is whether the reader may see what the thing was before the change.
  defp take_back(%GroupChange{op: :created}, _values, _seen?), do: nil

  defp take_back(%GroupChange{op: :deleted} = change, _values, seen?) do
    cond do
      not seen? -> Map.new(Tracked.kept(change.subject_type), &{&1, :hidden})
      change.purged_at -> Map.new(Tracked.kept(change.subject_type), &{&1, :emptied})
      true -> change.before || %{}
    end
  end

  # Changes of a thing that is gone with no word of it (a row Potok dropped).
  defp take_back(%GroupChange{op: :changed}, nil, _seen?), do: nil

  defp take_back(%GroupChange{op: :changed} = change, values, seen?) do
    cond do
      not seen? -> Enum.reduce(change.fields, values, &Map.put(&2, &1, :hidden))
      change.purged_at -> Enum.reduce(change.fields, values, &Map.put(&2, &1, :emptied))
      true -> Map.merge(values, change.before || %{})
    end
  end

  @doc "The values of a record with its grades as the reader may see them (`change` says whose it is)."
  def graded(%Reader{} = reader, %GroupChange{subject_type: "record"} = change, %{} = values) do
    case Map.fetch(values, "managed") do
      {:ok, managed} when is_map(managed) ->
        case shown({:value, managed}, reader, change, "managed") do
          {:value, shown} -> %{values | "managed" => shown}
          :hidden -> Map.delete(values, "managed")
        end

      _none ->
        values
    end
  end
end
