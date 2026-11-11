defmodule PotokIdeWeb.EventIcsController do
  use PotokIdeWeb, :controller

  alias PotokIde.Events
  alias PotokIde.Events.ICS
  alias PotokIde.Social

  # The calendar file of an event, for members of its group, with its place
  # on a map as this profile may see it.
  def show(conn, %{"id" => id}) do
    profile = Social.get_account_current_profile(conn.assigns.current_scope.account)

    with {event_id, ""} <- Integer.parse(id),
         {:ok, event} <- if(profile, do: Events.get_event(profile, event_id), else: :error) do
      place = Events.place(profile, event)

      body =
        ICS.render(event,
          host: conn.host,
          url: url(~p"/groups/#{event.group_id}/calendar?event=#{event.id}"),
          geo: place && {place.lat, place.lng}
        )

      conn
      |> put_resp_content_type("text/calendar")
      |> put_resp_header("content-disposition", ~s(attachment; filename="event-#{event.id}.ics"))
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
