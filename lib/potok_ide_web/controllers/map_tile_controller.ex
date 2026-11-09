defmodule PotokIdeWeb.MapTileController do
  @moduledoc """
  Map tiles for the maps in apps and in a group's settings, passed on from
  OpenStreetMap (`PotokIde.MapTiles`). Like avatars, they need no session: an
  app's frame sends none.
  """
  use PotokIdeWeb, :controller

  alias PotokIde.{MapTiles, RateLimit}

  @cache_control "public, max-age=604800"
  # A tile is only ever shown as an image (as in `AvatarController`).
  @image_csp "default-src 'none'; style-src 'unsafe-inline'; sandbox"

  def show(conn, %{"z" => z, "x" => x, "y" => y}) do
    with {:ok, z, x, y} <- parse(z, x, y),
         :ok <- RateLimit.hit(:tile_ip, RateLimit.ip_key(conn.remote_ip)) do
      case MapTiles.fetch(z, x, y) do
        {:ok, png} ->
          conn
          |> put_resp_content_type("image/png", nil)
          |> put_resp_header("cache-control", @cache_control)
          |> put_resp_header("content-security-policy", @image_csp)
          |> put_resp_header("access-control-allow-origin", "*")
          |> send_resp(200, png)

        :error ->
          conn
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(502, "")
      end
    else
      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after, 1000) + 1))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(429, "")

      :error ->
        send_resp(conn, 404, "")
    end
  end

  defp parse(z, x, y) do
    with {z, ""} <- Integer.parse(z),
         {x, ""} <- Integer.parse(x),
         {y, ".png"} <- Integer.parse(y),
         true <- MapTiles.valid?(z, x, y) do
      {:ok, z, x, y}
    else
      _ -> :error
    end
  end
end
