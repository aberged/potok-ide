defmodule PotokIde.History.Snapshot do
  @moduledoc """
  A group as it was at a moment, for a reader of its history: what things it
  had then and what they were called, what it was itself, and how many records
  its apps kept. What one thing was is `PotokIde.History.State.at/4`.

  Messages are not in it, as no old text of theirs is kept, and neither are
  members, whose history tells of roles and not of who was in.
  """

  alias PotokIde.History.{GroupChange, Reader, State}
  alias PotokIde.Repo
  alias PotokIde.Social.Group

  # The table of each kind of thing, what it goes by, and who may list it.
  @things [
    {"description", "group_alt_descriptions", "name"},
    {"process", "app_processes", "name"},
    {"field", "group_fields", "name"},
    {"entity", "group_entities", "name"},
    {"template", "group_templates", "name"},
    {"poll", "polls", "question"},
    {"event", "group_events", "title"}
  ]

  @limit 200
  @page 30

  @doc "How many records a page has."
  def page_size, do: @page

  @doc """
  The group at `moment`: `%{group, things, records}`. `group` is as
  `State.at/4` gives it, `things` is `[{type, [%{id, name}]}]` with the kinds
  the group had some of, and `records` `[%{alt_id, collection, count}]`.
  """
  def load(%Reader{} = reader, %DateTime{} = moment) do
    %{
      group: State.at(reader, "group", reader.group.id, moment),
      things:
        for({type, _table, _name} <- @things, list = things(reader, type, moment), list != []) do
          {type, list}
        end,
      records: records(reader, moment)
    }
  end

  @doc "The things of a kind the group had at `moment`, by name, those the reader may see."
  def things(%Reader{manage?: false}, type, _moment) when type in ["field", "entity", "template"],
    do: []

  def things(%Reader{} = reader, type, moment) do
    {^type, table, column} = List.keyfind(@things, type, 0)

    reader
    |> list(type, table, column, moment)
    |> Enum.filter(&shown?(reader, type, &1, moment))
  end

  # An alternative description, by its roles of now and of then; a drawing, if
  # it was on then and is on now, unless the reader edits the group.
  defp shown?(%Reader{manage?: true}, _type, _thing, _moment), do: true

  defp shown?(%Reader{} = reader, "description", %{id: id}, moment) do
    Map.has_key?(reader.alts, id) and
      case State.at(reader, "description", id, moment) do
        {:ok, %{"visible_role_keys" => keys}} when is_list(keys) -> Reader.keys?(reader, keys)
        _hidden -> false
      end
  end

  defp shown?(%Reader{} = reader, "process", %{id: id}, moment) do
    match?(%{"active" => true}, State.current("process", id)) and
      match?({:ok, %{"active" => true}}, State.at(reader, "process", id, moment))
  end

  defp shown?(%Reader{}, _type, _thing, _moment), do: true

  # What was there then and has not changed since, and what has: whatever the
  # first change since was, unless it made the thing. Each goes by its name of
  # that time.
  defp list(%Reader{group: %Group{id: group_id}}, type, table, column, moment) do
    drawn = if type == "process", do: "AND t.drawn", else: ""

    %{rows: rows} =
      Repo.query!(
        """
        WITH later AS (
          SELECT c.id, c.subject_id, c.op, c.fields, c.before ->> $3 AS name
          FROM group_changes c
          WHERE c.group_id = $1 AND c.subject_type = $2 AND c.at > $4
        ),
        first AS (
          SELECT DISTINCT ON (subject_id) subject_id, op FROM later ORDER BY subject_id, id
        ),
        named AS (
          SELECT DISTINCT ON (subject_id) subject_id, name FROM later
          WHERE op = 'deleted' OR $3 = ANY (fields)
          ORDER BY subject_id, id
        )
        SELECT x.id, COALESCE(n.name, x.name)
        FROM (
          SELECT t.id, t."#{column}"::text AS name
          FROM "#{table}" t
          WHERE t.group_id = $1 AND t.inserted_at <= $4 #{drawn}
            AND NOT EXISTS (SELECT 1 FROM first f WHERE f.subject_id = t.id)
          UNION ALL
          SELECT f.subject_id, l."#{column}"::text
          FROM first f LEFT JOIN "#{table}" l ON l.id = f.subject_id
          WHERE f.op <> 'created'
        ) x
        LEFT JOIN named n ON n.subject_id = x.id
        ORDER BY lower(COALESCE(n.name, x.name)), x.id
        LIMIT #{@limit}
        """,
        [group_id, type, column, DateTime.to_naive(moment)]
      )

    Enum.map(rows, fn [id, name] -> %{id: id, name: name} end)
  end

  @doc """
  How many records each app of the group kept at `moment` in each collection,
  those the reader reads; of the rest, their own.
  """
  def records(%Reader{} = reader, moment) do
    %{rows: rows} =
      Repo.query!(
        """
        #{at_moment()}
        SELECT r.alt_description_id, r.collection, r.creator_id = $3 AS own, count(*)
        FROM records r
        GROUP BY 1, 2, 3
        """,
        [reader.group.id, DateTime.to_naive(moment), reader.profile_id || 0]
      )

    rows
    |> Enum.filter(fn [alt_id, collection, own?, _n] ->
      Reader.reads_all?(reader, alt_id, collection) or own? == true
    end)
    |> Enum.group_by(fn [alt_id, collection, _own, _n] -> {alt_id, collection} end, &List.last/1)
    |> Enum.map(fn {{alt_id, collection}, counts} ->
      %{alt_id: alt_id, collection: collection, count: Enum.sum(counts)}
    end)
    |> Enum.sort_by(&{&1.alt_id || 0, &1.collection || ""})
  end

  # The records a group had at $2, of whichever description they are filed under.
  defp at_moment do
    """
    WITH first AS (
      SELECT DISTINCT ON (c.subject_id)
        c.subject_id, c.op, c.alt_description_id, c.collection, c.creator_id, c.anonymous
      FROM group_changes c
      WHERE c.group_id = $1 AND c.subject_type = 'record' AND c.at > $2
      ORDER BY c.subject_id, c.id
    ),
    records AS (
      SELECT v.id, v.alt_description_id, v.collection, v.creator_id, v.anonymous
      FROM "values" v
      WHERE v.group_id = $1 AND v.is_data AND v.inserted_at <= $2
        AND v.collection IS DISTINCT FROM 'notify' AND v.collection IS DISTINCT FROM 'files'
        AND NOT EXISTS (SELECT 1 FROM first f WHERE f.subject_id = v.id)
      UNION ALL
      SELECT f.subject_id, f.alt_description_id, f.collection, f.creator_id, f.anonymous
      FROM first f
      WHERE f.op <> 'created'
    )
    """
  end

  @doc """
  The records of a collection at `moment`, the newest first, `page_size/0` of
  them after `before_id`: `{[%{id, values, change}], more?}`. `change` stands
  for the record where `State` asks whose it is.
  """
  def record_page(%Reader{} = reader, alt_id, collection, moment, before_id \\ nil) do
    all? = Reader.reads_all?(reader, alt_id, collection)

    if all? or is_integer(reader.profile_id) do
      %{rows: rows} =
        Repo.query!(
          """
          #{at_moment()}
          SELECT r.id, r.creator_id, r.anonymous
          FROM records r
          WHERE r.alt_description_id IS NOT DISTINCT FROM $3
            AND r.collection IS NOT DISTINCT FROM $4
            AND ($5::bigint IS NULL OR r.id < $5)
            AND ($6 OR r.creator_id = $7)
          ORDER BY r.id DESC
          LIMIT #{@page + 1}
          """,
          [
            reader.group.id,
            DateTime.to_naive(moment),
            alt_id,
            collection,
            before_id,
            all?,
            reader.profile_id || 0
          ]
        )

      {page, rest} = Enum.split(rows, @page)

      records =
        for [id, creator_id, anonymous] <- page,
            {:ok, values} <- [State.at(reader, "record", id, moment)] do
          change = %GroupChange{
            subject_type: "record",
            subject_id: id,
            group_id: reader.group.id,
            alt_description_id: alt_id,
            collection: collection,
            creator_id: creator_id,
            anonymous: anonymous
          }

          %{id: id, values: values, change: change}
        end

      {records, rest != []}
    else
      {[], false}
    end
  end

  @doc """
  What a thing was at `moment` for a reader who may see it, as
  `{:ok, values}`, `:none` or `:hidden`. A record goes by `change`, which says
  whose it is (`record_page/5`); its grades by the app's rules.
  """
  def thing(%Reader{} = reader, type, id, moment) when type != "record" do
    cond do
      type == "group" and id == reader.group.id ->
        State.at(reader, "group", id, moment)

      List.keymember?(@things, type, 0) and
          Enum.any?(things(reader, type, moment), &(&1.id == id)) ->
        State.at(reader, type, id, moment)

      true ->
        :none
    end
  end

  def record(%Reader{} = reader, %GroupChange{} = change, moment) do
    case State.at(reader, "record", change.subject_id, moment) do
      {:ok, values} -> {:ok, State.graded(reader, change, values)}
      other -> other
    end
  end
end
