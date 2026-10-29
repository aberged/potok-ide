defmodule PotokIde.Storage.S3 do
  @moduledoc """
  Files in an S3-compatible bucket: Tigris on Fly (`fly storage create`),
  Cloudflare R2 or AWS S3. Config keys: `:bucket`, `:endpoint`, `:region`,
  `:access_key_id`, `:secret_access_key`, `:virtual_host` (bucket in the host
  name instead of the path) and `:req_options` (tests plug in `Req.Test`).

  Browsers PUT files straight into the bucket with a presigned URL, so the
  bucket needs a CORS rule that allows `PUT` with a `content-type` header from
  the app's origin.
  """

  @behaviour PotokIde.Storage

  @put_expires 3600
  # Download links are signed as of the start of the hour and last two hours:
  # the same file gets the same URL for an hour, so browsers can cache it, and
  # every link handed out stays valid for at least an hour.
  @get_window 3600
  @get_expires 2 * @get_window

  @impl true
  def direct_upload?, do: true

  @doc """
  The signed headers must match what the browser sends: the uploader sets
  `content-type`, and the browser sets `content-length` from the file, so the
  bucket refuses a body of any other size.
  """
  @impl true
  def presign_put(key, content_type, byte_size) do
    {:ok,
     presign(:put, key,
       expires: @put_expires,
       headers: [{"content-type", content_type}, {"content-length", Integer.to_string(byte_size)}]
     )}
  end

  @impl true
  def put_file(key, source_path) do
    case request(:put, key, body: File.read!(source_path)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stat(key) do
    case request(:head, key) do
      {:ok, %Req.Response{status: 200} = response} ->
        with [length | _] <- Req.Response.get_header(response, "content-length"),
             {size, ""} <- Integer.parse(length) do
          {:ok, size}
        else
          _ -> {:error, :unknown_size}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case request(:delete, key) do
      {:ok, %Req.Response{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(key, filename, content_type, disposition) do
    now = DateTime.to_unix(DateTime.utc_now())

    {:redirect,
     presign(:get, key,
       expires: @get_expires,
       datetime: DateTime.from_unix!(now - rem(now, @get_window)),
       query: [
         {"response-content-disposition",
          PotokIde.Storage.content_disposition(disposition, filename)},
         {"response-content-type", content_type}
       ]
     )}
  end

  # Public for the signature test against AWS's published example.
  @doc false
  def presign(method, key, opts) do
    config = config()

    [
      method: method,
      url: object_url(config, key),
      service: :s3,
      region: config[:region],
      access_key_id: config[:access_key_id],
      secret_access_key: config[:secret_access_key],
      datetime: DateTime.utc_now()
    ]
    |> Keyword.merge(opts)
    |> Req.Utils.aws_sigv4_url()
    |> URI.to_string()
  end

  defp request(method, key, opts \\ []) do
    config = config()

    config
    |> Keyword.get(:req_options, [])
    |> Keyword.merge(
      method: method,
      url: object_url(config, key),
      aws_sigv4: [
        service: :s3,
        region: config[:region],
        access_key_id: config[:access_key_id],
        secret_access_key: config[:secret_access_key]
      ]
    )
    |> Keyword.merge(opts)
    |> Req.request()
  end

  defp object_url(config, key) do
    endpoint = URI.parse(config[:endpoint])
    bucket = config[:bucket]

    if config[:virtual_host] do
      URI.to_string(%{endpoint | host: "#{bucket}.#{endpoint.host}", path: "/#{key}"})
    else
      URI.to_string(%{endpoint | path: "/#{bucket}/#{key}"})
    end
  end

  defp config do
    PotokIde.Storage.config()
    |> Keyword.put_new(:region, "auto")
  end
end
