defmodule PotokIde.RenderCacheTest do
  use ExUnit.Case, async: true

  alias PotokIde.RenderCache

  @hour :timer.hours(1)

  setup do
    dir = Path.join(System.tmp_dir!(), "render_cache_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp key, do: {:render_cache_test, System.unique_integer([:positive])}

  defp counting(test, result) do
    fn ->
      send(test, :computed)
      result
    end
  end

  test "a picture is written once and then read from disk", %{dir: dir} do
    key = key()

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "png"}), dir: dir) == {:ok, "png"}
    assert_received :computed
    assert [_file] = File.ls!(dir)

    # Gone from memory, as after the memory entry expires or a restart.
    PotokIde.Cache.delete({RenderCache, key})

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "other"}), dir: dir) ==
             {:ok, "png"}

    refute_received :computed
  end

  test "a file older than max_age is drawn again", %{dir: dir} do
    key = key()
    RenderCache.fetch(key, @hour, fn -> {:ok, "old"} end, dir: dir)
    [file] = File.ls!(dir)
    old = System.os_time(:second) - 7_200
    File.touch!(Path.join(dir, file), old)
    PotokIde.Cache.delete({RenderCache, key})

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "new"}), dir: dir) == {:ok, "new"}
    assert_received :computed
  end

  test "a failure is not written and is remembered in memory only", %{dir: dir} do
    key = key()

    assert RenderCache.fetch(key, @hour, counting(self(), :error), dir: dir) == :error
    assert_received :computed
    refute File.exists?(dir) and File.ls!(dir) != []

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "png"}), dir: dir) == :error
    refute_received :computed
  end

  test "with the disk off, pictures stay in memory" do
    key = key()

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "png"}), dir: false) ==
             {:ok, "png"}

    assert RenderCache.fetch(key, @hour, counting(self(), {:ok, "x"}), dir: false) == {:ok, "png"}
    assert_received :computed
    refute_received :computed
  end

  test "callers asking at once draw it once", %{dir: dir} do
    key = key()
    test = self()

    slow = fn ->
      send(test, :computed)
      Process.sleep(100)
      {:ok, "png"}
    end

    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> RenderCache.fetch(key, @hour, slow, dir: dir) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.uniq(results) == [{:ok, "png"}]
    assert_received :computed
    refute_received :computed
  end
end
