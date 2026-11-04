defmodule PotokIdeWeb.LocaleTest do
  use PotokIdeWeb.ConnCase, async: true

  alias PotokIdeWeb.Locale

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

  test "follows a browser that asks for Cyrillic" do
    assert get_session(visit("sr-Cyrl-RS,sr;q=0.9,en;q=0.8"), :locale) == "sr_Cyrl"
  end

  test "stays in Latin for any other Serbian browser" do
    assert get_session(visit("sr-RS,sr;q=0.9"), :locale) == "sr"
    assert get_session(visit("sr-Latn-RS"), :locale) == "sr"
  end

  test "picks the first non-English supported browser language" do
    assert get_session(visit("en-GB,de;q=0.9,sr-Cyrl;q=0.8"), :locale) == "sr_Cyrl"
  end

  test "keeps English when the visitor chose it", %{conn: conn} do
    conn = put_req_header(conn, "accept-language", "sr-Cyrl")

    assert get_session(get(conn, ~p"/accounts/log-in"), :locale) == "en"
  end

  test "moves Polish visitors to the default language" do
    assert get_session(visit("pl-PL,pl;q=0.9"), :locale) == "sr"

    conn =
      Phoenix.ConnTest.build_conn()
      |> init_test_session(%{locale: "pl"})
      |> get(~p"/accounts/log-in")

    assert get_session(conn, :locale) == "sr"
  end

  test "recognizes every spelling of Cyrillic" do
    for spelling <- ["sr_Cyrl", "sr-Cyrl", "sr-cyrl", "sr-Cyrl-RS"] do
      assert Locale.normalize_locale(spelling) == "sr_Cyrl"
    end
  end

  test "writes a locale as a BCP 47 tag" do
    assert Locale.html_lang("sr_Cyrl") == "sr-Cyrl"
    assert Locale.html_lang("sr") == "sr"
  end
end
