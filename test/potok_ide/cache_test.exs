defmodule PotokIde.CacheTest do
  use ExUnit.Case, async: true

  alias PotokIde.Cache

  test "concurrent misses of one key compute it once" do
    key = {:cache_test, System.unique_integer()}
    test_pid = self()

    compute = fn ->
      send(test_pid, {:computing, self()})
      receive do: (:go -> :value)
    end

    callers = for _caller <- 1..5, do: Task.async(fn -> Cache.fetch(key, :infinity, compute) end)

    assert_receive {:computing, computing_pid}
    await_waiters(key, 4)
    send(computing_pid, :go)

    assert Enum.map(callers, &Task.await/1) == List.duplicate(:value, 5)
    refute_received {:computing, _other_pid}
  end

  test "a waiter computes the value itself when the computing caller dies" do
    key = {:cache_test, System.unique_integer()}
    test_pid = self()

    first =
      spawn(fn ->
        Cache.fetch(key, :infinity, fn ->
          send(test_pid, {:computing, self()})
          receive do: (:never -> :first)
        end)
      end)

    assert_receive {:computing, ^first}
    waiter = Task.async(fn -> Cache.fetch(key, :infinity, fn -> :from_waiter end) end)
    await_waiters(key, 1)

    Process.exit(first, :kill)

    assert Task.await(waiter) == :from_waiter
    assert Cache.get(key) == {:ok, :from_waiter}
  end

  # The callers send their claims concurrently; each `:sys.get_state/1` round
  # trip lets more of them reach the cache process.
  defp await_waiters(key, count, attempts \\ 500) do
    waiting =
      case :sys.get_state(Cache).computing do
        %{^key => {_pid, _ref, waiters}} -> length(waiters)
        _ -> 0
      end

    cond do
      waiting >= count ->
        :ok

      attempts == 0 ->
        flunk("expected #{count} callers waiting on #{inspect(key)}, got #{waiting}")

      true ->
        await_waiters(key, count, attempts - 1)
    end
  end
end
