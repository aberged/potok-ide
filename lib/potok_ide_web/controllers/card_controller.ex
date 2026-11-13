defmodule PotokIdeWeb.CardController do
  @moduledoc """
  The pictures of link cards (`PotokIde.LinkCards`), which sites and apps fetch
  without any session. Only what guests can see has one: the rest answers like
  an address that does not exist, even if its picture is still in the cache.
  """

  use PotokIdeWeb, :controller

  alias PotokIde.Events
  alias PotokIde.Events.Event
  alias PotokIde.LinkCards
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIdeWeb.PublicPreview

  # The address changes with the picture.
  @forever "public, max-age=31536000, immutable"
  # A card without its picture, or without its own look: sites should ask again.
  @for_now "public, max-age=300"

  def group(conn, %{"file" => file}) do
    with id when is_integer(id) <- parse_file(file),
         %Group{} = group <- Social.get_public_group(id) do
      group |> LinkCards.group_card() |> serve(conn)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # The card of a group as a link into an app names it, with the app's pill:
  # checked again on every request (`PublicPreview.linked_groups/2`), so it
  # goes with the link's card when either group closes or moves.
  def linked(conn, %{"app_id" => app_id, "file" => file}) do
    case PublicPreview.linked_groups(app_id, String.replace_suffix(file, ".jpg", "")) do
      {app, group} -> group |> LinkCards.linked_card(app) |> serve(conn)
      nil -> send_resp(conn, 404, "")
    end
  end

  def event(conn, %{"file" => file}) do
    with id when is_integer(id) <- parse_file(file),
         %Event{} = event <- Events.get_public_event(id) do
      event |> LinkCards.event_card() |> serve(conn)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp parse_file(file), do: file |> String.replace_suffix(".jpg", "") |> PublicPreview.parse_id()

  defp serve(card, conn) do
    case LinkCards.image(card) do
      {:ok, jpeg, :whole} -> send_jpeg(conn, jpeg, @forever)
      {:ok, jpeg, :partial} -> send_jpeg(conn, jpeg, @for_now)
      :error -> send_potok_picture(conn)
    end
  end

  defp send_jpeg(conn, jpeg, cache_control) do
    conn
    |> put_resp_content_type("image/jpeg", nil)
    |> put_resp_header("cache-control", cache_control)
    |> send_resp(200, jpeg)
  end

  defp send_potok_picture(conn) do
    conn
    |> put_resp_content_type("image/png", nil)
    |> put_resp_header("cache-control", @for_now)
    |> send_file(200, Application.app_dir(:potok_ide, "priv/static/images/og.png"))
  end
end
