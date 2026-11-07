defmodule PotokIdeWeb.PollExportController do
  use PotokIdeWeb, :controller

  alias PotokIde.Polls
  alias PotokIde.Polls.{Export, Poll, View}
  alias PotokIde.Social
  alias PotokIdeWeb.Locale

  # The results of a poll as a file, or its voters, for those its rules show them.
  def show(conn, %{"id" => id} = params) do
    conn = Locale.put_locale(conn, [])
    account = conn.assigns.current_scope.account
    profile = Social.get_account_current_profile(account)

    with {poll_id, ""} <- Integer.parse(id),
         true <- not is_nil(profile),
         %Poll{} = poll <- Polls.get_poll(poll_id),
         %View{scope: :full} = view <- Polls.view_of(poll, profile, account),
         {:ok, body} <- render_part(params["part"], poll, view, separator(conn)) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="poll-#{poll.id}-#{part_name(params["part"])}.csv")
      )
      |> put_resp_header("cache-control", "private, no-cache")
      |> send_resp(200, body)
    else
      _hidden_or_gone -> send_resp(conn, 404, "")
    end
  end

  defp render_part("voters", %Poll{} = poll, %View{details?: true}, separator),
    do: {:ok, Export.voters(poll, poll.group, separator)}

  defp render_part("results", %Poll{} = poll, %View{results?: true}, separator),
    do: {:ok, Export.results(poll, separator)}

  defp render_part(_part, _poll, _view, _separator), do: :error

  defp part_name("voters"), do: "voters"
  defp part_name(_results), do: "results"

  # Excel splits a file on the list separator of the machine's language.
  defp separator(conn) do
    if conn.assigns.current_locale == "en", do: ",", else: ";"
  end
end
