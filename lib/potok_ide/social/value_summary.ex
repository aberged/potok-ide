defmodule PotokIde.Social.ValueSummary do
  @moduledoc """
  Counts over the answers of one collection of an app, made in the database so
  that a summary of a hundred thousand responses costs one query, not a
  hundred thousand rows sent to a browser.

  The answers are the map at `under` in each value's data, and only the
  `keys` asked for are counted. Each answer is split by its JSON type:

  - a string, number or boolean is one bucket: one choice;
  - a list gives a bucket for each element: checkboxes;
  - a map gives buckets per entry, keyed by row: a grid, whose cells are again
    one value or a list.

  Each bucket counts values, not answers, so a value that repeats an element
  counts once. Each key and row keeps its 50 biggest buckets, and the rest
  is summed as `other`. A query runs for at most five seconds.
  """

  alias PotokIde.Repo

  @max_buckets 50
  @timeout_ms 5_000

  @doc """
  `%{total: n, keys: %{key => %{answered: n, rows: %{row_or_nil => %{answered: n,
  buckets: [{bucket, count}], other: n}}}}}`, and with `score: true` also
  `score:` (`score_stats/3`).
  """
  def summarize(group_id, alt_id, collection, under, keys, opts \\ []) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = #{@timeout_ms}")

      %{
        total: total(group_id, alt_id, collection),
        keys: if(keys == [], do: %{}, else: buckets(group_id, alt_id, collection, under, keys)),
        score: if(Keyword.get(opts, :score, false), do: score_stats(group_id, alt_id, collection))
      }
    end)
  end

  defp condition(nil),
    do: "v.group_id = $1 AND v.is_data AND v.collection = $2 AND v.alt_description_id IS NULL"

  defp condition(_alt_id),
    do: "v.group_id = $1 AND v.is_data AND v.collection = $2 AND v.alt_description_id = $3"

  defp base_params(group_id, nil, collection), do: [group_id, collection]
  defp base_params(group_id, alt_id, collection), do: [group_id, collection, alt_id]

  defp total(group_id, alt_id, collection) do
    %{rows: [[count]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "values" v WHERE #{condition(alt_id)}|,
        base_params(group_id, alt_id, collection)
      )

    count
  end

  defp buckets(group_id, alt_id, collection, under, keys) do
    params = base_params(group_id, alt_id, collection)
    under_param = "$#{length(params) + 1}::text[]"
    keys_param = "$#{length(params) + 2}::text[]"

    sql = """
    WITH cells AS MATERIALIZED (
      SELECT v.id, k.key, r.row_key, b.bucket
      FROM "values" v
      CROSS JOIN LATERAL jsonb_each(
        CASE WHEN jsonb_typeof(v.data #> #{under_param}) = 'object'
             THEN v.data #> #{under_param} ELSE '{}'::jsonb END
      ) AS k(key, val)
      CROSS JOIN LATERAL (
        SELECT NULL::text, k.val WHERE jsonb_typeof(k.val) <> 'object'
        UNION ALL
        SELECT e.key, e.value
        FROM jsonb_each(CASE WHEN jsonb_typeof(k.val) = 'object' THEN k.val ELSE '{}'::jsonb END) AS e
      ) AS r(row_key, cell)
      CROSS JOIN LATERAL (
        SELECT r.cell #>> '{}'
        WHERE jsonb_typeof(r.cell) IN ('string', 'number', 'boolean')
        UNION ALL
        SELECT x #>> '{}'
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r.cell) = 'array' THEN r.cell ELSE '[]'::jsonb END) AS x
        WHERE jsonb_typeof(x) IN ('string', 'number', 'boolean')
      ) AS b(bucket)
      WHERE #{condition(alt_id)} AND k.key = ANY(#{keys_param}) AND b.bucket <> ''
    ),
    counted AS (
      SELECT key, row_key, bucket, count(DISTINCT id) AS n FROM cells GROUP BY key, row_key, bucket
    ),
    ranked AS (
      SELECT key, row_key, bucket, n,
             row_number() OVER (PARTITION BY key, row_key ORDER BY n DESC, bucket) AS rn
      FROM counted
    )
    SELECT 'b', key, row_key, bucket, n::bigint FROM ranked WHERE rn <= #{@max_buckets}
    UNION ALL
    SELECT 'o', key, row_key, NULL, sum(n)::bigint FROM ranked WHERE rn > #{@max_buckets} GROUP BY key, row_key
    UNION ALL
    SELECT 'r', key, row_key, NULL, count(DISTINCT id)::bigint FROM cells GROUP BY key, row_key
    UNION ALL
    SELECT 'k', key, NULL, NULL, count(DISTINCT id)::bigint FROM cells GROUP BY key
    """

    %{rows: rows} = Repo.query!(sql, params ++ [under, keys])

    Enum.reduce(rows, %{}, fn [kind, key, row, bucket, count], acc ->
      entry = Map.get(acc, key, %{answered: 0, rows: %{}})
      Map.put(acc, key, add(entry, kind, row, bucket, count))
    end)
    |> Map.new(fn {key, entry} -> {key, sort_buckets(entry)} end)
  end

  defp add(entry, "k", _row, _bucket, count), do: %{entry | answered: count}

  defp add(entry, kind, row, bucket, count) do
    row_entry = Map.get(entry.rows, row, %{answered: 0, buckets: [], other: 0})

    row_entry =
      case kind do
        "b" -> %{row_entry | buckets: [{bucket, count} | row_entry.buckets]}
        "o" -> %{row_entry | other: count}
        "r" -> %{row_entry | answered: count}
      end

    %{entry | rows: Map.put(entry.rows, row, row_entry)}
  end

  defp sort_buckets(entry) do
    rows =
      Map.new(entry.rows, fn {row, row_entry} ->
        {row, %{row_entry | buckets: Enum.sort_by(row_entry.buckets, fn {b, n} -> {-n, b} end)}}
      end)

    %{entry | rows: rows}
  end

  @doc """
  Over the scores Potok gave (`Value.managed`): how many, the average, median,
  lowest and highest, how many got each score, and per question how many got it
  right, wrong or wait for an editor.
  """
  def score_stats(group_id, alt_id, collection) do
    params = base_params(group_id, alt_id, collection)
    scored = "#{condition(alt_id)} AND jsonb_typeof(v.managed -> 'score') = 'number'"

    %{rows: [[count, average, median, low, high]]} =
      Repo.query!(
        """
        SELECT count(*), avg(s)::float, (percentile_cont(0.5) WITHIN GROUP (ORDER BY s))::float,
               min(s)::float, max(s)::float
        FROM (SELECT (v.managed ->> 'score')::numeric AS s FROM "values" v WHERE #{scored}) t
        """,
        params
      )

    %{rows: distribution} =
      Repo.query!(
        """
        SELECT (v.managed ->> 'score')::float AS s, count(*)
        FROM "values" v WHERE #{scored}
        GROUP BY s ORDER BY s LIMIT 1001
        """,
        params
      )

    %{rows: items} =
      Repo.query!(
        """
        SELECT i.key,
               CASE WHEN jsonb_typeof(i.value -> 'points') IS DISTINCT FROM 'number' THEN 'pending'
                    WHEN (i.value ->> 'ok') = 'true' THEN 'ok'
                    ELSE 'bad' END,
               count(*)
        FROM "values" v
        CROSS JOIN LATERAL jsonb_each(
          CASE WHEN jsonb_typeof(v.managed -> 'items') = 'object' THEN v.managed -> 'items' ELSE '{}'::jsonb END
        ) AS i
        WHERE #{condition(alt_id)}
        GROUP BY 1, 2
        """,
        params
      )

    %{
      count: count,
      average: average,
      median: median,
      min: low,
      max: high,
      distribution: Enum.map(distribution, fn [score, n] -> %{score: score, count: n} end),
      items:
        Enum.reduce(items, %{}, fn [key, status, n], acc ->
          Map.update(acc, key, %{status => n}, &Map.put(&1, status, n))
        end)
    }
  end
end
