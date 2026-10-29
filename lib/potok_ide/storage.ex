defmodule PotokIde.Storage do
  @moduledoc """
  Where the files attached to values live. The adapter comes from config:

    * `PotokIde.Storage.Local` keeps files on disk (dev, test). Browsers
      upload through the LiveView channel.
    * `PotokIde.Storage.S3` keeps them in an S3-compatible bucket (Tigris on
      Fly, Cloudflare R2, AWS S3). Browsers upload straight to the bucket with
      a presigned PUT and download through a short-lived presigned GET.

  Without an adapter attachments are off and the composer has no file button.
  """

  require Logger

  @type key :: String.t()

  @callback direct_upload?() :: boolean()
  @callback presign_put(key, content_type :: String.t(), byte_size :: non_neg_integer()) ::
              {:ok, String.t()} | {:error, term()}
  @callback put_file(key, source_path :: Path.t()) :: :ok | {:error, term()}
  @callback stat(key) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback delete(key) :: :ok | {:error, term()}
  @callback download(
              key,
              filename :: String.t(),
              content_type :: String.t(),
              :inline | :attachment
            ) ::
              {:redirect, String.t()} | {:file, Path.t()}

  @key_format ~r/\Ag\d+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def config, do: Application.get_env(:potok_ide, __MODULE__, [])

  def adapter, do: config()[:adapter]

  def enabled?, do: adapter() != nil

  @doc "True when browsers upload straight to the storage instead of the LiveView channel."
  def direct_upload?, do: enabled?() and adapter().direct_upload?()

  def max_files, do: Keyword.get(config(), :max_files, 10)

  def max_file_size, do: Keyword.get(config(), :max_file_size, 100_000_000)

  @doc "A fresh key for a file of the group's value: `g<group id>/<uuid>`."
  def new_key(group_id) when is_integer(group_id), do: "g#{group_id}/#{Ecto.UUID.generate()}"

  @doc "Keys are only ever made by `new_key/1`; anything else is refused."
  def valid_key?(key) when is_binary(key), do: Regex.match?(@key_format, key)
  def valid_key?(_key), do: false

  def presign_put(key, content_type, byte_size),
    do: with_key(key, &adapter().presign_put(&1, content_type, byte_size))

  def put_file(key, source_path), do: with_key(key, &adapter().put_file(&1, source_path))

  def stat(key), do: with_key(key, &adapter().stat/1)

  def delete(key), do: with_key(key, &adapter().delete/1)

  def download(key, filename, content_type, disposition),
    do: with_key(key, &adapter().download(&1, filename, content_type, disposition))

  @doc """
  Deletes stored files once the rows that named them are gone. Runs off the
  caller unless `:async_storage_cleanup` is false (tests); failures are only
  logged, the files are unreachable either way.
  """
  def delete_later([]), do: :ok

  def delete_later(keys) when is_list(keys) do
    if enabled?() do
      cleanup = fn -> Enum.each(keys, &delete_logged/1) end

      if Application.get_env(:potok_ide, :async_storage_cleanup, true) do
        {:ok, _pid} = Task.Supervisor.start_child(PotokIde.TaskSupervisor, cleanup)
      else
        cleanup.()
      end
    end

    :ok
  end

  @doc """
  `Content-Disposition` with an ASCII fallback name and the full UTF-8 name
  (RFC 6266), safe to send as a header or a signed S3 query parameter.
  """
  def content_disposition(disposition, filename) when disposition in [:inline, :attachment] do
    ascii =
      filename
      |> String.normalize(:nfd)
      |> String.replace(~r/[^\x20-\x7E]|["\\]/u, "")
      |> String.trim()
      |> case do
        "" -> "file"
        name -> name
      end

    "#{disposition}; filename=\"#{ascii}\"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)}"
  end

  defp delete_logged(key) do
    case delete(key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not delete stored file #{key}: #{inspect(reason)}")
    end
  end

  defp with_key(key, fun) do
    cond do
      not enabled?() -> {:error, :storage_disabled}
      not valid_key?(key) -> {:error, :invalid_key}
      true -> fun.(key)
    end
  end
end
