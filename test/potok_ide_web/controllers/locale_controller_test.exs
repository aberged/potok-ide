defmodule PotokIdeWeb.LocaleControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  test "stores locale and redirects back to the referring page", %{conn: conn} do
    conn =
      conn
      |> put_req_header("referer", "http://www.example.com/accounts/log-in")
      |> get(~p"/locale/pl")

    assert get_session(conn, :locale) == "pl"
    assert redirected_to(conn) == ~p"/accounts/log-in"
  end

  test "falls back to default locale for unsupported locales", %{conn: conn} do
    conn = get(conn, ~p"/locale/de")

    assert get_session(conn, :locale) == "en"
    assert redirected_to(conn) == ~p"/"
  end
end
