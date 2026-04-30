defmodule PotokIdeWeb.AccountLive.RegistrationTest do
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  defp conn_with_current_profile(conn) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "invite-owner",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    account = Accounts.get_account!(account.id)
    {log_in_account(conn, account), profile}
  end

  describe "Registration page" do
    test "redirects unauthenticated accounts to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(conn, ~p"/accounts/register")
    end

    test "renders invite page for a signed-in account with a current profile", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)

      {:ok, _lv, html} =
        conn
        |> live(~p"/accounts/register")

      assert html =~ "Invite people to potok by email"
      assert html =~ "Invite"
    end

    test "renders errors for invalid data", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)

      {:ok, lv, _html} =
        conn
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
      {conn, current_profile} = conn_with_current_profile(conn)

      {:ok, lv, _html} =
        conn
        |> live(~p"/accounts/register")

      email = unique_account_email()
      form = form(lv, "#registration_form", account: valid_account_attributes(email: email))

      html = render_submit(form)

      assert html =~ "An invitation email was sent to #{email}"

      assert invited_account = Accounts.get_account_by_email(email)
      assert invited_account.invited_by_id == current_profile.id
    end

    test "shows an error when invitation email delivery fails", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)

      original_mailer_config = Application.fetch_env!(:potok_ide, PotokIde.Mailer)

      on_exit(fn ->
        Application.put_env(:potok_ide, PotokIde.Mailer, original_mailer_config)
      end)

      Application.put_env(:potok_ide, PotokIde.Mailer,
        adapter: Swoosh.Adapters.Gmail,
        from_email: "potok@example.com",
        from_name: "Potok"
      )

      {:ok, lv, _html} =
        conn
        |> live(~p"/accounts/register")

      _html =
        lv
        |> form("#registration_form",
          account: valid_account_attributes(email: unique_account_email())
        )
        |> render_submit()

      assert has_element?(lv, "#flash-error")

      assert has_element?(
               lv,
               "#flash-error p",
               "We couldn't send the invitation email right now. Please try again later."
             )
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)

      {:ok, lv, _html} =
        conn
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
