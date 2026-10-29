defmodule PotokIdeWeb.LocaleTest do
  use PotokIdeWeb.ConnCase, async: true

  # ConnCase's build_conn/0 starts in English, so visit with a bare conn.
  defp visit(accept_language \\ nil) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      if accept_language,
        do: put_req_header(conn, "accept-language", accept_language),
        else: conn

    get(conn, ~p"/accounts/log-in")
  end

  test "defaults new visitors to Serbian" do
    assert get_session(visit(), :locale) == "sr"
  end

  test "ignores English in the browser languages" do
    assert get_session(visit("en-US,en;q=0.9"), :locale) == "sr"
  end

  test "follows a Polish browser" do
    assert get_session(visit("pl-PL,pl;q=0.9,en;q=0.8"), :locale) == "pl"
  end

  test "picks the first non-English supported browser language" do
    assert get_session(visit("en-GB,de;q=0.9,pl;q=0.8"), :locale) == "pl"
  end

  test "keeps English when the visitor chose it", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "pl")

    assert get_session(get(conn, ~p"/accounts/log-in"), :locale) == "en"
  end
end
