defmodule PotokIdeWeb.LocaleController do
  use PotokIdeWeb, :controller

  alias PotokIdeWeb.Locale

  def update(conn, %{"locale" => locale}) do
    locale = Locale.normalize_locale(locale) || Locale.default_locale()

    Gettext.put_locale(PotokIdeWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> redirect(to: redirect_path(conn))
  end

  defp redirect_path(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] ->
        referer
        |> URI.parse()
        |> local_path(conn.host)

      _ ->
        ~p"/"
    end
  end

  defp local_path(%URI{host: nil, path: path, query: query}, _host), do: with_query(path, query)

  defp local_path(%URI{host: host, path: path, query: query}, host), do: with_query(path, query)

  defp local_path(_, _), do: ~p"/"

  defp with_query(nil, _query), do: ~p"/"
  defp with_query(path, nil), do: path
  defp with_query(path, query), do: path <> "?" <> query
end
