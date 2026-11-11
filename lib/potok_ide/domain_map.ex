defmodule PotokIde.DomainMap do
  @moduledoc """
  The entities of the domain and the links between them, for the map at `/domain`.

  Fields come from the Ecto schemas, and foreign keys, delete rules, unique
  indexes and checks from the database's catalog, so the map cannot fall behind
  them. A new schema has to be added to `@entities`; a test fails until it is.

  Where the two differ the database wins: `GroupMemberRole.profile_id` is a
  `belongs_to :profile` in Ecto and a composite key to `group_memberships` in
  the database.

  The result is cached until the node restarts, as only a deploy changes it.
  What the entities and their columns mean is in `PotokIdeWeb.DomainCopy`,
  which is also what keeps the column names from reaching the page.
  """

  alias PotokIde.Cache
  alias PotokIde.Repo

  @domains ~w(account profiles group content calendar polls notices tags joining)

  @entities [
    {"account",
     [
       PotokIde.Accounts.Account,
       PotokIde.Accounts.AccountToken,
       PotokIde.Accounts.PushSubscription,
       PotokIde.GmailRefreshToken
     ]},
    {"profiles", [PotokIde.Social.Profile, PotokIde.Social.AccountProfile]},
    {"group",
     [
       PotokIde.Social.Group,
       PotokIde.Social.GroupManifest,
       PotokIde.Social.GroupRole,
       PotokIde.Social.GroupMembership,
       PotokIde.Social.GroupMemberRole,
       PotokIde.Social.GroupAltDescription,
       PotokIde.Social.GroupReaction,
       PotokIde.Social.GroupBlock
     ]},
    {"content",
     [
       PotokIde.Social.Value,
       PotokIde.Social.ValueAttachment,
       PotokIde.Social.ValueReaction,
       PotokIde.Social.GroupValueRead
     ]},
    {"calendar",
     [PotokIde.Events.Event, PotokIde.Events.Response, PotokIde.Events.MemberSetting]},
    {"polls", [PotokIde.Polls.Poll, PotokIde.Polls.PollOption, PotokIde.Polls.PollBallot]},
    {"notices",
     [
       PotokIde.Notices.GroupFollow,
       PotokIde.Notices.GroupNotice,
       PotokIde.Notices.GroupNoticeReceipt
     ]},
    {"tags", [PotokIde.Tags.Tag, PotokIde.Tags.Tagging]},
    {"joining",
     [
       PotokIde.Social.GroupInvitation,
       PotokIde.Social.GroupAccountInvitation,
       PotokIde.Social.ProfileInvitation,
       PotokIde.Social.GroupJoinRequest,
       PotokIde.Social.GroupJoinRequestApproval
     ]}
  ]

  # Columns that point at another table with no key to hold them there:
  # {from, column, to, column it refers to}.
  @soft_links [
    {"GroupMemberRole", "role_key", "GroupRole", "key"},
    {"GroupAltDescription", "visible_role_keys", "GroupRole", "key"},
    {"GroupValueRead", "last_read_value_id", "Value", "id"},
    {"Value", "mentioned_profile_ids", "Profile", "id"},
    {"Poll", "voter_role_keys", "GroupRole", "key"},
    {"Poll", "results_role_keys", "GroupRole", "key"},
    {"Poll", "details_role_keys", "GroupRole", "key"},
    {"PollBallot", "option_ids", "PollOption", "id"}
  ]

  def domains, do: @domains

  def modules, do: Enum.flat_map(@entities, &elem(&1, 1))

  @doc """
  `%{entities: [...], edges: [...]}`. An edge is a foreign key
  (`kind: :key`, with its delete `rule`) or a `kind: :soft` link, and goes from
  the table holding it to the one it points at. `columns` starts with the
  edge's own column; a composite key has the shared one after it.
  """
  def graph, do: Cache.fetch(__MODULE__, :infinity, &read_graph/0)

  @doc """
  What deleting a row of the entity does in the database: the keys that block
  it, the entities whose rows go with it and the keys that get cleared. The
  code can do more before it deletes.
  """
  def deletion(id, edges \\ graph().edges) do
    keys = Enum.filter(edges, &(&1.kind == :key))
    reached = reached_by_cascade(keys, [id], MapSet.new([id]))
    touching = Enum.filter(keys, &(&1.to in reached))

    %{
      blocked_by: Enum.filter(touching, &(&1.rule == :restrict)),
      cascades: reached |> MapSet.delete(id) |> Enum.sort(),
      clears: Enum.filter(touching, &(&1.rule == :nilify))
    }
  end

  defp reached_by_cascade(_keys, [], reached), do: reached

  defp reached_by_cascade(keys, [id | rest], reached) do
    new =
      for %{to: ^id, rule: :cascade, from: from} <- keys,
          from not in reached,
          uniq: true,
          do: from

    reached_by_cascade(keys, rest ++ new, Enum.into(new, reached))
  end

  defp read_graph do
    entities =
      for {domain, modules} <- @entities, module <- modules do
        entity(module, domain)
      end

    edges = key_edges(entities) ++ soft_edges()
    unique = unique_indexes()
    checks = checks()

    %{
      entities:
        Enum.map(entities, fn entity ->
          entity
          |> mark_key_columns(edges)
          |> Map.put(:unique, Map.get(unique, entity.table, []))
          |> Map.put(:checks, Map.get(checks, entity.table, []))
        end),
      edges: edges
    }
  end

  defp entity(module, domain) do
    %{
      id: id(module),
      domain: domain,
      table: module.__schema__(:source),
      module: inspect(module),
      file: "lib/#{Macro.underscore(inspect(module))}.ex",
      fields: fields(module),
      virtual:
        for field <- module.__schema__(:virtual_fields) do
          %{name: field, type: type_name(module.__schema__(:virtual_type, field))}
        end
    }
  end

  defp id(module), do: module |> Module.split() |> List.last()

  defp fields(module) do
    primary_key = module.__schema__(:primary_key)

    for field <- module.__schema__(:fields) do
      %{
        name: field,
        type: type_name(module.__schema__(:type, field)),
        primary?: field in primary_key
      }
    end
  end

  defp mark_key_columns(entity, edges) do
    columns =
      for %{kind: :key, from: from, columns: [column | _]} <- edges,
          from == entity.id,
          do: column

    fields = Enum.map(entity.fields, &Map.put(&1, :key?, to_string(&1.name) in columns))
    %{entity | fields: fields}
  end

  defp type_name({:parameterized, {Ecto.Enum, %{mappings: mappings}}}) do
    "enum(" <> Enum.map_join(mappings, " | ", fn {value, _} -> value end) <> ")"
  end

  defp type_name({:array, type}), do: type_name(type) <> "[]"
  # A PostGIS column (`Group.area`), by the database's name for it.
  defp type_name(Geo.PostGIS.Geometry), do: "geometry"
  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(type), do: inspect(type)

  defp soft_edges do
    for {from, column, to, target} <- @soft_links do
      %{kind: :soft, from: from, to: to, columns: [column], target: target}
    end
  end

  defp key_edges(entities) do
    ids = Map.new(entities, &{&1.table, &1.id})

    rows =
      Repo.query!("""
      SELECT source.relname, target.relname, key.confdeltype::text,
             (SELECT array_agg(column_name.attname::text ORDER BY position.ordinality)
                FROM unnest(key.conkey) WITH ORDINALITY AS position(attnum, ordinality)
                JOIN pg_attribute column_name
                  ON column_name.attrelid = key.conrelid
                 AND column_name.attnum = position.attnum)
        FROM pg_constraint key
        JOIN pg_class source ON source.oid = key.conrelid
        JOIN pg_class target ON target.oid = key.confrelid
       WHERE key.contype = 'f' AND key.connamespace = 'public'::regnamespace
       ORDER BY 1, 4
      """).rows

    single_columns = for [table, _, _, [column]] <- rows, into: MapSet.new(), do: {table, column}

    for [table, target, rule, columns] <- rows, is_map_key(ids, table), is_map_key(ids, target) do
      %{
        kind: :key,
        from: ids[table],
        to: ids[target],
        columns: own_column_first(table, columns, single_columns),
        rule: delete_rule(rule)
      }
    end
  end

  # The other column of a composite key has a key of its own: `group_id` in
  # `(alt_description_id, group_id)`. Both orders exist in the catalog.
  defp own_column_first(_table, [_] = columns, _single_columns), do: columns

  defp own_column_first(table, columns, single_columns) do
    {shared, own} = Enum.split_with(columns, &MapSet.member?(single_columns, {table, &1}))
    own ++ shared
  end

  defp delete_rule("c"), do: :cascade
  defp delete_rule("n"), do: :nilify
  # `NO ACTION` blocks a delete just like `RESTRICT`.
  defp delete_rule(_rule), do: :restrict

  defp unique_indexes do
    Repo.query!("""
    SELECT tablename, indexdef FROM pg_indexes
     WHERE schemaname = 'public' AND indexdef LIKE 'CREATE UNIQUE%'
       AND indexname NOT LIKE '%\\_pkey'
     ORDER BY 1, 2
    """).rows
    |> Enum.group_by(&hd/1, fn [_table, definition] -> unique_index(definition) end)
  end

  defp unique_index(definition) do
    {head, where} =
      case String.split(definition, " WHERE ", parts: 2) do
        [head, where] -> {head, inner(where)}
        [head] -> {head, nil}
      end

    columns =
      head
      |> String.split("USING btree ", parts: 2)
      |> List.last()
      |> inner()
      |> String.replace(~r/lower\(\((\w+)\)::text\)/, "lower(\\1)")
      |> String.split(", ")

    %{columns: columns, where: where}
  end

  # Enum lists are left out: the field's type already says them.
  defp checks do
    Repo.query!("""
    SELECT source.relname, key.conname, pg_get_constraintdef(key.oid)
      FROM pg_constraint key
      JOIN pg_class source ON source.oid = key.conrelid
     WHERE key.contype = 'c' AND key.connamespace = 'public'::regnamespace
       AND pg_get_constraintdef(key.oid) NOT LIKE '%= ANY (%'
     ORDER BY 1, 2
    """).rows
    |> Enum.group_by(&hd/1, fn [_table, name, definition] ->
      %{name: name, definition: definition |> String.replace_prefix("CHECK ", "") |> inner()}
    end)
  end

  # What stands inside the outermost parentheses.
  defp inner(text) do
    text |> String.trim() |> String.slice(1..-2//1)
  end
end
