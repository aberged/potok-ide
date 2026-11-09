defmodule PotokIde.Social.ValueAggregate do
  @moduledoc """
  Sums over the numbers in app data values, made in the database so that the
  totals of a hundred thousand values cost one query, not a hundred thousand
  rows sent to a browser.

  The values are those a filtered listing would page through
  (`PotokIde.Social.list_group_data_value_rows/2`), and the numbers are read at
  `under` in each value's data (its top by default). For each of up to five
  `fields` it gives how many values hold a number there, their sum, average,
  lowest and highest. A number is a JSON number, or a string that is a plain
  decimal ("12", "-3.5"), of at most 61 characters either way; "1,5", "1e3"
  and anything else are skipped. Within that length no cast can fail and no
  sum can overflow.

  With `group_by` the same comes per value of that field too: the 50 biggest
  groups, and the rest summed as `other`. A group is the text of a string,
  number or boolean, cut to 200 characters; values without one fall in the
  `nil` group. One statement does it all and runs for at most five seconds.
  """

  import Ecto.Query, only: [select: 3]

  alias PotokIde.Repo

  @max_fields 5
  @max_buckets 50
  @max_key_bytes 64
  @max_depth 3
  @bucket_chars 200
  @number_chars 61
  @timeout_ms 5_000

  @doc """
  Checks what an app asked for, as it sent it: `group_by` a key or nil,
  `fields` a list of keys or nil, `under` a path of up to three keys or nil
  for `default_under`. Every key is 1..64 bytes of text. A bad one is refused,
  not cut, so the app learns of it.
  """
  def spec(group_by, fields, under, default_under) do
    with {:ok, group_by} <- group_by_spec(group_by),
         {:ok, fields} <- fields_spec(fields),
         {:ok, under} <- under_spec(under, default_under) do
      {:ok, %{group_by: group_by, fields: fields, under: under}}
    else
      _invalid -> {:error, :invalid_aggregate}
    end
  end

  defp group_by_spec(nil), do: {:ok, nil}
  defp group_by_spec(key), do: if(key?(key), do: {:ok, key}, else: :error)

  defp fields_spec(nil), do: {:ok, []}

  defp fields_spec(fields) when is_list(fields) do
    fields = Enum.uniq(fields)

    if length(fields) <= @max_fields and Enum.all?(fields, &key?/1),
      do: {:ok, fields},
      else: :error
  end

  defp fields_spec(_fields), do: :error

  defp under_spec(nil, default) when is_list(default), do: under_spec(default, [])

  defp under_spec(path, _default) when is_list(path) do
    if length(path) <= @max_depth and Enum.all?(path, &key?/1), do: {:ok, path}, else: :error
  end

  defp under_spec(_path, _default), do: :error

  defp key?(key),
    do: is_binary(key) and byte_size(key) in 1..@max_key_bytes and String.valid?(key)

  @doc """
  Adds up the values `query` selects (a query on `PotokIde.Social.Value`) as
  `spec` says. Returns `{:ok, %{total:, fields:, buckets:, other:}}`, where
  `fields` maps each field to `%{count:, sum:, avg:, min:, max:}`, `buckets`
  is nil without `group_by`, else `[%{value:, count:, fields:}]`, and `other`
  is `%{buckets:, count:}` past the 50 biggest groups, else nil. Or
  `{:error, :timeout}`.
  """
  def run(query, %{group_by: group_by, fields: fields, under: under}) do
    {filter_sql, filter_params} = Repo.to_sql(:all, select(query, [v], %{data: v.data}))
    {sql, params} = statement(filter_sql, filter_params, group_by, under, fields)

    Repo.with_statement_timeout(
      @timeout_ms,
      fn ->
        %{rows: rows} = Repo.query!(sql, params)
        result(rows, fields, not is_nil(group_by))
      end,
      jit: false
    )
  end

  # Keys are always parameters, never written into the statement, so its text
  # depends only on how many fields there are.
  #
  # Each level ends in `OFFSET 0`, which keeps Postgres from folding it into
  # the next: folded, every use of a column repeats the expression behind it,
  # and each number was parsed once per aggregate that reads it, four times
  # over (measured: 830 ms instead of 225 for 100k values).
  defp statement(filter_sql, filter_params, group_by, under, fields) do
    n = length(filter_params)
    group_param = "$#{n + 1}::text"
    under_param = "$#{n + 2}::text[]"

    indexed =
      fields |> Enum.with_index() |> Enum.map(fn {_field, i} -> {"$#{n + 3 + i}::text", i} end)

    keys =
      Enum.map_join(indexed, "", fn {param, i} ->
        ", jsonb_typeof(n.node -> #{param}) AS t#{i}, n.node ->> #{param} AS s#{i}"
      end)

    numbers = Enum.map_join(indexed, "", fn {_param, i} -> ",\n    #{number(i)} AS x#{i}" end)

    stats =
      Enum.map_join(indexed, "", fn {_param, i} ->
        ",\n  count(r.x#{i})::bigint, sum(r.x#{i})::float8, min(r.x#{i})::float8, max(r.x#{i})::float8," <>
          " (sum(count(r.x#{i})) OVER ())::bigint, (sum(sum(r.x#{i})) OVER ())::float8," <>
          " (min(min(r.x#{i})) OVER ())::float8, (max(max(r.x#{i})) OVER ())::float8"
      end)

    sql = """
    SELECT r.bucket, count(*)::bigint, (count(*) OVER ())::bigint, (sum(count(*)) OVER ())::bigint#{stats}
    FROM (
      SELECT left(CASE WHEN k.gt IN ('string', 'number', 'boolean') THEN k.g END, #{@bucket_chars}) AS bucket#{numbers}
      FROM (
        SELECT jsonb_typeof(n.node -> #{group_param}) AS gt, n.node ->> #{group_param} AS g#{keys}
        FROM (SELECT f.data #> #{under_param} AS node FROM (#{filter_sql}) AS f OFFSET 0) AS n
        OFFSET 0
      ) AS k
      OFFSET 0
    ) AS r
    GROUP BY r.bucket
    ORDER BY count(*) DESC, r.bucket NULLS LAST
    LIMIT #{@max_buckets}
    """

    {sql, filter_params ++ [group_by, under | fields]}
  end

  # A JSON number, which jsonb always writes as a plain decimal, or a string
  # that is one; nil for anything else. The regex has no counted repeats,
  # which cost Postgres several times more.
  defp number(i) do
    "CASE WHEN k.t#{i} = 'number' AND length(k.s#{i}) <= #{@number_chars} THEN k.s#{i}::numeric" <>
      " WHEN k.t#{i} = 'string' AND length(k.s#{i}) <= #{@number_chars}" <>
      " AND k.s#{i} ~ '^-?[0-9]+(\\.[0-9]+)?$' THEN k.s#{i}::numeric END"
  end

  defp result([], fields, grouped?) do
    %{
      total: 0,
      fields: Map.new(fields, &{&1, stats(0, nil, nil, nil)}),
      buckets: if(grouped?, do: []),
      other: nil
    }
  end

  defp result([[_bucket, _n, bucket_count, total | first] | _] = rows, fields, grouped?) do
    buckets =
      Enum.map(rows, fn [bucket, n, _bucket_count, _total | values] ->
        %{value: bucket, count: n, fields: field_stats(fields, values, 0)}
      end)

    other =
      if bucket_count > @max_buckets,
        do: %{
          buckets: bucket_count - @max_buckets,
          count: total - Enum.reduce(buckets, 0, &(&1.count + &2))
        }

    %{
      total: total,
      fields: field_stats(fields, first, 4),
      buckets: if(grouped?, do: buckets),
      other: other
    }
  end

  # Each field has eight columns: its group's count, sum, min and max, then
  # the same over every group. `offset` picks which four.
  defp field_stats(fields, values, offset) do
    fields
    |> Enum.with_index()
    |> Map.new(fn {field, i} ->
      [count, sum, min, max] = Enum.slice(values, i * 8 + offset, 4)
      {field, stats(count, sum, min, max)}
    end)
  end

  defp stats(count, sum, min, max) do
    %{
      count: count,
      sum: sum || 0.0,
      avg: if(count > 0, do: sum / count),
      min: min,
      max: max
    }
  end
end
