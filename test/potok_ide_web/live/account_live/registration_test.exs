defmodule PotokIdeWeb.AccountLive.RegistrationTest do
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.RateLimit
  alias PotokIde.Social
  alias PotokIde.Social.AccountProfile

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

  # Accounts of the fixtures get emails of their own.
  defp empty_mailbox do
    receive do
      {:email, _email} -> empty_mailbox()
    after
      0 -> :ok
    end
  end

  describe "Registration page" do
    test "redirects unauthenticated accounts to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(conn, ~p"/accounts/register")
    end

    test "renders invite page for a signed-in account with a current profile", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)

      {:ok, lv, html} =
        conn
        |> live(~p"/accounts/register")

      assert html =~ "Invite people to potok by email"
      assert html =~ "Invite"
      # The page header and column of the other top-level pages.
      assert has_element?(lv, "#registration-header h1", "Invite people to potok by email")
      assert has_element?(lv, "#registration-page #registration_form")
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

    test "the answer does not tell whether the address has an account", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)
      taken = account_fixture(%{email: "test@email.com"})
      empty_mailbox()

      answers =
        for email <- [taken.email, unique_account_email()] do
          {:ok, lv, _html} = live(conn, ~p"/accounts/register")

          html =
            lv
            |> form("#registration_form", account: %{"email" => email})
            |> render_submit()

          refute html =~ "has already been taken"
          assert_received {:email, %Swoosh.Email{to: [{"", ^email}], subject: subject}}
          assert subject =~ "@invite-owner invites you to Potok"
          lv |> element("#flash-info p") |> render() |> String.replace(email, "EMAIL")
        end

      assert [answer, answer] = answers
      assert answer =~ "An invitation email was sent to EMAIL"
    end

    test "a failed delivery does not tell it either", %{conn: conn} do
      {conn, _profile} = conn_with_current_profile(conn)
      taken = account_fixture()
      original = Application.fetch_env!(:potok_ide, PotokIde.Mailer)
      on_exit(fn -> Application.put_env(:potok_ide, PotokIde.Mailer, original) end)

      Application.put_env(:potok_ide, PotokIde.Mailer,
        adapter: Swoosh.Adapters.Gmail,
        from_email: "potok@example.com",
        from_name: "Potok"
      )

      for email <- [taken.email, unique_account_email()] do
        {:ok, lv, _html} = live(conn, ~p"/accounts/register")
        lv |> form("#registration_form", account: %{"email" => email}) |> render_submit()

        assert has_element?(lv, "#flash-error p", "We couldn't send the invitation email")
      end
    end

    test "refuses invitations past the account's limit without opening an account", %{
      conn: conn
    } do
      {conn, profile} = conn_with_current_profile(conn)
      inviter_id = PotokIde.Repo.get_by!(AccountProfile, profile_id: profile.id).account_id

      {max, _window} = RateLimit.limit(:invitation_email)
      for _ <- 1..max, do: RateLimit.hit(:invitation_email, inviter_id)

      {:ok, lv, _html} = live(conn, ~p"/accounts/register")
      email = unique_account_email()

      lv
      |> form("#registration_form", account: valid_account_attributes(email: email))
      |> render_submit()

      assert has_element?(lv, "#flash-error p", "Too many requests in a short time.")
      refute Accounts.get_account_by_email(email)
    end

    test "a mistyped address does not count toward the limit", %{conn: conn} do
      {conn, profile} = conn_with_current_profile(conn)
      inviter_id = PotokIde.Repo.get_by!(AccountProfile, profile_id: profile.id).account_id

      {:ok, lv, _html} = live(conn, ~p"/accounts/register")

      lv
      |> form("#registration_form", account: %{"email" => "with spaces"})
      |> render_submit()

      lv
      |> form("#registration_form",
        account: valid_account_attributes(email: unique_account_email())
      )
      |> render_submit()

      {max, _window} = RateLimit.limit(:invitation_email)
      for _ <- 1..(max - 1), do: assert(:ok = RateLimit.hit(:invitation_email, inviter_id))
      assert {:error, :rate_limited, _} = RateLimit.hit(:invitation_email, inviter_id)
    end
  end
end
