defmodule PotokIde.SocialTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "create_group/3" do
    test "persists group_picture_url" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-picture-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "picture-child-group",
          "group_picture_url" => "https://example.com/group.png",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert group.group_picture_url == "https://example.com/group.png"
    end
  end

  describe "shared profile invitations" do
    test "inviting and accepting links a shared profile to the accepting account" do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "shared-profile-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "shared-profile-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_profile(
                 inviter_account,
                 shared_profile,
                 shared_profile,
                 invitee_profile
               )

      assert [pending_invitation] = Social.list_pending_profile_invitations(invitee_profile)
      assert pending_invitation.id == invitation.id
      assert pending_invitation.profile.id == shared_profile.id

      assert {:ok, _accepted_invitation} =
               Social.accept_profile_invitation(invitation, invitee_profile, invitee_account)

      invitee_account = Accounts.get_account!(invitee_account.id)

      assert [_invitee_profile, linked_profile] = Social.list_profiles_for_account(invitee_account)
      assert linked_profile.id == shared_profile.id

      assert current_profile = Social.get_account_current_profile(invitee_account)
      assert current_profile.id == invitee_profile.id

      assert [] == Social.list_pending_profile_invitations(invitee_profile)
    end
  end

  describe "count_group_members/1" do
    test "returns the current number of members in a group" do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "member-count-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "member-count-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "member-count-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert Social.count_group_members(group) == 1

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      assert Social.count_group_members(group) == 2
    end
  end

  describe "delete_value/2" do
    test "deletes a value created by the profile" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delete-value-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "delete me",
          "content_format" => :markdown
        })

      assert {:ok, _deleted_value} = Social.delete_value(profile, value)
      assert [] == Social.list_group_values(group)
    end

    test "rejects deleting another profile's value" do
      owner_account = account_fixture()
      other_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "delete-value-authorized",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "delete-value-unauthorized",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(owner_profile, group, %{
          "content" => "keep me",
          "content_format" => :markdown
        })

      assert {:error, :not_value_creator} = Social.delete_value(other_profile, value)
      assert [remaining_value] = Social.list_group_values(group)
      assert remaining_value.id == value.id
    end
  end

  describe "update_value/3" do
    test "updates a value created by the profile" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "edit-value-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "original value",
          "content_format" => :markdown
        })

      assert {:ok, updated_value} =
               Social.update_value(profile, value, %{"content" => "updated value"})

      assert updated_value.content == "updated value"

      assert [reloaded_value] = Social.list_group_values(group)
      assert reloaded_value.content == "updated value"
    end

    test "rejects updating another profile's value" do
      owner_account = account_fixture()
      other_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "edit-value-authorized",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "edit-value-unauthorized",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(owner_profile, group, %{
          "content" => "keep original",
          "content_format" => :markdown
        })

      assert {:error, :not_value_creator} =
               Social.update_value(other_profile, value, %{"content" => "changed"})

      assert [reloaded_value] = Social.list_group_values(group)
      assert reloaded_value.content == "keep original"
    end
  end

  describe "list_child_groups_for_profile/2" do
    test "returns only child groups where the profile is a member" do
      account = account_fixture()
      other_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "social-member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "social-other-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, visible_child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "alpha-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _hidden_child_group} =
        Social.create_group(other_profile, root_group, %{
          "name" => "beta-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert [returned_group] = Social.list_child_groups_for_profile(root_group, profile)
      assert returned_group.id == visible_child_group.id
      assert returned_group.name == "alpha-child-group"

      assert [] == Social.list_child_groups_for_profile(visible_child_group, other_profile)

      assert [other_returned_group] =
               Social.list_child_groups_for_profile(root_group, other_profile)

      assert other_returned_group.name == "beta-child-group"

      assert [_] =
               Social.list_child_groups_for_profile(
                 root_group,
                 Accounts.get_account!(account.id) |> Social.get_account_current_profile()
               )
    end
  end
end
