defmodule PotokIde.Storage.Local do
  @moduledoc """
  Files on the local disk under the configured `:root`. Uploads come through
  the LiveView channel and downloads are sent by the app. Keys are checked by
  `PotokIde.Storage` before they get here, so they cannot leave the root.
  """

  @behaviour PotokIde.Storage

  @impl true
  def direct_upload?, do: false

  @impl true
  def presign_put(_key, _content_type, _byte_size), do: {:error, :not_supported}

  @impl true
  def put_file(key, source_path) do
    path = path(key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _bytes} <- File.copy(source_path, path) do
      :ok
    end
  end

  @impl true
  def stat(key) do
    case File.stat(path(key)) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, _stat} -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(key, _filename, _content_type, _disposition), do: {:file, path(key)}

  defp path(key), do: Path.join(root(), key)

  defp root do
    PotokIde.Storage.config()
    |> Keyword.fetch!(:root)
    |> Path.expand()
  end
end
