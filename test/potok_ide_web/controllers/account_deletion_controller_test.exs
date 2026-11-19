defmodule PotokIdeWeb.AccountDeletionControllerTest do
  use PotokIdeWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Profile

  defp link_token(account) do
    extract_account_token(fn url ->
      Accounts.deliver_account_deletion_instructions(account, url)
    end)
  end

  describe "GET /brisanje-naloga" do
    test "asks for the address, for guests too", %{conn: conn} do
      html = conn |> get(~p"/brisanje-naloga") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "#account-deletion-form") |> Enum.count() == 1
      assert LazyHTML.query(document, "a[href='/privacy-policy']") |> Enum.count() >= 1
    end

    test "the English address leads to it", %{conn: conn} do
      assert conn |> get(~p"/delete-account") |> redirected_to() == ~p"/brisanje-naloga"
    end
  end

  describe "POST /brisanje-naloga" do
    test "answers the same whether the address has an account or not", %{conn: conn} do
      account = account_fixture()

      known =
        conn
        |> post(~p"/brisanje-naloga", %{"account" => %{"email" => account.email}})

      unknown =
        build_conn()
        |> post(~p"/brisanje-naloga", %{"account" => %{"email" => "nobody@example.com"}})

      assert redirected_to(known) == ~p"/brisanje-naloga"
      assert redirected_to(unknown) == ~p"/brisanje-naloga"

      assert Phoenix.Flash.get(known.assigns.flash, :info) ==
               Phoenix.Flash.get(unknown.assigns.flash, :info)

      assert Repo.exists?(
               from(t in Accounts.AccountToken,
                 where: t.account_id == ^account.id and t.context == "delete"
               )
             )
    end

    test "counts the typed address", %{conn: conn} do
      email = "limited#{System.unique_integer([:positive])}@example.com"
      {limit, _window} = RateLimit.limit(:account_deletion_email)

      for _ <- 1..limit do
        post(build_conn(), ~p"/brisanje-naloga", %{"account" => %{"email" => email}})
      end

      conn = post(conn, ~p"/brisanje-naloga", %{"account" => %{"email" => email}})
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end
  end

  describe "the link" do
    test "shows what goes and deletes nothing", %{conn: conn} do
      {account, profile} = account_with_profile!("leaving")
      token = link_token(account)

      html = conn |> get(~p"/brisanje-naloga/#{token}") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "#account-deletion-preview-profiles") |> Enum.count() == 1
      assert LazyHTML.query(document, "#account-deletion-confirm-form") |> Enum.count() == 1
      assert Repo.get(Account, account.id)
      assert Repo.get!(Profile, profile.id).kind == :person
    end

    test "the form under it deletes and logs out", %{conn: conn} do
      {account, profile} = account_with_profile!("leaving")
      token = link_token(account)
      conn = log_in_account(conn, account)

      conn = post(conn, ~p"/brisanje-naloga/#{token}")
      assert redirected_to(conn) == ~p"/brisanje-naloga/gotovo"
      refute Repo.get(Account, account.id)
      assert Repo.get!(Profile, profile.id).kind == :deleted
      refute get_session(conn, :account_token)

      html = conn |> recycle() |> get(~p"/brisanje-naloga/gotovo") |> html_response(200)

      assert LazyHTML.from_document(html) |> LazyHTML.query("#account-deleted") |> Enum.count() ==
               1
    end

    test "an invalid or expired link sends back to the form", %{conn: conn} do
      conn = get(conn, ~p"/brisanje-naloga/not-a-token")
      assert redirected_to(conn) == ~p"/brisanje-naloga"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
    end

    test "names the groups that block it", %{conn: conn} do
      {account, owner} = account_with_profile!("owner")
      {_other_account, other} = account_with_profile!("other")
      group = group_with_members!(owner, [other])
      token = link_token(account)

      html = conn |> get(~p"/brisanje-naloga/#{token}") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "#account-deletion-preview-blocking-#{group.id}")
             |> Enum.count() == 1

      assert LazyHTML.query(document, "#account-deletion-confirm-form") |> Enum.count() == 0

      conn = post(build_conn(), ~p"/brisanje-naloga/#{token}")
      assert redirected_to(conn) == ~p"/brisanje-naloga/#{token}"
      assert Repo.get(Account, account.id)
    end
  end

  describe "the settings" do
    setup %{conn: conn} do
      {account, profile} = account_with_profile!("settler")
      %{conn: log_in_account(conn, account), account: account, profile: profile}
    end

    test "link the privacy policy and open the deletion", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")

      assert has_element?(lv, "#settings-account a[href='/privacy-policy']")
      refute has_element?(lv, "#delete-account-form")

      lv |> element("#delete-account-start") |> render_click()
      assert has_element?(lv, "#delete-account-preview")
      assert has_element?(lv, "#delete-account-form")
    end

    test "a wrong address deletes nothing", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")
      lv |> element("#delete-account-start") |> render_click()

      lv
      |> form("#delete-account-form", %{"account" => %{"email" => "someone@else.com"}})
      |> render_submit()

      assert Repo.get(Account, account.id)
    end

    test "after a recent log-in the form posts and deletes at once", %{
      conn: conn,
      account: account,
      profile: profile
    } do
      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")
      lv |> element("#delete-account-start") |> render_click()

      form = form(lv, "#delete-account-form", %{"account" => %{"email" => account.email}})
      assert render_submit(form) =~ ~s(phx-trigger-action)

      conn = follow_trigger_action(form, conn)
      assert redirected_to(conn) == ~p"/brisanje-naloga/gotovo"
      refute Repo.get(Account, account.id)
      assert Repo.get!(Profile, profile.id).kind == :deleted
    end

    test "after an old log-in it sends the link instead", %{account: account} do
      conn =
        log_in_account(build_conn(), account,
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -2, :hour)
        )

      {:ok, lv, _html} = live(conn, ~p"/accounts/settings")
      lv |> element("#delete-account-start") |> render_click()

      lv
      |> form("#delete-account-form", %{"account" => %{"email" => account.email}})
      |> render_submit()

      assert Repo.get(Account, account.id)

      assert Repo.exists?(
               from(t in Accounts.AccountToken,
                 where: t.account_id == ^account.id and t.context == "delete"
               )
             )

      # The post itself is refused without a recent log-in.
      conn = post(conn, ~p"/accounts/delete", %{"account" => %{"email" => account.email}})
      assert redirected_to(conn) =~ "/accounts/settings"
      assert Repo.get(Account, account.id)
    end
  end

  test "the chat names a deleted author \"Deleted user\"" do
    {_owner_account, owner} = account_with_profile!("owner")
    {member_account, member} = account_with_profile!("member")
    group = group_with_members!(owner, [member])

    {:ok, _value} =
      Social.create_value(member, group, %{"content" => "Bye", "content_format" => "markdown"})

    {:ok, _tokens} = Accounts.delete_account(member_account)

    owner_account =
      Repo.one!(from(a in Account, join: ap in assoc(a, :profiles), where: ap.id == ^owner.id))

    conn = log_in_account(build_conn(), owner_account)
    {:ok, _lv, html} = live(conn, ~p"/groups/#{group.id}/values")

    assert html =~ "Deleted user"
    refute html =~ "@member"
  end
end
