defmodule PotokIde.RateLimit do
  @moduledoc """
  Counts attempts in fixed windows, for what anyone can repeat without being
  a member of anything: password log-ins, sign-in links and the emails sent to
  an address someone types. Also for what scans many values and can be asked
  again and again: an app's counts and sums in its viewer's name, and
  searches of a group's messages.

  A limit that keeps something outside the machine safe (an inbox, a group's
  followers, OpenStreetMap, what an app writes, a process's steps) is counted
  in Postgres (`rate_limit_counters`), for all machines together, in windows
  by the wall clock. One that guards the machine's own processor (reads,
  searches, map views, tiles one client asks for) counts in
  `PotokIde.Cache`'s ETS table, each machine for itself.

  `once?/1` is a shared limit of one: the first machine in a window does a
  periodic job, the others leave it.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PotokIde.{Cache, Repo}

  # name => {attempts a window allows, window in milliseconds}
  @limits %{
    # Every password attempt from one IP.
    password_ip: {60, :timer.minutes(10)},
    # Failed password attempts on one email address.
    password_email: {20, :timer.minutes(15)},
    # Sign-in links asked for one typed address, with an account or not.
    magic_link_email: {5, :timer.minutes(15)},
    magic_link_ip: {20, :timer.hours(1)},
    # Invitation emails one account sends to new addresses.
    invitation_email: {50, :timer.hours(1)},
    # Emails to confirm a new address, per account.
    email_change: {10, :timer.hours(1)},
    # Links that delete an account (`/brisanje-naloga`), per typed address and
    # per IP, with an account or not.
    account_deletion_email: {3, :timer.hours(1)},
    account_deletion_ip: {10, :timer.hours(1)},
    # App counts and sums (`summarizeValues`, `aggregateValues`), per profile
    # on all its pages, or per page for a guest. Forma refreshes a summary at
    # most every two seconds, so four pages of it fit.
    app_heavy_read: {120, :timer.minutes(1)},
    # Places an app adds on a map (`createPlace`), per profile: each is a group.
    app_create_place: {20, :timer.hours(1)},
    # Calls of `createChildren`, per profile, each up to 100 groups: a year of
    # an open dataset (some 35,000 rows) fits in a fraction of it, a runaway
    # loop does not fill the database.
    app_create_children: {2_000, :timer.hours(1)},
    # Views of a big map app (`listPlaces` with a view, `listPlacesAt`), per
    # profile on all its pages, as for the root's map.
    app_map_view: {300, :timer.minutes(1)},
    # Every app call guests make from one address, on all their pages: what a
    # few people behind one address read (a house, a phone network), not a loop.
    app_guest_client: {600, :timer.minutes(1)},
    # Views of the root's map, per profile on all its pages: the map asks once
    # it stops moving, so even a busy minute asks a few dozen times.
    root_map_view: {300, :timer.minutes(1)},
    # Searches of a group's messages, per profile on all its pages: the box
    # asks 300 ms after the last key, so even fast typing asks a few a second.
    value_search: {60, :timer.minutes(1)},
    # Notices one group sends its followers, each a push to every follower's
    # devices: a busy day of a local community fits, a loop does not.
    group_notice: {10, :timer.hours(1)},
    # Map tiles one IP asks Potok for, kept or not: a fast pan over a big
    # screen asks for a few hundred a minute.
    tile_ip: {1200, :timer.minutes(1)},
    # Tiles all of Potok fetches from OpenStreetMap, whose policy forbids heavy use.
    tile_upstream: {600, :timer.minutes(1)},
    # Steps one app's process takes (`Processes.Engine`): a busy day of
    # requests fits, a graph that runs away waits for the next minute.
    process_step: {60, :timer.minutes(1)},
    # Runs one person starts of one process by hand (`Social.DrawnProcesses`).
    process_manual_start: {10, :timer.hours(1)},
    # Requests to join and for roles one account sends (`Social.GroupRequests`):
    # a vote one raises is a message to the whole group.
    group_request: {10, :timer.hours(1)},
    # Periodic jobs one machine of all does in a window (`once?/1`).
    app_file_sweep: {1, :timer.hours(1)},
    hosting_costs_sample: {1, :timer.minutes(15)}
  }

  # Counted in Postgres, for all machines together.
  @shared [
    :password_ip,
    :password_email,
    :magic_link_email,
    :magic_link_ip,
    :invitation_email,
    :email_change,
    :account_deletion_email,
    :account_deletion_ip,
    :group_notice,
    :process_step,
    :process_manual_start,
    :group_request,
    :app_create_place,
    :app_create_children,
    :tile_upstream,
    :app_file_sweep,
    :hosting_costs_sample
  ]

  @type name ::
          :password_ip
          | :password_email
          | :magic_link_email
          | :magic_link_ip
          | :invitation_email
          | :email_change
          | :account_deletion_email
          | :account_deletion_ip
          | :app_heavy_read
          | :app_create_place
          | :app_create_children
          | :app_map_view
          | :app_guest_client
          | :root_map_view
          | :value_search
          | :group_notice
          | :tile_ip
          | :tile_upstream
          | :process_step
          | :process_manual_start
          | :group_request
          | :app_file_sweep
          | :hosting_costs_sample

  @type result :: :ok | {:error, :rate_limited, pos_integer()}

  @doc "The attempts a window of `name` allows and the window's length in milliseconds."
  @spec limit(name()) :: {pos_integer(), pos_integer()}
  def limit(name), do: Map.fetch!(@limits, name)

  @doc """
  Counts an attempt of `id` under `name`. Returns `{:error, :rate_limited,
  retry_after_ms}` once the window holds more attempts than it allows.
  """
  @spec hit(name(), term()) :: result()
  def hit(name, id) do
    {max, window_ms} = limit(name)

    {count, retry_after} =
      if shared?(name) do
        {key, slot, retry_after} = shared_window(name, id, window_ms)

        %Postgrex.Result{rows: [[count]]} =
          Repo.query!(
            """
            INSERT INTO rate_limit_counters AS c (key, slot, count, expires_at)
            VALUES ($1, $2, 1, now() + make_interval(secs => $3::float8 / 1000))
            ON CONFLICT (key, slot) DO UPDATE SET count = c.count + 1
            RETURNING c.count
            """,
            [key, slot, retry_after]
          )

        {count, retry_after}
      else
        {key, retry_after} = window(name, id, window_ms)
        {Cache.increment(key, retry_after), retry_after}
      end

    if count <= max, do: :ok, else: limited(name, retry_after)
  end

  @doc """
  Like `hit/2` without counting: refuses when the window is already full.
  For limits that count only failures, which call `hit/2` after one.
  """
  @spec check(name(), term()) :: result()
  def check(name, id) do
    {max, window_ms} = limit(name)

    {count, retry_after} =
      if shared?(name) do
        {key, slot, retry_after} = shared_window(name, id, window_ms)

        count =
          Repo.one(
            from(c in "rate_limit_counters",
              where: c.key == ^key and c.slot == ^slot,
              select: c.count
            )
          )

        {count, retry_after}
      else
        {key, retry_after} = window(name, id, window_ms)

        case Cache.get(key) do
          {:ok, count} -> {count, retry_after}
          :error -> {nil, retry_after}
        end
      end

    if is_integer(count) and count >= max, do: limited(name, retry_after), else: :ok
  end

  @doc """
  Whether this machine is the first of all in the window of `name` (one of
  the periodic jobs in `@limits`): it does the job, the others leave it.
  """
  @spec once?(name()) :: boolean()
  def once?(name) do
    {1, _window_ms} = limit(name)
    hit(name, :cluster) == :ok
  end

  @doc "Deletes the shared counters of windows that have ended."
  def prune do
    {deleted, _} =
      Repo.delete_all(from(c in "rate_limit_counters", where: c.expires_at < fragment("now()")))

    deleted
  end

  @doc "Whether `name` is counted in Postgres, for all machines together."
  def shared?(name), do: name in @shared

  @doc """
  The key of a client's IP. An IPv6 client is counted by its /64 network,
  which one home or phone gets whole and can move around in.
  """
  def ip_key({_, _, _, _} = ip), do: ip

  def ip_key({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  def ip_key({a, b, c, d, _, _, _, _}), do: {:v6, a, b, c, d}

  @doc "The key of a typed email address."
  def email_key(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase() |> String.slice(0, 320)

  def email_key(_email), do: ""

  # A shared window: by the wall clock, which all machines agree on, and a
  # hash in place of what is counted, so the table keeps no address or IP.
  defp shared_window(name, id, window_ms) do
    now = System.system_time(:millisecond)
    slot = Integer.floor_div(now, window_ms)
    key = :crypto.hash(:sha256, :erlang.term_to_binary({name, id}, [:deterministic]))
    {key, slot, (slot + 1) * window_ms - now}
  end

  # A window has a key of its own, so a counter never outlives its window.
  defp window(name, id, window_ms) do
    now = System.monotonic_time(:millisecond)
    window = Integer.floor_div(now, window_ms)
    {{:rate_limit, name, id, window}, (window + 1) * window_ms - now}
  end

  defp limited(name, retry_after) do
    Logger.info("rate limited: #{name}")
    {:error, :rate_limited, retry_after}
  end
end
