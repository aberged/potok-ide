defmodule PotokIdeWeb.AttachmentController do
  use PotokIdeWeb, :controller

  alias PotokIde.Social
  alias PotokIde.Social.ValueAttachment
  alias PotokIde.Storage

  # A stored file never changes, so the browser may keep it for a while; it
  # is private to the account that asked for it.
  @cache_control "private, max-age=3600"

  def show(conn, %{"id" => id} = params) do
    profile = Social.get_account_current_profile(conn.assigns.current_scope.account)

    with {attachment_id, ""} <- Integer.parse(id),
         %ValueAttachment{} = attachment <-
           profile && Social.get_attachment_for_download(profile, attachment_id) do
      serve(conn, attachment, disposition(attachment, params))
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Only images, audio and video open in place; everything else (HTML, SVG,
  # PDF...) is downloaded, so a file never runs as a page of this origin.
  # `?download=1` downloads any file, since the `download` attribute does not
  # survive the redirect to a bucket.
  defp disposition(attachment, params) do
    if ValueAttachment.previewable?(attachment) and !Map.has_key?(params, "download"),
      do: :inline,
      else: :attachment
  end

  defp serve(conn, %ValueAttachment{} = attachment, disposition) do
    case Storage.download(
           attachment.storage_key,
           attachment.filename,
           attachment.content_type,
           disposition
         ) do
      {:redirect, url} ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> redirect(external: url)

      {:file, path} ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :regular, size: size}} ->
            conn
            |> put_resp_content_type(attachment.content_type, nil)
            |> put_resp_header(
              "content-disposition",
              Storage.content_disposition(disposition, attachment.filename)
            )
            |> put_resp_header("cache-control", @cache_control)
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
            |> put_resp_header("accept-ranges", "bytes")
            |> send_range(path, size)

          _ ->
            send_resp(conn, 404, "")
        end

      {:error, _reason} ->
        send_resp(conn, 404, "")
    end
  end

  # Buckets answer range requests themselves; files on disk need it here, or
  # Safari will not play a video and other browsers cannot seek.
  defp send_range(conn, path, size) do
    case byte_range(get_req_header(conn, "range"), size) do
      :full ->
        send_file(conn, 200, path)

      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :invalid ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # One range of `bytes=first-last`, `bytes=first-` or `bytes=-suffix`; any
  # other or malformed header gets the whole file, as RFC 9110 allows.
  defp byte_range(["bytes=" <> spec], size) do
    case Regex.run(~r/\A\s*(\d*)-(\d*)\s*\z/, spec, capture: :all_but_first) do
      ["", ""] -> :full
      ["", suffix] -> suffix_range(String.to_integer(suffix), size)
      [first, last] -> bounded_range(String.to_integer(first), last, size)
      nil -> :full
    end
  end

  defp byte_range(_header, _size), do: :full

  defp suffix_range(0, _size), do: :invalid
  defp suffix_range(_suffix, 0), do: :invalid
  defp suffix_range(suffix, size), do: {max(size - suffix, 0), size - 1}

  defp bounded_range(first, _last, size) when first >= size, do: :invalid

  defp bounded_range(first, "", size), do: {first, size - 1}

  defp bounded_range(first, last, size) do
    case String.to_integer(last) do
      last when last < first -> :full
      last -> {first, min(last, size - 1)}
    end
  end
end
