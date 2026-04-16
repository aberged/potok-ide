defmodule PotokIdeWeb.RequestLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "requests page" do
    test "renders pending access requests the current profile can approve", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "reqpage-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "reqpage-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "Requested Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, _request} = Social.request_group_access(requester_profile, group)

      html =
        Phoenix.ConnTest.build_conn()
        |> log_in_account(owner_account)
        |> get(~p"/requests")
        |> html_response(200)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/requests")

      assert html =~ "nav-requests-count-badge"
      assert render(lv) =~ "Requested Group"
      assert render(lv) =~ requester_profile.username
      assert render(lv) =~ "Review this access request for the selected group."
      assert has_element?(lv, "a[href='/profiles/#{requester_profile.id}/direct']")
    end

    test "updates when a new access request arrives for the approver", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "requpd-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "requpd-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "Realtime Request Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/requests")

      refute render(lv) =~ "Realtime Request Group"

      assert {:ok, _request} = Social.request_group_access(requester_profile, group)

      assert render(lv) =~ "Realtime Request Group"
    end

    test "switches request list when current profile changes", %{conn: conn} do
      requester_account = account_fixture()
      approver_account = account_fixture()

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "reqsw-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, first_profile} =
        Social.create_profile_for_account(approver_account, %{
          username: "reqsw-first",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(approver_account, %{
          username: "reqsw-sec",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, approver_account} = Accounts.set_current_profile(approver_account, first_profile)
      approver_account = Accounts.get_account!(approver_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(second_profile, root_group, %{
          "name" => "Switched Request Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, _request} = Social.request_group_access(requester_profile, group)

      {:ok, lv, _html} =
        conn
        |> log_in_account(approver_account)
        |> live(~p"/requests")

      refute render(lv) =~ "Switched Request Group"

      {:ok, _updated_account} = Accounts.set_current_profile(approver_account, second_profile)

      assert render(lv) =~ "Switched Request Group"
    end

    test "lets the approver accept and reject pending requests", %{conn: conn} do
      owner_account = account_fixture()
      requester_account = account_fixture()
      second_requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "reqact-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "reqact-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_requester_profile} =
        Social.create_profile_for_account(second_requester_account, %{
          username: "reqact-req2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "Action Request Group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, request} = Social.request_group_access(requester_profile, group)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/requests")

      assert has_element?(lv, "#request-accept-#{request.id}")

      lv
      |> element("#request-accept-#{request.id}")
      |> render_click()

      assert Social.member_of_group?(requester_profile, group)
      refute has_element?(lv, "#approval-request-#{request.id}")

      assert {:ok, request} = Social.request_group_access(second_requester_profile, group)

      assert has_element?(lv, "#request-reject-#{request.id}")

      lv
      |> element("#request-reject-#{request.id}")
      |> render_click()

      refute has_element?(lv, "#approval-request-#{request.id}")
      refute Social.member_of_group?(second_requester_profile, group)
    end
  end
end
