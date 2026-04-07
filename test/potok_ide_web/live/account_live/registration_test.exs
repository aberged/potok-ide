defmodule PotokIdeWeb.AccountLive.RegistrationTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  defp conn_with_current_profile(conn) do
    account = account_fixture()

    {:ok, _profile} =
      Social.create_profile_for_account(account, %{
        username: "invite-owner",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    account = Accounts.get_account!(account.id)
    log_in_account(conn, account)
  end

  describe "Registration page" do
    test "redirects unauthenticated accounts to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(conn, ~p"/accounts/register")
    end

    test "renders invite page for a signed-in account with a current profile", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> conn_with_current_profile()
        |> live(~p"/accounts/register")

      assert html =~ "Invite people to potok by email"
      assert html =~ "Invite"
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> conn_with_current_profile()
        |> live(~p"/accounts/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(account: %{"email" => "with spaces"})

      assert result =~ "Invite people to potok by email"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register account" do
    test "creates an invited account and shows confirmation", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> conn_with_current_profile()
        |> live(~p"/accounts/register")

      email = unique_account_email()
      form = form(lv, "#registration_form", account: valid_account_attributes(email: email))

      html = render_submit(form)

      assert html =~ "An invitation email was sent to #{email}"
      assert Accounts.get_account_by_email(email)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> conn_with_current_profile()
        |> live(~p"/accounts/register")

      account = account_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          account: %{"email" => account.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end
end
