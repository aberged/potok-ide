defmodule PotokIde.RateLimitTest do
  use ExUnit.Case, async: true

  alias PotokIde.RateLimit

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
