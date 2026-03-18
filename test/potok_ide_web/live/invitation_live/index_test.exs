defmodule PotokIdeWeb.InvitationLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "invitations page" do
    test "updates when a new invitation arrives", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inviter-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Realtime Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      refute render(lv) =~ "Realtime Group"

      {:ok, _invitation} =
        Social.invite_profile_to_group(inviter_profile, group, invitee_profile)

      html = render(lv)
      assert html =~ "Realtime Group"
      assert html =~ "inviter-profile"
    end

    test "switches invitation list when current profile changes", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inviter-profile-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, first_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "first-invitee-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "second-invitee-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_account} = Accounts.set_current_profile(invitee_account, first_profile)
      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Switch Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _invitation} =
        Social.invite_profile_to_group(inviter_profile, group, second_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      refute render(lv) =~ "Switch Group"

      {:ok, _updated_account} = Accounts.set_current_profile(invitee_account, second_profile)

      html = render(lv)
      assert html =~ "Switch Group"
      assert html =~ "inviter-profile-2"
    end
  end
end
