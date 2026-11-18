defmodule PotokIde.RateLimitTest do
  # The limits that keep others safe count in Postgres.
  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias PotokIde.{RateLimit, Repo}
  alias PotokIde.HostingCosts.Sampler
  alias PotokIde.Social.AppFileSweeper

  defp unique_id, do: {:test, System.unique_integer([:positive])}

  test "lets a window's attempts through, then refuses until it ends" do
    id = unique_id()
    {max, window_ms} = RateLimit.limit(:magic_link_email)

    for _ <- 1..max, do: assert(:ok = RateLimit.hit(:magic_link_email, id))

    assert {:error, :rate_limited, retry_after} = RateLimit.hit(:magic_link_email, id)
    assert retry_after > 0 and retry_after <= window_ms
  end

  test "check refuses a full window without counting" do
    id = unique_id()
    {max, _window_ms} = RateLimit.limit(:password_email)

    for _ <- 1..max, do: assert(:ok = RateLimit.check(:password_email, id))
    for _ <- 1..max, do: assert(:ok = RateLimit.hit(:password_email, id))

    assert {:error, :rate_limited, _retry_after} = RateLimit.check(:password_email, id)
  end

  test "counts each name and id apart" do
    id = unique_id()
    {max, _window_ms} = RateLimit.limit(:magic_link_email)

    for _ <- 1..max, do: RateLimit.hit(:magic_link_email, id)

    assert :ok = RateLimit.hit(:magic_link_email, unique_id())
    assert :ok = RateLimit.hit(:magic_link_ip, id)
  end

  test "a shared limit is one counter for every process and machine" do
    id = unique_id()
    {max, _window_ms} = RateLimit.limit(:magic_link_email)
    assert RateLimit.shared?(:magic_link_email)
    refute RateLimit.shared?(:value_search)

    # Each attempt from a process of its own, as from pages on other machines.
    for _ <- 1..max do
      assert :ok = Task.async(fn -> RateLimit.hit(:magic_link_email, id) end) |> Task.await()
    end

    assert {:error, :rate_limited, _retry_after} = RateLimit.hit(:magic_link_email, id)
  end

  test "the shared counters keep no address" do
    :ok = RateLimit.hit(:magic_link_email, "ana@example.com")

    keys = Repo.all(from(c in "rate_limit_counters", select: c.key))
    assert keys != []
    refute Enum.any?(keys, &String.contains?(&1, "ana@example.com"))
  end

  test "once? lets the first through in a window, the rest not" do
    assert RateLimit.once?(:app_file_sweep)
    refute RateLimit.once?(:app_file_sweep)
    assert RateLimit.once?(:hosting_costs_sample)
  end

  test "prune deletes the counters of windows that have ended" do
    :ok = RateLimit.hit(:magic_link_email, unique_id())
    :ok = RateLimit.hit(:magic_link_ip, unique_id())

    from(c in "rate_limit_counters", where: c.count == 1, limit: 1, select: c.key)
    |> Repo.one()
    |> then(fn key ->
      Repo.update_all(from(c in "rate_limit_counters", where: c.key == ^key),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )
    end)

    assert RateLimit.prune() == 1
    assert Repo.aggregate("rate_limit_counters", :count) == 1
  end

  test "the hourly sweep and the costs sample run on one machine in a window" do
    assert AppFileSweeper.pass() == :done
    assert AppFileSweeper.pass() == :skipped

    # Another machine asked Fly this quarter of an hour (no Fly in tests).
    assert RateLimit.once?(:hosting_costs_sample)
    assert Sampler.pass() == :skipped
  end

  test "keys an IPv6 client by its /64 network and an IPv4 one whole" do
    assert RateLimit.ip_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) ==
             RateLimit.ip_key({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9})

    refute RateLimit.ip_key({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}) ==
             RateLimit.ip_key({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1})

    assert RateLimit.ip_key({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201}) == {192, 0, 2, 1}
    refute RateLimit.ip_key({1, 2, 3, 4}) == RateLimit.ip_key({1, 2, 3, 4, 0, 0, 0, 0})
  end

  test "keys a typed address the same however it is written" do
    assert RateLimit.email_key("  Ana@Example.COM ") == "ana@example.com"
    assert RateLimit.email_key(nil) == ""
  end
end
