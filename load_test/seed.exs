# Seeds a load-test population into the running release:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/seed.exs"); LoadTest.Seed.run(1000)'
#
# Rows go in with Repo.insert_all, so no broadcasts, emails or per-user password
# hashing happen. Every account gets a session token and a signed remember-me
# cookie (the same value AccountAuth would set), written to
# /load_test/results/users_<n>.csv for loadgen.exs.
defmodule LoadTest.Seed do
  alias PotokIde.Accounts.{Account, AccountToken}
  alias PotokIde.Repo

  alias PotokIde.Social.{
    AccountProfile,
    Group,
    GroupMemberRole,
    GroupMembership,
    GroupValueRead,
    Profile,
    Value
  }

  @password "load test password"
  @remember_me_cookie "_potok_ide_web_account_remember_me"
  @remember_me_max_age 14 * 24 * 60 * 60
  # Regular (non-direct) memberships per user, on average.
  @memberships_per_user 4
  @dms_per_user 3

  def run(n, out_dir \\ "/load_test/results") when is_integer(n) and n >= 10 do
    :rand.seed(:exsss, {17, 29, n})

    if Repo.aggregate(Account, :count) > 0 do
      raise "accounts table is not empty; seed a fresh database (run.sh --reseed)"
    end

    started = System.monotonic_time(:millisecond)
    root = PotokIde.Social.get_root_group!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    log("hashing the shared password")
    hashed_password = Pbkdf2.hash_pwd_salt(@password)

    log("accounts and profiles")
    account_ids = insert_accounts(n, hashed_password, now)
    profile_ids = insert_profiles(n, now)

    insert_rows(
      AccountProfile,
      Enum.zip_with(account_ids, profile_ids, &account_profile(&1, &2, now))
    )

    Repo.query!("""
    UPDATE accounts AS a
    SET current_profile_id = ap.profile_id, default_profile_id = ap.profile_id
    FROM accounts_profiles AS ap
    WHERE ap.account_id = a.id
    """)

    insert_rows(GroupMembership, Enum.map(profile_ids, &membership(root.id, &1, now)))

    log("groups")
    profiles = List.to_tuple(profile_ids)
    {big_group_id, regular} = insert_regular_groups(root, profile_ids, now)
    dms = insert_direct_groups(root, profiles, now)

    log("values")
    group_members = [{big_group_id, profile_ids} | regular] ++ dms
    latest = insert_values(group_members, big_group_id, dms, now)
    threads = insert_threads(regular, latest, now)

    log("read markers")
    insert_read_markers(group_members ++ threads, latest, now)

    log("session tokens and cookies")
    cookies = insert_session_tokens(account_ids, now)

    groups_by_profile = memberships_by_profile([{big_group_id, profile_ids} | regular])
    dms_by_profile = memberships_by_profile(dms)
    write_users(out_dir, n, profile_ids, cookies, groups_by_profile, dms_by_profile)

    meta = %{
      users: n,
      root_id: root.id,
      big_group_id: big_group_id,
      groups: length(regular) + 1,
      direct_groups: length(dms),
      threads: length(threads),
      values: Repo.aggregate(Value, :count),
      memberships: Repo.aggregate(GroupMembership, :count),
      password: @password,
      email_pattern: "load-<i>@potok.test"
    }

    File.write!(Path.join(out_dir, "users_#{n}.json"), Jason.encode!(meta, pretty: true))
    log("done in #{System.monotonic_time(:millisecond) - started} ms: #{inspect(meta)}")
    meta
  end

  defp insert_accounts(n, hashed_password, now) do
    rows =
      Enum.map(1..n, fn i ->
        %{
          email: "load-#{i}@potok.test",
          hashed_password: hashed_password,
          confirmed_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_rows(Account, rows, returning: [:id])
  end

  defp insert_profiles(n, now) do
    rows =
      Enum.map(1..n, fn i ->
        %{
          username: "lt#{i}",
          description: "Load test profile #{i}",
          description_format: :markdown,
          sharing: :unique,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_rows(Profile, rows, returning: [:id])
  end

  # One community-wide group with every user (the worst case for fan-out),
  # then Zipf-sized groups: a few with 10-20% of users, most with 3-30.
  # About 40% are nested under an earlier group (depth <= 3) and draw their
  # members from it.
  defp insert_regular_groups(root, profile_ids, now) do
    n = length(profile_ids)
    [big_group_id] = insert_groups([group_row("Opšta", root.id, hd(profile_ids), true, now)])
    insert_creator_rows(big_group_id, profile_ids, now)

    count = max(div(n, 10), 10)
    sizes = zipf_sizes(count, n)

    {regular, _nestable} =
      sizes
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {size, index}, {acc, nestable} ->
        {parent_id, pool, pool_size, depth} = pick_parent(nestable, root.id, profile_ids, n)
        members = Enum.take_random(pool, min(size, pool_size))
        public? = :rand.uniform() < 0.3
        [id] = insert_groups([group_row("Grupa #{index}", parent_id, hd(members), public?, now)])
        insert_creator_rows(id, members, now)

        nestable =
          if depth < 3 and length(members) >= 3,
            do: [{id, members, length(members), depth} | nestable],
            else: nestable

        {[{id, members} | acc], nestable}
      end)

    {big_group_id, Enum.reverse(regular)}
  end

  defp pick_parent(nestable, root_id, profile_ids, n) do
    if nestable != [] and :rand.uniform() < 0.4 do
      {id, members, size, depth} = Enum.random(nestable)
      {id, members, size, depth + 1}
    else
      {root_id, profile_ids, n, 1}
    end
  end

  defp zipf_sizes(count, n) do
    target = @memberships_per_user * n
    cap = max(div(n, 5), 3)
    sizes = fn c -> Enum.map(1..count, &(round(c / :math.pow(&1, 0.9)) |> max(3) |> min(cap))) end

    # Find the scale whose clamped sizes add up to about `target`.
    {lo, hi} =
      Enum.reduce(1..40, {0.0, n * 1.0}, fn _, {lo, hi} ->
        mid = (lo + hi) / 2
        if Enum.sum(sizes.(mid)) < target, do: {mid, hi}, else: {lo, mid}
      end)

    sizes.((lo + hi) / 2)
  end

  defp insert_direct_groups(root, profiles, now) do
    n = tuple_size(profiles)

    # Each direct group has two members, so n * dms / 2 pairs give each user ~dms.
    pairs =
      1..div(n * @dms_per_user, 2)
      |> Enum.reduce(MapSet.new(), fn _, acc ->
        i = :rand.uniform(n) - 1
        j = :rand.uniform(n) - 1
        if i == j, do: acc, else: MapSet.put(acc, {min(i, j), max(i, j)})
      end)
      |> Enum.map(fn {i, j} -> {elem(profiles, i), elem(profiles, j), i + 1, j + 1} end)

    pairs
    |> Enum.chunk_every(2_000)
    |> Enum.flat_map(fn chunk ->
      rows =
        Enum.map(chunk, fn {a, _b, ia, ib} ->
          [ia, ib]
          |> Enum.sort()
          |> Enum.map_join(" & ", &"lt#{&1}")
          |> group_row(root.id, a, false, now)
          |> Map.merge(%{is_direct: true, has_public_chat: true, home_page: :chat})
        end)

      ids = insert_groups(rows)

      Enum.zip_with(ids, chunk, fn id, {a, b, _ia, _ib} -> {id, [a, b]} end)
      |> tap(fn groups ->
        insert_rows(
          GroupMembership,
          Enum.flat_map(groups, fn {id, members} ->
            Enum.map(members, &membership(id, &1, now))
          end)
        )

        insert_rows(
          GroupMemberRole,
          Enum.map(groups, fn {id, [a, _]} -> admin_role(id, a, now) end)
        )
      end)
    end)
  end

  # Values are inserted oldest first across all groups, so ids grow with time
  # the way they do in production. Returns %{group_id => [value ids, oldest first]}.
  defp insert_values(group_members, big_group_id, dms, now) do
    dm_ids = MapSet.new(dms, &elem(&1, 0))

    messages =
      Enum.flat_map(group_members, fn {group_id, members} ->
        count =
          cond do
            group_id == big_group_id -> 300
            MapSet.member?(dm_ids, group_id) -> 10
            true -> 20 + :rand.uniform(80)
          end

        members = List.to_tuple(members)

        for k <- 1..count do
          {:rand.uniform(30 * 24 * 3600), group_id,
           elem(members, :rand.uniform(tuple_size(members)) - 1), k}
        end
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)

    messages
    |> Enum.chunk_every(4_000)
    |> Enum.reduce(%{}, fn chunk, acc ->
      rows =
        Enum.map(chunk, fn {age, group_id, creator_id, k} ->
          at = DateTime.add(now, -age, :second)

          %{
            content:
              "Poruka #{k} u grupi #{group_id}. Lorem ipsum dolor sit amet, **potok** test.",
            content_format: :markdown,
            is_data: false,
            mentions: %{},
            mentioned_profile_ids: [],
            creator_id: creator_id,
            group_id: group_id,
            inserted_at: at,
            updated_at: at
          }
        end)

      {_, returned} = Repo.insert_all(Value, rows, returning: [:id, :group_id])

      Enum.reduce(returned, acc, fn v, acc ->
        Map.update(acc, v.group_id, [v.id], &[v.id | &1])
      end)
    end)
    |> Map.new(fn {group_id, ids} -> {group_id, Enum.reverse(ids)} end)
  end

  # A few value threads (sub-groups started from a chat value) in mid-sized
  # groups; like Social.create_value_thread they copy the parent's members.
  defp insert_threads(regular, latest, now) do
    candidates =
      Enum.filter(regular, fn {id, members} -> length(members) in 10..500 and latest[id] end)

    count = min(length(candidates), max(div(length(regular), 20), 3))

    candidates
    |> Enum.take_random(count)
    |> Enum.map(fn {group_id, members} ->
      value_id = Enum.random(latest[group_id])

      [id] =
        insert_groups([
          group_row("Nit #{value_id}", group_id, hd(members), false, now)
          |> Map.merge(%{parent_value_id: value_id, home_page: :chat})
        ])

      insert_creator_rows(id, members, now)
      {id, members}
    end)
  end

  # 70% of members are caught up, 20% are behind, 10% never opened the group.
  defp insert_read_markers(group_members, latest, now) do
    rows =
      group_members
      |> Enum.flat_map(fn {group_id, members} ->
        ids = Map.get(latest, group_id, [])

        Enum.flat_map(members, fn profile_id ->
          roll = :rand.uniform()

          cond do
            ids == [] or roll > 0.9 ->
              []

            roll > 0.7 ->
              [read_marker(profile_id, group_id, Enum.at(ids, div(length(ids), 2)), now)]

            true ->
              [read_marker(profile_id, group_id, List.last(ids), now)]
          end
        end)
      end)

    insert_rows(GroupValueRead, rows)
  end

  defp insert_session_tokens(account_ids, now) do
    secret_key_base = PotokIdeWeb.Endpoint.config(:secret_key_base)
    tokens = Enum.map(account_ids, fn _ -> :crypto.strong_rand_bytes(32) end)

    rows =
      Enum.zip_with(account_ids, tokens, fn account_id, token ->
        %{
          token: token,
          context: "session",
          account_id: account_id,
          authenticated_at: now,
          inserted_at: now
        }
      end)

    insert_rows(AccountToken, rows)

    Enum.map(tokens, fn token ->
      Plug.Crypto.sign(secret_key_base, @remember_me_cookie <> "_cookie", token,
        keys: Plug.Keys,
        max_age: @remember_me_max_age
      )
    end)
  end

  defp write_users(out_dir, n, profile_ids, cookies, groups_by_profile, dms_by_profile) do
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, "users_#{n}.csv")

    lines =
      profile_ids
      |> Enum.with_index(1)
      |> Enum.zip_with(cookies, fn {profile_id, i}, cookie ->
        groups = groups_by_profile |> Map.get(profile_id, []) |> Enum.join(" ")
        dms = dms_by_profile |> Map.get(profile_id, []) |> Enum.join(" ")
        [Integer.to_string(profile_id), ",lt#{i},", cookie, ",", groups, ",", dms, "\n"]
      end)

    File.write!(path, ["profile_id,username,cookie,groups,dms\n" | lines])
  end

  defp memberships_by_profile(groups) do
    Enum.reduce(groups, %{}, fn {group_id, members}, acc ->
      Enum.reduce(members, acc, fn profile_id, acc ->
        Map.update(acc, profile_id, [group_id], &[group_id | &1])
      end)
    end)
  end

  defp insert_creator_rows(group_id, [creator | _] = members, now) do
    insert_rows(GroupMembership, Enum.map(members, &membership(group_id, &1, now)))
    insert_rows(GroupMemberRole, [admin_role(group_id, creator, now)])
  end

  defp insert_groups(rows) do
    {_, returned} = Repo.insert_all(Group, rows, returning: [:id])
    Enum.map(returned, & &1.id)
  end

  # Postgres allows 65_535 bind parameters per statement.
  defp insert_rows(schema, rows, opts \\ [])

  defp insert_rows(_schema, [], _opts), do: []

  defp insert_rows(schema, rows, opts) do
    per_row = rows |> hd() |> map_size()

    rows
    |> Enum.chunk_every(max(div(60_000, per_row), 1))
    |> Enum.flat_map(fn chunk ->
      case Repo.insert_all(schema, chunk, opts) do
        {_, nil} -> []
        {_, returned} -> Enum.map(returned, & &1.id)
      end
    end)
  end

  defp group_row(name, parent_id, creator_id, public?, now) do
    %{
      name: name,
      description: "",
      description_format: :markdown,
      home_page: :chat,
      has_public_chat: false,
      is_direct: false,
      is_public: public?,
      is_root: false,
      is_root_public: false,
      uses_api: false,
      creator_id: creator_id,
      parent_id: parent_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp account_profile(account_id, profile_id, now),
    do: %{account_id: account_id, profile_id: profile_id, inserted_at: now, updated_at: now}

  defp membership(group_id, profile_id, now),
    do: %{group_id: group_id, profile_id: profile_id, inserted_at: now, updated_at: now}

  defp admin_role(group_id, profile_id, now) do
    %{
      group_id: group_id,
      profile_id: profile_id,
      role_key: PotokIde.Social.GroupRole.admin_key(),
      inserted_at: now,
      updated_at: now
    }
  end

  defp read_marker(profile_id, group_id, value_id, now) do
    %{
      profile_id: profile_id,
      group_id: group_id,
      last_read_value_id: value_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp log(message), do: IO.puts("[seed] #{message}")
end
