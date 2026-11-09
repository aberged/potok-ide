defmodule PotokIde.RenderCache do
  @moduledoc """
  Drawn pictures (link cards, PNG avatars) kept as files, so they stay out of
  the VM's memory and survive a restart; a deploy starts with an empty disk.

  `fetch/4` reads a file younger than `max_age`; otherwise it computes the
  picture once, however many callers ask at the same moment
  (`PotokIde.Cache` lets one compute while the others wait), and writes it.
  Only a picture (`{:ok, binary}`) is written. Anything else the function
  returns, a failure or a partial card, is remembered in memory for
  `:memory_ttl`, so a broken picture is not redrawn for every request.

  Files older than a week are removed now and then while writing. Tests
  turn the disk off (`dir: false`), and pictures then stay in memory.
  """

  require Logger

  alias PotokIde.Cache

  @memory_ttl :timer.minutes(5)
  @sweep_age :timer.hours(24 * 7)
  # About one write in this many also removes old files.
  @sweep_every 64

  @doc """
  The picture for `key`: `{:ok, binary}`, or whatever `fun` returned instead.
  `fun` returns `{:ok, binary}` for a picture to keep.

  Options: `:memory_ttl` (ms) and `:dir`, which defaults to the configured one.
  """
  def fetch(key, max_age, fun, opts \\ []) when is_function(fun, 0) do
    path = path(key, Keyword.get_lazy(opts, :dir, &dir/0))

    case read(path, max_age) do
      {:ok, binary} ->
        {:ok, binary}

      :miss ->
        {__MODULE__, key}
        |> Cache.fetch(Keyword.get(opts, :memory_ttl, @memory_ttl), fn -> compute(fun, path) end)
        |> unpack(path)
    end
  end

  defp compute(fun, path) do
    case fun.() do
      {:ok, binary} = picture when is_binary(binary) ->
        # In memory only what could not be written.
        if write(path, binary) == :ok, do: :written, else: picture

      other ->
        other
    end
  end

  defp unpack(:written, path) do
    case path && File.read(path) do
      {:ok, binary} -> {:ok, binary}
      _gone -> :error
    end
  end

  defp unpack(other, _path), do: other

  defp read(nil, _max_age), do: :miss

  defp read(path, max_age) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- System.os_time(:second) - mtime < div(max_age, 1000),
         {:ok, binary} <- File.read(path) do
      {:ok, binary}
    else
      _ -> :miss
    end
  end

  defp write(nil, _binary), do: :error

  defp write(path, binary) do
    dir = Path.dirname(path)
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(temporary, binary),
         :ok <- File.rename(temporary, path) do
      if :rand.uniform(@sweep_every) == 1, do: sweep(dir)
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        Logger.warning("Could not keep a drawn picture: #{inspect(reason)}")
        :error
    end
  end

  defp sweep(dir) do
    oldest = System.os_time(:second) - div(@sweep_age, 1000)

    for name <- File.ls!(dir),
        file = Path.join(dir, name),
        match?({:ok, %File.Stat{mtime: mtime}} when mtime < oldest, File.stat(file, time: :posix)) do
      File.rm(file)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp path(_key, false), do: nil
  defp path(_key, nil), do: nil

  defp path(key, dir) do
    name =
      :sha256 |> :crypto.hash(:erlang.term_to_binary(key)) |> Base.url_encode64(padding: false)

    Path.join(dir, name)
  end

  defp dir do
    case Application.get_env(:potok_ide, __MODULE__, [])[:dir] do
      nil -> Path.join(System.tmp_dir!(), "potok-renders")
      dir -> dir
    end
  end
end
