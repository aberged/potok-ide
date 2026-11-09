defmodule PotokIde.RateLimit do
  @moduledoc """
  Counts attempts in fixed windows, for what anyone can repeat without being
  a member of anything: password log-ins, sign-in links and the emails sent to
  an address someone types. Also for what an app can repeat in its viewer's
  name and that scans every value it keeps: counts and sums.

  The counters live in `PotokIde.Cache`'s ETS table, so each machine counts for
  itself: with N machines a limit lets through up to N times as much.
  Production runs one machine.
  """

  require Logger

  alias PotokIde.Cache

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
    # App counts and sums (`summarizeValues`, `aggregateValues`), per profile
    # on all its pages, or per page for a guest. Forma refreshes a summary at
    # most every two seconds, so four pages of it fit.
    app_heavy_read: {120, :timer.minutes(1)}
  }

  @type name ::
          :password_ip
          | :password_email
          | :magic_link_email
          | :magic_link_ip
          | :invitation_email
          | :email_change
          | :app_heavy_read

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
    {key, retry_after} = window(name, id, window_ms)

    if Cache.increment(key, retry_after) <= max,
      do: :ok,
      else: limited(name, retry_after)
  end

  @doc """
  Like `hit/2` without counting: refuses when the window is already full.
  For limits that count only failures, which call `hit/2` after one.
  """
  @spec check(name(), term()) :: result()
  def check(name, id) do
    {max, window_ms} = limit(name)
    {key, retry_after} = window(name, id, window_ms)

    case Cache.get(key) do
      {:ok, count} when count >= max -> limited(name, retry_after)
      _ -> :ok
    end
  end

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
