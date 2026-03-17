defmodule PotokIdeWeb.PageControllerTest do
  use PotokIdeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  test "GET / renders translated content when locale is selected", %{conn: conn} do
    conn = get(conn, ~p"/?locale=pl")

    assert get_session(conn, :locale) == "pl"
    assert html_response(conn, 200) =~ "Spokój od prototypu do produkcji."
  end
end
