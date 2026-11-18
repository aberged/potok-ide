defmodule PotokIde.Cache.BoundedTest do
  @moduledoc """
  The cache with two generations: it holds at most twice its size, keeps
  what is still read, and never makes a caller wait for its owner.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Cache.Bounded

  setup do
    name = :"bounded_test_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Bounded, name: name, max_entries: 3})
    %{cache: name, pid: pid}
  end

  # The owner rotates on a message: past it, the generations stand.
  defp settled(pid), do: _ = :sys.get_state(pid)

  test "holds at most two generations of its size", %{cache: cache, pid: pid} do
    for n <- 1..10 do
      Bounded.put(cache, n, n)
      settled(pid)
    end

    assert Bounded.info(cache).entries <= 6
    assert {:ok, 10} = Bounded.get(cache, 10)
    assert Bounded.get(cache, 1) == :error
  end

  test "an entry read from the previous generation stays", %{cache: cache, pid: pid} do
    for key <- [:a, :b, :c], do: Bounded.put(cache, key, key)
    settled(pid)

    # :a moves to the current generation; :b stays in the previous one.
    assert {:ok, :a} = Bounded.get(cache, :a)

    for key <- [:d, :e], do: Bounded.put(cache, key, key)
    settled(pid)

    assert {:ok, :a} = Bounded.get(cache, :a)
    assert Bounded.get(cache, :b) == :error
  end

  test "an expired entry is missing", %{cache: cache} do
    Bounded.put(cache, :soon, 1, 0)
    assert Bounded.get(cache, :soon) == :error
    assert Bounded.fetch(cache, :soon, :infinity, fn -> 2 end) == 2
    assert {:ok, 2} = Bounded.get(cache, :soon)
  end

  test "a miss computes while the owner is busy", %{cache: cache, pid: pid} do
    :sys.suspend(pid)

    try do
      assert Bounded.fetch(cache, :key, :infinity, fn -> :computed end) == :computed
      assert {:ok, :computed} = Bounded.get(cache, :key)
    after
      :sys.resume(pid)
    end
  end

  test "deletes a key from both generations", %{cache: cache, pid: pid} do
    for key <- [:a, :b, :c], do: Bounded.put(cache, key, key)
    settled(pid)
    Bounded.put(cache, :d, :d)

    Bounded.delete(cache, :a)
    Bounded.delete(cache, :d)

    assert Bounded.get(cache, :a) == :error
    assert Bounded.get(cache, :d) == :error
    assert {:ok, :b} = Bounded.get(cache, :b)
  end
end
