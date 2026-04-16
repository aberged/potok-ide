defmodule PotokIdeWeb.PageControllerTest do
  use PotokIdeWeb.ConnCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  test "GET / redirects guests to log in", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/accounts/log-in"
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

  test "GET / keeps selected locale when redirecting guests", %{conn: conn} do
    conn = get(conn, ~p"/?locale=pl")

    assert get_session(conn, :locale) == "pl"
    assert redirected_to(conn) == ~p"/accounts/log-in"
  end
end
