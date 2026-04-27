defmodule PotokIdeWeb.InvitationLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "invitations page" do
    test "renders pending invitations before accepted invitations", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inv-order",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "inee-order",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      {:ok, pending_group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Pending Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, accepted_group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Accepted Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, accepted_invitation} =
        Social.invite_profile_to_group(inviter_profile, accepted_group, invitee_profile)

      {:ok, _accepted_invitation} =
        Social.accept_group_invitation(accepted_invitation, invitee_profile)

      {:ok, _pending_invitation} =
        Social.invite_profile_to_group(inviter_profile, pending_group, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      html = render(lv)

      assert html =~ "Pending Group"
      assert html =~ "Accepted Group"

      {pending_index, _pending_length} = :binary.match(html, "Pending Group")
      {accepted_index, _accepted_length} = :binary.match(html, "Accepted Group")

      assert pending_index < accepted_index
    end

    test "updates when a new invitation arrives", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inviter-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-prof",
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
      assert html =~ "inviter-prof"
    end

    test "switches invitation list when current profile changes", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inviter-pr2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, first_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-one",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "invitee-two",
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
      assert html =~ "inviter-pr2"
    end

    test "loads more invitations when more than one page exists", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inv-page-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "inv-page-viewer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      Enum.each(1..21, fn index ->
        group_name = "Paged Group #{String.pad_leading(Integer.to_string(index), 2, "0")}"

        {:ok, group} =
          Social.create_group(inviter_profile, root_group, %{
            "name" => group_name,
            "description" => "",
            "description_format" => :markdown,
            "is_public" => false
          })

        assert {:ok, _invitation} =
                 Social.invite_profile_to_group(inviter_profile, group, invitee_profile)
      end)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      rendered = render(lv)

      assert rendered =~ "Paged Group 11"
      refute rendered =~ "Paged Group 01"
      assert has_element?(lv, "#invitations-load-more")

      lv
      |> element("#invitations-load-more")
      |> render_click()

      rendered = render(lv)
      assert rendered =~ "Paged Group 01"
    end

    test "deletes an invitation from the list", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inv-del-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "inv-del-viewer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Delete Invitation Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, invitation} =
        Social.invite_profile_to_group(inviter_profile, group, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      assert render(lv) =~ "Delete Invitation Group"
      assert has_element?(lv, "#invitation-delete-#{invitation.id}")

      html =
        lv
        |> element("#invitation-delete-#{invitation.id}")
        |> render_click()

      assert html =~ "Invitation deleted."
      refute html =~ "Delete Invitation Group"
      refute Social.get_group_invitation_for_invitee(invitee_profile, invitation.id)
    end

    test "filters invitations by search query and clears the search", %{conn: conn} do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "inv-src-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "inv-src-view",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      invitee_account = Accounts.get_account!(invitee_account.id)
      root_group = Social.get_root_group!()

      {:ok, alpha_group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Alpha Search Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, beta_group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Beta Search Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, _invitation} =
               Social.invite_profile_to_group(inviter_profile, alpha_group, invitee_profile)

      assert {:ok, _invitation} =
               Social.invite_profile_to_group(inviter_profile, beta_group, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(invitee_account)
        |> live(~p"/invitations")

      assert has_element?(lv, "#invitation-search-form")

      lv
      |> form("#invitation-search-form", invitation_search: %{q: "Alpha"})
      |> render_change()

      assert has_element?(lv, "#invitations a", "Alpha Search Group")
      refute has_element?(lv, "#invitations a", "Beta Search Group")
      assert has_element?(lv, "#invitation-search-reset")
      assert has_element?(lv, ".bg-yellow-300", "Alpha")

      lv
      |> form("#invitation-search-form", invitation_search: %{q: "inv-src-own"})
      |> render_change()

      assert has_element?(lv, "#invitations a", "Alpha Search Group")
      assert has_element?(lv, "#invitations a", "Beta Search Group")
      assert has_element?(lv, ".bg-yellow-300", "inv-src-own")

      lv
      |> element("#invitation-search-reset")
      |> render_click()

      assert has_element?(lv, "#invitations a", "Alpha Search Group")
      assert has_element?(lv, "#invitations a", "Beta Search Group")
    end

    test "shows sent invitations in a separate section and searches both sections", %{conn: conn} do
      current_account = account_fixture()
      received_inviter_account = account_fixture()
      sent_invitee_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "invsh-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, received_inviter_profile} =
        Social.create_profile_for_account(received_inviter_account, %{
          username: "invsh-src",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, sent_invitee_profile} =
        Social.create_profile_for_account(sent_invitee_account, %{
          username: "invsh-tgt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      current_account = Accounts.get_account!(current_account.id)
      root_group = Social.get_root_group!()

      {:ok, received_group} =
        Social.create_group(received_inviter_profile, root_group, %{
          "name" => "Received Search Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, sent_group} =
        Social.create_group(current_profile, root_group, %{
          "name" => "Sent Search Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, _received_invitation} =
               Social.invite_profile_to_group(received_inviter_profile, received_group, current_profile)

      assert {:ok, _sent_invitation} =
               Social.invite_profile_to_group(current_profile, sent_group, sent_invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(current_account)
        |> live(~p"/invitations")

      assert has_element?(lv, "#invitations-toggle")
      assert has_element?(lv, "#sent-invitations-toggle")
      assert has_element?(lv, "#invitations a", "Received Search Group")
      assert has_element?(lv, "#sent-invitations a", "Sent Search Group")

      lv
      |> form("#invitation-search-form", invitation_search: %{q: "invsh-tgt"})
      |> render_change()

      refute has_element?(lv, "#invitations a", "Received Search Group")
      assert has_element?(lv, "#sent-invitations a", "Sent Search Group")
      assert has_element?(lv, ".bg-yellow-300", "invsh-tgt")
    end

    test "repopulates collapsed sections after search when re-expanded", %{conn: conn} do
      current_account = account_fixture()
      inviter_account = account_fixture()
      sent_invitee_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "invcol-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "invcol-src",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, sent_invitee_profile} =
        Social.create_profile_for_account(sent_invitee_account, %{
          username: "invcol-tgt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      current_account = Accounts.get_account!(current_account.id)
      root_group = Social.get_root_group!()

      {:ok, received_group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "Collapsed Received Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, sent_group} =
        Social.create_group(current_profile, root_group, %{
          "name" => "Collapsed Sent Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, _received_invitation} =
               Social.invite_profile_to_group(inviter_profile, received_group, current_profile)

      assert {:ok, _sent_invitation} =
               Social.invite_profile_to_group(current_profile, sent_group, sent_invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(current_account)
        |> live(~p"/invitations")

      lv
      |> element("#invitations-toggle")
      |> render_click()

      lv
      |> element("#sent-invitations-toggle")
      |> render_click()

      lv
      |> form("#invitation-search-form", invitation_search: %{q: "Collapsed"})
      |> render_change()

      refute has_element?(lv, "#invitations a", "Collapsed Received Group")
      refute has_element?(lv, "#sent-invitations a", "Collapsed Sent Group")

      lv
      |> element("#invitations-toggle")
      |> render_click()

      lv
      |> element("#sent-invitations-toggle")
      |> render_click()

      assert has_element?(lv, "#invitations a", "Collapsed Received Group")
      assert has_element?(lv, "#sent-invitations a", "Collapsed Sent Group")
    end
  end
end
