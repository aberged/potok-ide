defmodule PotokIde.History.Feed do
  @moduledoc """
  The history of a group as its page tells it, the newest first, a page at a
  time: the changes of what the group keeps (`PotokIde.History`) and those of
  who may do what in it (`PotokIde.Social.AccessHistory`), each by its own
  rules of reading (`PotokIde.History.Reader`).

  An entry is `%{id, source, at, row}`: `source` is `:change` or `:access` and
  `row` what it is of. Names of what rows speak of come apart, read for a page
  at once (`names/2`). What a thing was is not read here, as a description may
  be 300 KB: `PotokIde.History.State` reads it for one change.
  """

  import Ecto.Query

  alias PotokIde.Events.Event
  alias PotokIde.History.{GroupChange, Reader}
  alias PotokIde.Polls.Poll
  alias PotokIde.Processes.{GroupEntity, GroupField, ValueProcess}
  alias PotokIde.Repo

  alias PotokIde.Social.{
    AccessHistory,
    AppProcess,
    Group,
    GroupAltDescription,
    GroupTemplate,
    Profile,
    Value,
    Visibility
  }

  @page 30

  @types %{
    all: ~w(group sub_group shortcut description template app record process entity field message
         poll event notice),
    group: ~w(group sub_group shortcut description template app),
    records: ~w(record),
    processes: ~w(process entity field),
    talk: ~w(message reaction group_reaction poll event notice)
  }

  # Told by the access history, with who may do what, so not told twice.
  @access_settings ~w(is_public has_public_chat description_for_guests inherits_members
                      inherit_role_keys elects_admins join_mode join_poll published_at)
  @access_of_description ~w(visible_role_keys for_guests)

  @filters [:all, :group, :records, :processes, :talk, :access]

  @doc "What the history can be narrowed to."
  def filters, do: @filters

  @doc "How many entries a page has."
  def page_size, do: @page

  @doc """
  A page for `reader`: `%{entries, cursor}`, `cursor` nil at the end.

  Options: `:filter` (`filters/0`), `:actor` (a profile's id), `:until` (a
  `DateTime`, what came after it left out), `:subject` (`{type, id}`, one
  thing's history), `:cursor` (from the page before) and `:limit`.
  """
  def page(%Reader{} = reader, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page)
    cursor = opts[:cursor] || %{change: nil, access: nil}

    changes = changes(reader, opts, cursor.change, limit + 1)
    access = access(reader, opts, cursor.access, limit + 1)

    all = Enum.sort_by(changes ++ access, & &1.at, {:desc, DateTime})
    {entries, rest} = Enum.split(all, limit)

    cursor =
      if rest != [] do
        %{
          change: last(entries, :change, & &1.row.id, cursor.change),
          access: last(entries, :access, &{&1.row.inserted_at, &1.row.id}, cursor.access)
        }
      end

    %{entries: entries, cursor: cursor}
  end

  defp last(entries, source, key, before) do
    case entries |> Enum.filter(&(&1.source == source)) |> List.last() do
      nil -> before
      entry -> key.(entry)
    end
  end

  defp changes(%Reader{} = reader, opts, before, limit) do
    case Keyword.get(opts, :filter, :all) do
      :access ->
        []

      filter ->
        GroupChange
        |> where([c], c.group_id in ^group_ids(reader, filter, opts[:subject]))
        |> of_type(filter, opts[:subject])
        |> Reader.visible(reader)
        |> listed(reader, opts[:subject])
        |> by_actor(opts[:actor])
        |> until(opts[:until])
        |> before_id(before)
        |> order_by([c], desc: c.id)
        |> limit(^limit)
        |> join(:left, [c], a in assoc(c, :actor), as: :actor)
        |> join(:left, [c], o in assoc(c, :creator), as: :creator)
        |> preload([actor: a, creator: o], actor: a, creator: o)
        |> told()
        |> Repo.all()
        |> Enum.map(&%{id: "change-#{&1.id}", source: :change, at: &1.at, row: &1})
    end
  end

  # Whether a change of a poll's end was its end or a new beginning, and where
  # a moved sub-group went or came from.
  defp told(query) do
    select_merge(query, [c], %{
      closing?:
        fragment(
          "CASE WHEN ? = 'poll' AND 'closed_at' = ANY(?) THEN ? ->> 'closed_at' IS NULL END",
          c.subject_type,
          c.fields,
          c.before
        ),
      moved:
        fragment(
          "CASE WHEN ? = 'sub_group' AND ? = 'changed' THEN ? - 'name' END",
          c.subject_type,
          c.op,
          c.before
        )
    })
  end

  # What was said in a thread is the group's talk too, for its members, who
  # may open any of its threads.
  defp group_ids(%Reader{group: %Group{id: id}}, :talk, nil) do
    threads =
      from(g in Group, where: g.parent_id == ^id and not is_nil(g.parent_value_id), select: g.id)

    [id | Repo.all(threads)]
  end

  defp group_ids(%Reader{group: %Group{id: id}}, _filter, _subject), do: [id]

  defp of_type(query, _filter, {type, id}),
    do: where(query, [c], c.subject_type == ^type and c.subject_id == ^id)

  defp of_type(query, :all, nil) do
    query
    |> where([c], c.subject_type in ^@types.all)
    |> where(
      [c],
      not (c.subject_type == "group" and fragment("? <@ ?", c.fields, ^@access_settings))
    )
    |> where(
      [c],
      not (c.subject_type == "description" and c.op == :changed and
             fragment("? <@ ?", c.fields, ^@access_of_description))
    )
  end

  defp of_type(query, filter, nil), do: where(query, [c], c.subject_type in ^@types[filter])

  # Of a collection deleted at once one row stands for all; the author of one
  # of them who does not read the rest sees their own.
  defp listed(query, _reader, {_type, _id}), do: query

  defp listed(query, %Reader{manage?: false, profile_id: id}, nil) when is_integer(id),
    do:
      where(
        query,
        [c],
        c.listed or (c.subject_type == "record" and c.op == :deleted and c.creator_id == ^id)
      )

  defp listed(query, _reader, nil), do: where(query, [c], c.listed)

  defp by_actor(query, nil), do: query
  defp by_actor(query, id), do: where(query, [c], c.actor_id == ^id)

  defp until(query, nil), do: query
  defp until(query, %DateTime{} = at), do: where(query, [c], c.at <= ^at)

  defp before_id(query, nil), do: query
  defp before_id(query, id), do: where(query, [c], c.id < ^id)

  defp access(%Reader{} = reader, opts, before, limit) do
    if is_nil(opts[:subject]) and Keyword.get(opts, :filter, :all) in [:all, :access] do
      reader.group
      |> AccessHistory.list(reader.access,
        before: before,
        limit: limit,
        actor: opts[:actor],
        until: opts[:until]
      )
      |> Enum.map(
        &%{
          id: "access-#{&1.id}",
          source: :access,
          at: %{&1.inserted_at | microsecond: {0, 6}},
          row: &1
        }
      )
    else
      []
    end
  end

  @doc "One change the reader may see, with what it was before, or nil."
  def get(%Reader{} = reader, id) when is_integer(id) do
    GroupChange
    |> where([c], c.id == ^id and c.group_id in ^group_ids(reader, :talk, nil))
    |> Reader.visible(reader)
    |> join(:left, [c], a in assoc(c, :actor), as: :actor)
    |> join(:left, [c], p in assoc(c, :purged_by), as: :purged_by)
    |> join(:left, [c], o in assoc(c, :creator), as: :creator)
    |> preload([actor: a, purged_by: p, creator: o], actor: a, purged_by: p, creator: o)
    |> told()
    |> select_merge([c], %{before: c.before})
    |> Repo.one()
  end

  # ---------
  # Names
  # ---------

  @doc """
  What the things the entries speak of are called, as `%{{type, id} => name}`:
  by their name now, and a deleted thing's by what it was called then. Also
  the polls and process runs that caused a change (`{"run", id}`), and which
  messages are still there (`{"message", id} => true`).
  """
  def names(%Reader{} = reader, entries) do
    rows = for %{source: :change, row: row} <- entries, do: row
    by_type = Enum.group_by(rows, & &1.subject_type, & &1.subject_id)

    polls = Enum.uniq(Map.get(by_type, "poll", []) ++ causes(rows, "poll"))

    live =
      [
        named("description", GroupAltDescription, by_type, :name),
        named("template", GroupTemplate, by_type, :name),
        named("process", AppProcess, by_type, :name),
        named("entity", GroupEntity, by_type, :name),
        named("field", GroupField, by_type, :name),
        named("event", Event, by_type, :title),
        named("poll", Poll, %{"poll" => polls}, :question),
        groups(reader, Map.get(by_type, "sub_group", []) ++ Map.get(by_type, "shortcut", [])),
        moved(reader, rows),
        runs(causes(rows, "process")),
        messages(Map.get(by_type, "message", []) ++ Map.get(by_type, "reaction", []))
      ]
      |> Enum.reduce(%{}, &Map.merge/2)

    Map.merge(gone(reader, rows, live), live)
  end

  defp causes(rows, key),
    do: for(%{cause: %{^key => id}} when is_integer(id) <- rows, uniq: true, do: id)

  defp named(type, schema, by_type, column) do
    case Enum.uniq(Map.get(by_type, type, [])) do
      [] ->
        %{}

      ids ->
        from(r in schema, where: r.id in ^ids, select: {r.id, field(r, ^column)})
        |> Repo.all()
        |> Map.new(fn {id, name} -> {{type, id}, name} end)
    end
  end

  # Rows were let through for those the reader sees, so their names are too.
  defp groups(_reader, []), do: %{}

  defp groups(_reader, ids) do
    from(g in Group, where: g.id in ^Enum.uniq(ids), select: {g.id, g.name})
    |> Repo.all()
    |> Enum.flat_map(fn {id, name} -> [{{"sub_group", id}, name}, {{"shortcut", id}, name}] end)
    |> Map.new()
  end

  # Where a sub-group went or came from (`history_sub_group_moved`): the other
  # group's name, only for a reader who sees it, as `{"moved", id}`.
  defp moved(%Reader{viewer: %Profile{} = viewer}, rows) do
    ids =
      for %{subject_type: "sub_group", op: :changed, moved: moved} <- rows,
          is_map(moved),
          id <- [moved["to"], moved["from"]],
          is_integer(id),
          uniq: true,
          do: id

    if ids == [] do
      %{}
    else
      from([group: g] in Visibility.plain_groups(viewer),
        where: g.id in ^ids,
        select: {g.id, g.name}
      )
      |> Repo.all()
      |> Map.new(fn {id, name} -> {{"moved", id}, name} end)
    end
  end

  defp moved(%Reader{}, _rows), do: %{}

  defp runs([]), do: %{}

  defp runs(ids) do
    from(i in ValueProcess,
      join: p in AppProcess,
      on: p.id == i.app_process_id,
      where: i.id in ^ids,
      select: {i.id, p.name}
    )
    |> Repo.all()
    |> Map.new(fn {id, name} -> {{"run", id}, name} end)
  end

  defp messages([]), do: %{}

  defp messages(ids) do
    from(v in Value, where: v.id in ^Enum.uniq(ids), select: v.id)
    |> Repo.all()
    |> Map.new(&{{"message", &1}, true})
  end

  # Of what is no more, the name it went by when it was deleted.
  defp gone(%Reader{group: group}, rows, live) do
    ids =
      for %{subject_type: type, subject_id: id} <- rows,
          type in ~w(description template process entity field event poll sub_group),
          not Map.has_key?(live, {type, id}),
          uniq: true,
          do: id

    if ids == [] do
      %{}
    else
      from(c in GroupChange,
        where:
          c.group_id == ^group.id and c.op == :deleted and c.subject_id in ^ids and
            c.subject_type in ~w(description template process entity field event poll sub_group),
        select:
          {c.subject_type, c.subject_id,
           fragment(
             "COALESCE(? ->> 'name', ? ->> 'title', ? ->> 'question')",
             c.before,
             c.before,
             c.before
           )}
      )
      |> Repo.all()
      |> Map.new(fn {type, id, name} -> {{type, id}, name} end)
    end
  end
end
