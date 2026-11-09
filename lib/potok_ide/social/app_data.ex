defmodule PotokIde.Social.AppData do
  @moduledoc """
  Data values of apps kept in collections, under rules the app's editors set
  (`PotokIde.Social.ValueRules`).

  An app's config is one data value of the collection `config`: whatever the
  app keeps there (a form's questions, say), with `rules` that Potok reads, a
  `secret` that only the editors read (the key of a quiz) and `files`, the
  sub-groups that keep the files sent with its values, which Potok writes
  (`PotokIde.Social.AppFiles`). It is changed in place, with `lock_version`
  as its revision, so two editors cannot overwrite each other unawares.

  Values of the other collections are written and read only as the rules say.
  Every write runs in one transaction that reads the config `FOR SHARE`, so a
  form closed by an editor takes no answer after the close, and reads the
  viewer's access again, as a page may hold an old one.

  Values outside collections (`collection: nil`) belong to apps that use none
  and keep the old behaviour in `PotokIde.Social`; they never mix with these.

  Changes go to `topic/1` as `{:app_value, group_id, event, payload}`, which
  only pages that know these events subscribe to. Each page decides for its
  own viewer (`PotokIdeWeb.GroupLive.Show.AppValues`).
  """

  import Ecto.Query, warn: false

  alias Phoenix.PubSub
  alias PotokIde.Accounts.Account
  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Storage

  alias PotokIde.Social.{
    Access,
    AccountProfile,
    AppFiles,
    Group,
    Identity,
    Notifications,
    Profile,
    Value,
    ValueRules,
    ValueScoring,
    ValueSummary
  }

  @config "config"
  @notify "notify"

  @max_value_bytes 64 * 1024
  @max_config_bytes 512 * 1024
  @max_page 100
  @max_summary_keys 200
  @outsider_values_per_minute 10

  @doc "Most values a page of `list/6` holds: a page of big values must fit in one socket frame."
  def max_page, do: @max_page

  @doc "The PubSub topic of the group's app values in collections."
  def topic(group_id) when is_integer(group_id), do: "groups:#{group_id}:app_values"

  def subscribe(%Group{id: group_id}),
    do: PubSub.subscribe(PotokIde.PubSub, topic(group_id))

  # ---------
  # Config
  # ---------

  @doc "The app's config: the newest value of its collection `config`, or nil."
  def get_config(%Group{} = group, alt) do
    group
    |> collection_query(alt, @config)
    |> order_by([v], desc: v.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The normalized rules of a config."
  def rules(%Value{data: %{"rules" => rules}}) when is_map(rules), do: rules
  def rules(_config), do: %{}

  @doc "The key a collection is scored by, from the config's secret part."
  def key(%Value{data: %{"secret" => %{"score" => keys}}}, collection) when is_map(keys) do
    case Map.get(keys, collection) do
      key when is_map(key) -> key
      _none -> %{}
    end
  end

  def key(_config, _collection), do: %{}

  @doc "The rule of `collection` in the app's config."
  def rule(config, collection), do: ValueRules.rule(rules(config), collection)

  @doc "The config as the holder of `access` may see it: its secret part goes only to editors."
  def config_payload(nil, _access), do: nil

  def config_payload(%Value{} = config, %Access{} = access) do
    data =
      if ValueRules.manage?(access), do: config.data, else: Map.delete(config.data, "secret")

    %{id: config.id, revision: config.lock_version, data: data, updated_at: config.updated_at}
  end

  @doc """
  Saves the app's config. `revision` is the one the editor started from: nil
  or 0 when there is none yet. Another editor's save in between gives
  `{:error, {:conflict, current}}`, with the config as it is now (nil when it
  was deleted). Potok keeps `files` itself, whatever comes in.
  """
  def save_config(%Profile{} = profile, %Group{} = group, alt, data, revision) do
    with {:ok, data} <- decode(data),
         :ok <- fits(data, @max_config_bytes),
         {:ok, rules} <- ValueRules.normalize(data["rules"]) do
      Repo.transaction(fn ->
        lock_app(group, alt)
        access = Access.for_profile(profile, Repo.get!(Group, group.id))

        unless ValueRules.manage?(access), do: Repo.rollback(:not_permitted)

        current = locked_config(group, alt)
        data = data |> Map.put("rules", rules) |> Map.put("files", files_of(current))

        saved =
          case {current, revision} do
            {nil, revision} when revision in [nil, 0] -> insert_config(profile, group, alt, data)
            {nil, _revision} -> Repo.rollback({:conflict, nil})
            {%Value{lock_version: ^revision}, _} -> update_config(current, data)
            {%Value{}, _revision} -> Repo.rollback({:conflict, current})
          end

        {saved, current}
      end)
      |> case do
        {:ok, {saved, previous}} ->
          broadcast(group, :config, %{
            alt_id: alt_id(alt),
            id: saved.id,
            revision: saved.lock_version
          })

          regrade_changed(group, alt, previous, saved)
          {:ok, saved}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  # For `AppFiles`, inside its own transaction: the sub-groups that keep the
  # files go into the config with no new revision, as the editor's next save
  # must not conflict with them.
  def put_files(%Value{} = config, files) do
    config
    |> Ecto.Changeset.change(data: Map.put(config.data, "files", files))
    |> Repo.update!()
  end

  defp files_of(%Value{data: %{"files" => files}}) when is_map(files), do: files
  defp files_of(_config), do: %{}

  defp insert_config(profile, group, alt, data) do
    %Value{
      alt_description_id: alt_id(alt),
      collection: @config,
      is_data: true,
      creator_id: profile.id,
      group_id: group.id,
      content: "data:",
      content_format: :markdown,
      data: data
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.check_constraint(:collection, name: :values_collection_check)
    |> Repo.insert!()
  end

  defp update_config(%Value{} = config, data) do
    config
    |> Ecto.Changeset.change(data: data)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  # A new key, or new rules for a score, scores again what was answered.
  defp regrade_changed(group, alt, previous, %Value{} = saved) do
    old_rules = rules(previous)

    saved
    |> rules()
    |> Enum.filter(fn {collection, rule} ->
      is_map(rule["score"]) and
        (key(previous, collection) != key(saved, collection) or
           Map.take(Map.get(old_rules, collection) || %{}, ["score", "under"]) !=
             Map.take(rule, ["score", "under"]))
    end)
    |> Enum.each(fn {collection, _rule} ->
      run_async(fn -> regrade(group, alt, collection) end)
    end)
  end

  # ---------
  # Values
  # ---------

  @doc """
  Writes `data` to `collection` in `profile`'s name, as its rule allows.
  `account` is the viewer's, for `once`. Returns `{:ok, value, rule}`.
  """
  def insert(%Profile{} = profile, %Account{} = account, %Group{} = group, alt, collection, data) do
    now = DateTime.utc_now(:second)

    with true <- ValueRules.app_collection?(collection) || {:error, :invalid_collection},
         {:ok, data} <- decode(data),
         :ok <- fits(data, @max_value_bytes) do
      Repo.transaction(fn ->
        config = shared_config(group, alt)
        group = Repo.get!(Group, group.id)
        access = Access.for_profile(profile, group)
        rule = rule(config, collection)

        case ValueRules.write_block(rule, group, access, profile, now) do
          nil -> :ok
          block -> Repo.rollback(block)
        end

        if not access.member? and outsider_at_limit?(profile, group),
          do: Repo.rollback(:rate_limited)

        if rule.once, do: ensure_first(profile, account, group, alt, collection)

        files = AppFiles.check_refs(rule, config, group, alt, data, profile, nil)

        value =
          %Value{
            alt_description_id: alt_id(alt),
            collection: collection,
            anonymous: rule.anonymous,
            managed: score(rule, config, collection, data, nil),
            is_data: true,
            creator_id: profile.id,
            group_id: group.id,
            content: "data:",
            content_format: :markdown,
            data: data
          }
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.check_constraint(:collection, name: :values_collection_check)
          |> Repo.insert!()

        AppFiles.claim(files, value)
        {%{value | creator: profile}, rule}
      end)
      |> case do
        {:ok, {value, rule}} ->
          broadcast_value(group, :created, value, rule)
          notify_subscribers(group, alt, value, rule, profile)
          {:ok, value, rule}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Changes the viewer's own value, where the rule lets authors edit theirs.
  `revision` nil skips the check against another change in between.
  """
  def update(%Profile{} = profile, %Group{} = group, alt, id, data, revision) do
    now = DateTime.utc_now(:second)

    with {:ok, data} <- decode(data),
         :ok <- fits(data, @max_value_bytes) do
      Repo.transaction(fn ->
        config = shared_config(group, alt)
        value = locked_value(group, alt, id) || Repo.rollback(:not_found)
        group = Repo.get!(Group, group.id)
        access = Access.for_profile(profile, group)
        rule = rule(config, value.collection)

        case ValueRules.edit_block(rule, value.creator_id, group, access, profile, now) do
          nil -> :ok
          block -> Repo.rollback(block)
        end

        if is_integer(revision) and revision != value.lock_version,
          do: Repo.rollback({:conflict, value})

        files = AppFiles.check_refs(rule, config, group, alt, data, profile, value.id)

        updated =
          value
          |> Ecto.Changeset.change(
            data: data,
            managed: score(rule, config, value.collection, data, value.managed)
          )
          |> Ecto.Changeset.optimistic_lock(:lock_version)
          |> Repo.update!()

        dropped = AppFiles.reclaim(files, updated)
        {%{updated | creator: profile}, rule, dropped}
      end)
      |> case do
        {:ok, {value, rule, dropped}} ->
          Storage.delete_later(dropped)
          broadcast_value(group, :updated, value, rule)
          {:ok, value, rule}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Deletes a value of one of the app's collections: for its editors, with the files it took."
  def delete(%Profile{} = profile, %Group{} = group, alt, id) do
    Repo.transaction(fn ->
      access = Access.for_profile(profile, Repo.get!(Group, group.id))

      unless ValueRules.manage?(access), do: Repo.rollback(:not_permitted)

      value = locked_value(group, alt, id) || Repo.rollback(:not_found)
      config = get_config(group, alt)
      Repo.delete!(value)
      keys = AppFiles.delete_for_values(config, [value.id])
      {value, rule(config, value.collection), keys}
    end)
    |> case do
      {:ok, {value, rule, keys}} ->
        Storage.delete_later(keys)

        broadcast(group, :deleted, %{
          alt_id: alt_id(alt),
          collection: value.collection,
          id: value.id,
          creator_id: value.creator_id,
          read: rule.read
        })

        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deletes every value of one collection of the app: for its editors. Returns how many."
  def delete_collection(%Profile{} = profile, %Group{} = group, alt, collection) do
    with true <- ValueRules.app_collection?(collection) || {:error, :invalid_collection} do
      Repo.transaction(fn ->
        access = Access.for_profile(profile, Repo.get!(Group, group.id))

        unless ValueRules.manage?(access), do: Repo.rollback(:not_permitted)

        ids = group |> collection_query(alt, collection) |> select([v], v.id) |> Repo.all()
        keys = AppFiles.delete_for_values(get_config(group, alt), ids)

        {count, _rows} =
          group |> collection_query(alt, collection) |> Repo.delete_all()

        {count, keys}
      end)
      |> case do
        {:ok, {count, keys}} ->
          Storage.delete_later(keys)

          broadcast(group, :cleared, %{alt_id: alt_id(alt), collection: collection})
          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  A page of `collection`: every value for its full readers, otherwise the
  viewer's own. Options: `limit` (up to #{@max_page}), `offset`, `before_id`,
  `after_id`, `order_dir` ("desc" for the newest first), `mine`, `match`
  (full readers only) and `total`. Returns `{:ok, rows, more?, total}`, the
  rows as the viewer may see them.
  """
  def list(profile, %Group{} = group, alt, %Access{} = access, collection, opts \\ []) do
    with true <- ValueRules.app_collection?(collection) || {:error, :invalid_collection} do
      config = get_config(group, alt)
      rule = rule(config, collection)
      full? = ValueRules.full_reader?(rule, access)
      viewer_id = profile && profile.id

      cond do
        is_nil(viewer_id) ->
          {:error, :not_permitted}

        not full? and not access.member? and not ValueRules.public?(rule, group) ->
          {:error, :not_a_member}

        true ->
          filters = [
            scope: {:app, alt_id(alt)},
            collection: collection,
            creator_id: if(Keyword.get(opts, :mine, false) or not full?, do: viewer_id),
            match: if(full?, do: opts[:match])
          ]

          paging = [
            limit: min(opts[:limit] || 50, @max_page),
            offset: opts[:offset],
            before_id: opts[:before_id],
            after_id: opts[:after_id],
            order_dir: opts[:order_dir]
          ]

          {rows, more?} = PotokIde.Social.list_group_data_value_rows(group, filters ++ paging)

          total =
            if Keyword.get(opts, :total, false),
              do: PotokIde.Social.count_group_data_value_rows(group, filters)

          key = key(config, collection)
          rows = Enum.map(rows, &ValueRules.present(&1, rule, viewer_id, access, key))
          {:ok, rows, more?, total}
      end
    end
  end

  @doc """
  Counts over the answers of `collection` (`ValueSummary`), for its full
  readers and its `summary` roles; scores only for full readers.
  """
  def summarize(%Group{} = group, alt, %Access{} = access, collection, opts) do
    config = get_config(group, alt)
    rule = rule(config, collection)
    full? = ValueRules.full_reader?(rule, access)
    keys = opts[:keys] || []
    under = opts[:under] || rule.under

    cond do
      not ValueRules.app_collection?(collection) ->
        {:error, :invalid_collection}

      not (full? or ValueRules.summary_reader?(rule, group, access)) ->
        {:error, :not_permitted}

      not valid_path?(under) or not valid_keys?(keys) ->
        {:error, :invalid_summary}

      true ->
        ValueSummary.summarize(group.id, alt_id(alt), collection, under, keys,
          score: full? and Keyword.get(opts, :score, false)
        )
    end
  end

  @doc """
  Sums over the numbers in `collection` (`PotokIde.Social.ValueAggregate`),
  read at the rule's `under` unless the app names a path: for its full readers
  only, as a sum or a lowest value over a narrow `match` can tell one answer,
  which a summary reader must not see.
  """
  def aggregate(%Group{} = group, alt, %Access{} = access, collection, opts) do
    config = get_config(group, alt)
    rule = rule(config, collection)
    full? = ValueRules.full_reader?(rule, access)

    cond do
      not ValueRules.app_collection?(collection) ->
        {:error, :invalid_collection}

      not full? and not access.member? ->
        {:error, :not_a_member}

      not full? ->
        {:error, :not_permitted}

      true ->
        PotokIde.Social.aggregate_group_data_values(group,
          scope: {:app, alt_id(alt)},
          collection: collection,
          match: opts[:match],
          group_by: opts[:group_by],
          fields: opts[:fields],
          under: opts[:under],
          default_under: rule.under || []
        )
    end
  end

  defp valid_path?(path),
    do: is_list(path) and path != [] and length(path) <= 3 and Enum.all?(path, &short_key?/1)

  defp valid_keys?(keys),
    do: is_list(keys) and length(keys) <= @max_summary_keys and Enum.all?(keys, &short_key?/1)

  defp short_key?(value), do: is_binary(value) and byte_size(value) in 1..64

  @doc """
  An editor's grades of one value: per question `points` and `feedback`
  (`ValueScoring.grade/4`). Not a change of the value, so its revision stays.
  """
  def grade(%Profile{} = profile, %Group{} = group, alt, id, patch) when is_map(patch) do
    Repo.transaction(fn ->
      access = Access.for_profile(profile, Repo.get!(Group, group.id))

      unless ValueRules.manage?(access), do: Repo.rollback(:not_permitted)

      config = shared_config(group, alt)
      value = locked_value(group, alt, id) || Repo.rollback(:not_found)
      rule = rule(config, value.collection)

      unless is_map(rule.score) and rule.under, do: Repo.rollback(:not_scored)

      managed =
        ValueScoring.grade(
          value.managed,
          patch,
          get_in(value.data, rule.under),
          key(config, value.collection)
        )

      graded = value |> Ecto.Changeset.change(managed: managed) |> Repo.update!()
      {Repo.preload(graded, :creator), rule}
    end)
    |> case do
      {:ok, {value, rule}} ->
        broadcast_value(group, :updated, value, rule)
        {:ok, value, rule}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def grade(_profile, _group, _alt, _id, _patch), do: {:error, :invalid_value}

  @doc """
  Scores every value of `collection` again by the current key, keeping the
  editors' grades, a batch at a time, and tells the pages.
  """
  def regrade(%Group{} = group, alt, collection) do
    config = get_config(group, alt)
    rule = rule(config, collection)
    key = key(config, collection)

    if is_map(rule.score) and rule.under do
      regrade_batches(group, alt, collection, rule, key, 0)
      broadcast(group, :regraded, %{alt_id: alt_id(alt), collection: collection})
    end

    :ok
  end

  defp regrade_batches(group, alt, collection, rule, key, after_id) do
    batch =
      group
      |> collection_query(alt, collection)
      |> where([v], v.id > ^after_id)
      |> order_by([v], asc: v.id)
      |> limit(500)
      |> select([v], {v.id, v.data, v.managed})
      |> Repo.all()

    Repo.transaction(fn ->
      Enum.each(batch, fn {id, data, managed} ->
        from(v in Value, where: v.id == ^id)
        |> Repo.update_all(
          set: [managed: ValueScoring.score(get_in(data, rule.under), key, managed)]
        )
      end)
    end)

    case List.last(batch) do
      {last_id, _data, _managed} when length(batch) == 500 ->
        regrade_batches(group, alt, collection, rule, key, last_id)

      _done ->
        :ok
    end
  end

  defp score(%{score: score, under: under}, config, collection, data, previous)
       when is_map(score) and is_list(under) do
    ValueScoring.score(get_in(data, under), key(config, collection), previous)
  end

  defp score(_rule, _config, _collection, _data, previous), do: previous

  # ---------
  # Notifications
  # ---------

  @doc "Whether `profile` hears of new values of the collection."
  def notifications?(%Profile{id: profile_id}, %Group{} = group, alt, collection) do
    group
    |> collection_query(alt, @notify)
    |> where([v], v.creator_id == ^profile_id)
    |> where([v], fragment("? ->> 'collection' = ?", v.data, ^collection))
    |> Repo.exists?()
  end

  def notifications?(_profile, _group, _alt, _collection), do: false

  @doc """
  Turns the viewer's push for new values of `collection` on or off. Only for
  those who read all of it.
  """
  def set_notifications(%Profile{} = profile, %Group{} = group, alt, collection, on?) do
    with true <- ValueRules.app_collection?(collection) || {:error, :invalid_collection} do
      Repo.transaction(fn ->
        access = Access.for_profile(profile, Repo.get!(Group, group.id))
        rule = rule(get_config(group, alt), collection)

        unless ValueRules.full_reader?(rule, access), do: Repo.rollback(:not_permitted)

        existing =
          group
          |> collection_query(alt, @notify)
          |> where([v], v.creator_id == ^profile.id)
          |> where([v], fragment("? ->> 'collection' = ?", v.data, ^collection))

        Repo.delete_all(existing)

        if on? do
          Repo.insert!(%Value{
            alt_description_id: alt_id(alt),
            collection: @notify,
            is_data: true,
            creator_id: profile.id,
            group_id: group.id,
            content: "data:",
            content_format: :markdown,
            data: %{"collection" => collection}
          })
        end

        on?
      end)
    end
  end

  # A push to those who asked for one and may still read the value, never to
  # its author, and without a name when it is anonymous.
  defp notify_subscribers(group, alt, %Value{} = value, rule, %Profile{} = author) do
    run_notification(fn ->
      subscriber_ids =
        group
        |> collection_query(alt, @notify)
        |> where([v], fragment("? ->> 'collection' = ?", v.data, ^value.collection))
        |> where([v], v.creator_id != ^author.id)
        |> select([v], v.creator_id)
        |> Repo.all()

      readers =
        if subscriber_ids == [] do
          []
        else
          group
          |> Access.for_members()
          |> Enum.filter(fn {profile_id, access} ->
            profile_id in subscriber_ids and ValueRules.full_reader?(rule, access)
          end)
          |> Enum.map(fn {profile_id, _access} -> profile_id end)
        end

      if readers != [] do
        author_accounts =
          from(ap in AccountProfile, where: ap.profile_id == ^author.id, select: ap.account_id)

        payload_for =
          Notifications.app_value_created(group, alt, if(value.anonymous, do: nil, else: author))

        from(ap in AccountProfile,
          where: ap.profile_id in ^readers and ap.account_id not in subquery(author_accounts),
          distinct: true,
          select: ap.account_id
        )
        |> Dispatch.subscriptions_by_account()
        |> Dispatch.deliver_localized("app value", group.id, payload_for)
      end
    end)
  end

  defp run_notification(fun), do: Dispatch.run(fun)

  # ---------
  # Helpers
  # ---------

  @doc false
  def collection_query(%Group{id: group_id}, alt, collection) do
    query =
      from(v in Value,
        where: v.group_id == ^group_id and v.is_data == true and v.collection == ^collection
      )

    case alt_id(alt) do
      nil -> where(query, [v], is_nil(v.alt_description_id))
      id -> where(query, [v], v.alt_description_id == ^id)
    end
  end

  @doc false
  def alt_id(nil), do: nil
  def alt_id(%{id: id}), do: id
  def alt_id(id) when is_integer(id), do: id

  defp locked_config(group, alt) do
    group
    |> collection_query(alt, @config)
    |> order_by([v], desc: v.id)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  # The rules hold for the whole write: an editor's save waits for it to end.
  defp shared_config(group, alt) do
    group
    |> collection_query(alt, @config)
    |> order_by([v], desc: v.id)
    |> limit(1)
    |> lock("FOR SHARE")
    |> Repo.one()
  end

  # A value of the app that one of its collections holds, never its config or
  # what Potok keeps for it.
  defp locked_value(%Group{id: group_id}, alt, id) when is_integer(id) do
    query =
      from(v in Value,
        where:
          v.id == ^id and v.group_id == ^group_id and v.is_data == true and
            not is_nil(v.collection) and v.collection not in ^ValueRules.reserved(),
        lock: "FOR UPDATE"
      )

    case alt_id(alt) do
      nil -> where(query, [v], is_nil(v.alt_description_id))
      alt_id -> where(query, [v], v.alt_description_id == ^alt_id)
    end
    |> Repo.one()
  end

  defp locked_value(_group, _alt, _id), do: nil

  # One editor's save at a time, also before the config exists.
  defp lock_app(%Group{id: group_id}, alt) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [7_101, lock_key({group_id, alt_id(alt)})])
  end

  defp lock_key(term), do: :erlang.phash2(term, 2_147_483_647)

  # Two answers of one person racing each other: the second waits and is refused.
  defp ensure_first(profile, account, group, alt, collection) do
    account_id = Identity.counted_account_id(profile, account)
    person = account_id || {:profile, profile.id}

    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      7_102,
      lock_key({group.id, alt_id(alt), collection, person})
    ])

    answered? =
      group
      |> collection_query(alt, collection)
      |> where(
        [v],
        v.creator_id in subquery(Identity.counted_profile_ids_query(profile, account_id))
      )
      |> Repo.exists?()

    if answered?, do: Repo.rollback(:already_answered)
  end

  @doc "Whether this person (the same identity as `once`) already has a value in the collection."
  def answered?(%Profile{} = profile, %Account{} = account, %Group{} = group, alt, collection) do
    account_id = Identity.counted_account_id(profile, account)

    group
    |> collection_query(alt, collection)
    |> where(
      [v],
      v.creator_id in subquery(Identity.counted_profile_ids_query(profile, account_id))
    )
    |> Repo.exists?()
  end

  def answered?(_profile, _account, _group, _alt, _collection), do: false

  # Counted in the database, so the limit holds over a reconnect and across nodes.
  defp outsider_at_limit?(%Profile{id: profile_id}, %Group{id: group_id}) do
    since = DateTime.add(DateTime.utc_now(), -60, :second)

    from(v in Value,
      where:
        v.group_id == ^group_id and v.is_data == true and not is_nil(v.collection) and
          v.creator_id == ^profile_id and v.inserted_at >= ^since,
      select: count()
    )
    |> Repo.one() >= @outsider_values_per_minute
  end

  @doc false
  def decode(data) when is_map(data), do: {:ok, data}

  def decode(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _invalid -> {:error, :invalid_value}
    end
  end

  def decode(_data), do: {:error, :invalid_value}

  defp fits(data, max) do
    if byte_size(Jason.encode!(data)) <= max, do: :ok, else: {:error, :too_large}
  end

  defp run_async(fun) do
    if Application.get_env(:potok_ide, :async_app_data, true) do
      {:ok, _pid} = Task.Supervisor.start_child(PotokIde.TaskSupervisor, fun)
      :ok
    else
      fun.()
    end
  end

  # What reached the database goes to the pages with the rule it was written
  # under, so each page decides without asking again.
  defp broadcast_value(%Group{} = group, event, %Value{} = value, rule) do
    broadcast(group, event, %{
      alt_id: value.alt_description_id,
      collection: value.collection,
      value: value,
      read: rule.read
    })
  end

  @doc false
  def broadcast(%Group{id: group_id}, event, payload) do
    PubSub.broadcast(PotokIde.PubSub, topic(group_id), {:app_value, group_id, event, payload})
  end
end
