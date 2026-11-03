defmodule PotokIdeWeb.PageControllerTest do
  use PotokIdeWeb.ConnCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  test "GET / shows guests the landing page", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()

    for selector <- [
          "#landing-hero",
          "#landing-waves",
          "#landing-features",
          "#landing-perks",
          "#landing-join",
          "#landing-login-link[href='/accounts/log-in']",
          "#landing-join-login[href='/accounts/log-in']",
          "#guest-header #landing-login-link",
          "#guest-footer #guest-privacy-link[href='/privacy-policy']",
          "meta[name=description]"
        ] do
      assert Enum.count(LazyHTML.query(document, selector)) == 1, "missing #{selector}"
    end

    assert Enum.count(LazyHTML.query(document, "#landing-features article")) == 6
    assert Enum.count(LazyHTML.query(document, "#landing-perks li")) == 5
  end

  describe "Potok's card for shared links" do
    defp og(document, property) do
      document
      |> LazyHTML.query(~s(meta[property="og:#{property}"]))
      |> LazyHTML.attribute("content")
      |> List.first()
    end

    test "is on the landing page and the page private links end up on", %{conn: conn} do
      for path <- [~p"/", ~p"/accounts/log-in"] do
        document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

        assert og(document, "site_name") == "Potok"
        assert og(document, "type") == "website"
        assert og(document, "title") == "Potok · Society for society"
        assert og(document, "description") =~ "Conversations, events, files and roles"
        assert og(document, "url") == PotokIdeWeb.Endpoint.url() <> path
        assert og(document, "image") == url(~p"/images/og.png")
        assert og(document, "image:width") == "1200"
        assert og(document, "image:height") == "630"
        assert og(document, "locale") == "en_US"

        assert Enum.count(LazyHTML.query(document, ~s(meta[name="description"]))) == 1
        assert Enum.empty?(LazyHTML.query(document, ~s(meta[name="robots"])))

        assert document
               |> LazyHTML.query(~s(meta[name="twitter:card"]))
               |> LazyHTML.attribute("content") == ["summary_large_image"]
      end
    end

    test "is in Serbian for crawlers, which ask for no language" do
      document =
        Phoenix.ConnTest.build_conn()
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert og(document, "title") == "Potok · Društvo društvu"
      assert og(document, "locale") == "sr_RS"
    end

    test "has its picture", %{conn: conn} do
      conn = get(conn, ~p"/images/og.png")

      assert response(conn, 200)
      assert response_content_type(conn, :png)
    end
  end

  test "GET / redirects authenticated accounts without a profile to profiles", %{conn: conn} do
    account = account_fixture()

    conn =
      conn
      |> log_in_account(account)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/profiles"
  end

  test "GET / redirects authenticated accounts with a current profile to groups", %{conn: conn} do
    account = account_fixture()

    {:ok, _profile} =
      Social.create_profile_for_account(account, %{
        username: "root-groups",
        description_format: :markdown,
        sharing: :unique
      })

    account = Accounts.get_account!(account.id)

    conn =
      conn
      |> log_in_account(account)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/groups"
  end

  test "GET / shows guests the landing page in the selected locale", %{conn: conn} do
    conn = get(conn, ~p"/?locale=pl")

    assert get_session(conn, :locale) == "pl"

    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "html[lang=pl]")) == 1
    assert Enum.count(LazyHTML.query(document, "#landing-hero")) == 1
  end
end
