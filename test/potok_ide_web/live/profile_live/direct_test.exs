defmodule PotokIdeWeb.ProfileLive.DirectTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "direct profile route" do
    test "creates a direct group and redirects to its values tab", %{conn: conn} do
      current_account = account_fixture()
      other_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "dirroute-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "dirroute-oth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      current_account = Accounts.get_account!(current_account.id)

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               conn
               |> log_in_account(current_account)
               |> live(~p"/profiles/#{other_profile.id}/direct")

      [direct_group] = Social.list_child_groups(Social.get_root_group!())

      assert redirected_to == ~p"/groups/#{direct_group.id}/values"
      assert Social.count_group_members(direct_group) == 2

      member_ids =
        direct_group
        |> Social.list_group_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert member_ids == Enum.sort([current_profile.id, other_profile.id])
    end

    test "reuses an existing direct group", %{conn: conn} do
      current_account = account_fixture()
      other_account = account_fixture()

      {:ok, current_profile} =
        Social.create_profile_for_account(current_account, %{
          username: "dirreuse-cur",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "dirreuse-oth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, existing_group} = Social.get_or_create_direct_group(current_profile, other_profile)
      current_account = Accounts.get_account!(current_account.id)

      assert {:error, {:live_redirect, %{to: redirected_to}}} =
               conn
               |> log_in_account(current_account)
               |> live(~p"/profiles/#{other_profile.id}/direct")

      assert redirected_to == ~p"/groups/#{existing_group.id}/values"
      assert length(Social.list_child_groups(Social.get_root_group!())) == 1
    end
  end
end
