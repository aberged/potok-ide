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
          "#landing-streams",
          "#landing-why",
          "#landing-flow",
          "#landing-join",
          "#landing-login-link[href='/accounts/log-in']",
          "#landing-join-login[href='/accounts/log-in']",
          "#guest-header #landing-login-link",
          "#guest-footer #guest-privacy-link[href='/privacy-policy']",
          "meta[name=description]"
        ] do
      assert Enum.count(LazyHTML.query(document, selector)) == 1, "missing #{selector}"
    end

    assert Enum.count(LazyHTML.query(document, "#landing-flow li")) == 5
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
