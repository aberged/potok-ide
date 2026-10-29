defmodule PotokIdeWeb.AttachmentController do
  use PotokIdeWeb, :controller

  alias PotokIde.Social
  alias PotokIde.Social.ValueAttachment
  alias PotokIde.Storage

  # A stored file never changes, so the browser may keep it for a while; it
  # is private to the account that asked for it.
  @cache_control "private, max-age=3600"

  def show(conn, %{"id" => id}) do
    profile = Social.get_account_current_profile(conn.assigns.current_scope.account)

    with {attachment_id, ""} <- Integer.parse(id),
         %ValueAttachment{} = attachment <-
           profile && Social.get_attachment_for_download(profile, attachment_id) do
      serve(conn, attachment)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Only raster images open in place; everything else (HTML, SVG, PDF...) is
  # downloaded, so a file never runs as a page of this origin.
  defp serve(conn, %ValueAttachment{} = attachment) do
    disposition = if ValueAttachment.image?(attachment), do: :inline, else: :attachment

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
        if File.regular?(path) do
          conn
          |> put_resp_content_type(attachment.content_type, nil)
          |> put_resp_header(
            "content-disposition",
            Storage.content_disposition(disposition, attachment.filename)
          )
          |> put_resp_header("cache-control", @cache_control)
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
          |> send_file(200, path)
        else
          send_resp(conn, 404, "")
        end

      {:error, _reason} ->
        send_resp(conn, 404, "")
    end
  end
end
