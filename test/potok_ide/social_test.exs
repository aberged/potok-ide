defmodule PotokIde.SocialTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Social
  alias PotokIde.Social.Group

  describe "create_group/3" do
    test "persists group_picture_url and home_page" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "grp-pic-prof",
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
          "home_page" => :subgroups,
          "is_public" => false
        })

      assert group.group_picture_url == "https://example.com/group.png"
      assert group.home_page == :subgroups
      assert group.has_public_chat == false
      assert group.is_direct == false
      assert group.uses_api == false
    end

    test "accepts larger data URLs for group pictures" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "grp-pic-data",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()
      group_picture_url = "data:image/png;base64," <> String.duplicate("a", 25_000)

      assert {:ok, group} =
               Social.create_group(profile, root_group, %{
                 "name" => "data-url-child-group",
                 "group_picture_url" => group_picture_url,
                 "description" => "",
                 "description_format" => :markdown,
                 "home_page" => :subgroups,
                 "is_public" => false
               })

      assert group.group_picture_url == group_picture_url
    end

    test "forces public visibility when root_public is enabled" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "root-pub-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      assert {:ok, group} =
               Social.create_group(profile, root_group, %{
                 "name" => "root-public-child-group",
                 "group_picture_url" => nil,
                 "description" => "",
                 "description_format" => :markdown,
                 "home_page" => :subgroups,
                 "is_public" => false,
                 "is_root_public" => true
               })

      assert group.is_root_public
      assert group.is_public
    end

    test "forces html description_format when uses_api is enabled" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "api-create",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      assert {:ok, group} =
               Social.create_group(profile, root_group, %{
                 "name" => "uses-api-create-group",
                 "description" => "",
                 "description_format" => :markdown,
                 "home_page" => :description,
                 "is_public" => false,
                 "uses_api" => true
               })

      assert group.uses_api
      assert group.description_format == :html
    end
  end

  describe "Group.update_changeset/2" do
    test "forces html description_format when uses_api is enabled" do
      changeset =
        Group.update_changeset(%Group{name: "group", description_format: :markdown}, %{
          "name" => "group",
          "description_format" => :markdown,
          "home_page" => :description,
          "has_public_chat" => false,
          "is_public" => false,
          "is_root_public" => false,
          "uses_api" => true
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :uses_api)
      assert Ecto.Changeset.get_field(changeset, :description_format) == :html
    end
  end

  describe "get_or_create_direct_group/2" do
    test "creates a private two-member child of the root group and reuses it" do
      first_account = account_fixture()
      second_account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(first_account, %{
          username: "direct-first",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(second_account, %{
          username: "direct-second",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(first_profile, second_profile)

      assert direct_group.parent_id == root_group.id
      refute direct_group.is_public
      assert direct_group.has_public_chat
      assert direct_group.is_direct
      assert direct_group.home_page == :chat
      assert Social.count_group_members(direct_group) == 2

      member_ids =
        direct_group
        |> Social.list_group_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert member_ids == Enum.sort([first_profile.id, second_profile.id])

      assert {:ok, reused_group} =
               Social.get_or_create_direct_group(second_profile, first_profile)

      assert reused_group.id == direct_group.id
      assert length(Social.list_child_groups(root_group)) == 1
    end

    test "rejects opening a direct group with the same profile" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "direct-self",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert {:error, :same_profile} = Social.get_or_create_direct_group(profile, profile)
    end

    test "does not reuse a regular private two-member group" do
      first_account = account_fixture()
      second_account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(first_account, %{
          username: "reggrp-first",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(second_account, %{
          username: "reggrp-second",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, regular_group} =
        Social.create_group(first_profile, root_group, %{
          "name" => "ordinary private group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert regular_group.is_direct == false

      assert {:ok, invitation} =
               Social.invite_profile_to_group(first_profile, regular_group, second_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, second_profile)

      assert Social.count_group_members(regular_group) == 2

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(first_profile, second_profile)

      assert direct_group.id != regular_group.id
      assert direct_group.is_direct
      assert length(Social.list_child_groups(root_group)) == 2
    end
  end

  describe "create_profile_for_account/2" do
    test "sets both current and default profiles for the first account profile only" do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-first",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      assert Social.get_account_current_profile(account).id == first_profile.id
      assert Social.get_account_default_profile(account).id == first_profile.id

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-sec",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      assert Social.get_account_current_profile(account).id == first_profile.id
      assert Social.get_account_default_profile(account).id == first_profile.id
      refute Social.get_account_default_profile(account).id == second_profile.id
    end

    test "materializes pending group account invitations when the first profile is created" do
      owner_account = account_fixture()
      invited_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "pending-own",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "pending-account-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, %PotokIde.Social.GroupAccountInvitation{} = pending_invitation} =
               Social.invite_account_to_group(owner_profile, group, invited_account)

      assert Repo.get(PotokIde.Social.GroupAccountInvitation, pending_invitation.id)

      {:ok, invited_profile} =
        Social.create_profile_for_account(invited_account, %{
          username: "pending-inv",
          description_format: :markdown,
          sharing: :unique
        })

      refute Repo.get(PotokIde.Social.GroupAccountInvitation, pending_invitation.id)

      assert [%{group: %{id: group_id}, inviter: %{id: inviter_id}}] =
               Social.list_pending_invitations(invited_profile)

      assert group_id == group.id
      assert inviter_id == owner_profile.id

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(invited_profile, owner_profile)

      assert direct_group.is_direct
      refute direct_group.is_public

      member_ids =
        direct_group
        |> Social.list_group_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert member_ids == Enum.sort([invited_profile.id, owner_profile.id])
    end

    test "invites the default profile for an existing account" do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "email-ownr",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "email-invt",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "existing-email-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, %PotokIde.Social.GroupInvitation{} = invitation} =
               Social.invite_account_to_group(owner_profile, group, invitee_account)

      assert invitation.invitee_id == invitee_profile.id

      assert [%{id: invitation_id}] = Social.list_pending_invitations(invitee_profile)
      assert invitation_id == invitation.id

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(invitee_profile, owner_profile)

      assert direct_group.is_direct
      refute direct_group.is_public

      member_ids =
        direct_group
        |> Social.list_group_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert member_ids == Enum.sort([invitee_profile.id, owner_profile.id])
    end

    test "creates a direct group with the inviter profile when the invited account creates its first profile" do
      inviter_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "first-inviter",
          description_format: :markdown,
          sharing: :unique
        })

      email = unique_account_email()
      {:ok, invited_account} = Accounts.register_account(%{email: email}, inviter_profile)

      {:ok, invited_profile} =
        Social.create_profile_for_account(invited_account, %{
          username: "first-invitee",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      assert {:ok, direct_group} =
               Social.get_or_create_direct_group(invited_profile, inviter_profile)

      assert direct_group.parent_id == root_group.id
      assert direct_group.is_direct
      refute direct_group.is_public
      assert Social.count_group_members(direct_group) == 2

      member_ids =
        direct_group
        |> Social.list_group_members()
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert member_ids == Enum.sort([invited_profile.id, inviter_profile.id])
      assert Enum.count(Social.list_child_groups(root_group), &(&1.id == direct_group.id)) == 1
    end

    test "accepts larger data URLs for profile pictures" do
      account = account_fixture()
      profile_picture_url = "data:image/png;base64," <> String.duplicate("a", 25_000)

      assert {:ok, profile} =
               Social.create_profile_for_account(account, %{
                 username: "dataurl-prof",
                 profile_picture_url: profile_picture_url,
                 description_format: :markdown,
                 sharing: :unique
               })

      assert profile.profile_picture_url == profile_picture_url
    end

    test "accepts unicode usernames with uppercase letters up to 16 characters" do
      account = account_fixture()

      assert {:ok, profile} =
               Social.create_profile_for_account(account, %{
                 username: "Żółć.123",
                 description_format: :markdown,
                 sharing: :unique
               })

      assert profile.username == "Żółć.123"
    end

    test "rejects usernames longer than 16 characters" do
      account = account_fixture()

      assert {:error, changeset} =
               Social.create_profile_for_account(account, %{
                 username: "abcdefghijklmnopq",
                 description_format: :markdown,
                 sharing: :unique
               })

      assert "should be at most 16 character(s)" in errors_on(changeset).username
    end

    test "rejects usernames with unsupported characters" do
      account = account_fixture()

      assert {:error, changeset} =
               Social.create_profile_for_account(account, %{
                 username: "alpha profile",
                 description_format: :markdown,
                 sharing: :unique
               })

      assert "must contain only letters, numbers, _, ., and -" in errors_on(changeset).username
    end
  end

  describe "delete_group/2" do
    test "deletes a non-root leaf group for a member" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delgrp-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "deleteable-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, _deleted_group} = Social.delete_group(profile, group)
      assert_raise Ecto.NoResultsError, fn -> Social.get_group!(group.id) end
    end

    test "rejects deleting the root group" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delroot-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert {:error, :cannot_delete_root_group} =
               Social.delete_group(profile, Social.get_root_group!())
    end

    test "rejects deleting a group with child groups" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delparent-pr",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, parent_group} =
        Social.create_group(profile, root_group, %{
          "name" => "delete-parent-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _child_group} =
        Social.create_group(profile, parent_group, %{
          "name" => "delete-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:error, :group_has_children} = Social.delete_group(profile, parent_group)
      assert Social.get_group!(parent_group.id).id == parent_group.id
    end
  end

  describe "shared profile invitations" do
    test "inviting and accepting links a shared profile to the accepting account" do
      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "shared-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "shared-invitee",
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

      assert [_invitee_profile, linked_profile] =
               Social.list_profiles_for_account(invitee_account)

      assert linked_profile.id == shared_profile.id

      assert current_profile = Social.get_account_current_profile(invitee_account)
      assert current_profile.id == invitee_profile.id

      assert [] == Social.list_pending_profile_invitations(invitee_profile)
    end

    test "sends push notifications to the invitee when sent and the inviter when accepted" do
      request_pid = self()
      configure_push_notifications(request_pid)

      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, shared_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "sharepush-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "sharepush-inv",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, inviter_subscription} =
        Accounts.upsert_push_subscription(inviter_account, valid_push_subscription_attrs())

      {:ok, invitee_subscription} =
        Accounts.upsert_push_subscription(invitee_account, valid_push_subscription_attrs())

      assert {:ok, invitation} =
               Social.invite_profile_to_profile(
                 inviter_account,
                 shared_profile,
                 shared_profile,
                 invitee_profile
               )

      assert_receive {:push_request, request_options}
      assert request_options[:url] == invitee_subscription.endpoint
      refute_receive {:push_request, _unexpected_request}

      assert {:ok, _accepted_invitation} =
               Social.accept_profile_invitation(invitation, invitee_profile, invitee_account)

      assert_receive {:push_request, request_options}
      assert request_options[:url] == inviter_subscription.endpoint
      refute_receive {:push_request, _unexpected_request}
    end
  end

  describe "count_group_members/1" do
    test "returns the current number of members in a group" do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "mcount-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "mcount-invitee",
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

  describe "group join requests" do
    test "allows a non-member to request access to a public group and the creator to accept it" do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "jreq-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "jreq-requester",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "join-request-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, request} = Social.request_group_access(requester_profile, group)
      assert Social.count_pending_group_join_requests(group) == 1
      assert Social.get_pending_group_join_request(requester_profile, group).id == request.id

      assert [%{id: request_id, requester: %{id: requester_id}}] =
               Social.list_pending_group_join_requests(group)

      assert request_id == request.id
      assert requester_id == requester_profile.id

      assert {:ok, accepted_profile} =
               Social.accept_group_join_request(owner_profile, group, request.id)

      assert accepted_profile.id == requester_profile.id
      assert Social.member_of_group?(requester_profile, group)
      assert Social.count_pending_group_join_requests(group) == 0
      assert is_nil(Social.get_pending_group_join_request(requester_profile, group))
    end

    test "rejects access requests for private groups and lets the creator reject a pending request" do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "jreqpriv-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "jreqpriv-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, private_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "join-request-private-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:error, :group_not_public} =
               Social.request_group_access(requester_profile, private_group)

      {:ok, public_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "join-request-public-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, request} = Social.request_group_access(requester_profile, public_group)

      assert {:ok, _request} =
               Social.reject_group_join_request(owner_profile, public_group, request.id)

      refute Social.member_of_group?(requester_profile, public_group)
      assert Social.count_pending_group_join_requests(public_group) == 0
      assert is_nil(Social.get_pending_group_join_request(requester_profile, public_group))
    end

    test "sending an invitation clears the matching pending join request" do
      owner_account = account_fixture()
      requester_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "jreqinv-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, requester_profile} =
        Social.create_profile_for_account(requester_account, %{
          username: "jreqinv-req",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "join-request-invite-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      assert {:ok, _request} = Social.request_group_access(requester_profile, group)
      assert Social.count_pending_group_join_requests(group) == 1

      assert {:ok, _invitation} =
               Social.invite_profile_to_group(owner_profile, group, requester_profile)

      assert Social.count_pending_group_join_requests(group) == 0
      assert is_nil(Social.get_pending_group_join_request(requester_profile, group))
    end
  end

  describe "remove_group_member/3" do
    test "allows the group creator to remove another member" do
      owner_account = account_fixture()
      member_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "rm-member-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "rm-member-tgt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "remove-member-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, member_profile)

      assert Social.member_of_group?(member_profile, group)

      assert {:ok, removed_profile} =
               Social.remove_group_member(owner_profile, group, member_profile.id)

      assert removed_profile.id == member_profile.id
      refute Social.member_of_group?(member_profile, group)
      assert Social.count_group_members(group) == 1
    end

    test "rejects removal by a non-creator member" do
      owner_account = account_fixture()
      member_account = account_fixture()
      target_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "rmem-own-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "rmem-noncrt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, target_profile} =
        Social.create_profile_for_account(target_account, %{
          username: "rmem-tgt-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "remove-member-group-2",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, member_invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_member_invitation} =
               Social.accept_group_invitation(member_invitation, member_profile)

      assert {:ok, target_invitation} =
               Social.invite_profile_to_group(owner_profile, group, target_profile)

      assert {:ok, _accepted_target_invitation} =
               Social.accept_group_invitation(target_invitation, target_profile)

      assert {:error, :not_permitted} =
               Social.remove_group_member(member_profile, group, target_profile.id)

      assert Social.member_of_group?(target_profile, group)
    end
  end

  describe "group invitations push notifications" do
    test "sends push notifications to the invitee when sent and the inviter when accepted" do
      request_pid = self()
      configure_push_notifications(request_pid)

      inviter_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, inviter_profile} =
        Social.create_profile_for_account(inviter_account, %{
          username: "grppush-inv",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "grppush-tgt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(inviter_profile, root_group, %{
          "name" => "group-push-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, inviter_subscription} =
        Accounts.upsert_push_subscription(inviter_account, valid_push_subscription_attrs())

      {:ok, invitee_subscription} =
        Accounts.upsert_push_subscription(invitee_account, valid_push_subscription_attrs())

      assert {:ok, invitation} =
               Social.invite_profile_to_group(inviter_profile, group, invitee_profile)

      assert_receive {:push_request, request_options}
      assert request_options[:url] == invitee_subscription.endpoint
      refute_receive {:push_request, _unexpected_request}

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      assert_receive {:push_request, request_options}
      assert request_options[:url] == inviter_subscription.endpoint
      refute_receive {:push_request, _unexpected_request}
    end
  end

  describe "create_value/3 push notifications" do
    test "sends push notifications to other group members but not the sender" do
      request_pid = self()
      original_config = Application.get_env(:potok_ide, PushNotifications, [])

      on_exit(fn ->
        Application.put_env(:potok_ide, PushNotifications, original_config)
      end)

      Application.put_env(
        :potok_ide,
        PushNotifications,
        ttl: 60,
        vapid_subject: "mailto:test@example.com",
        vapid_public_key:
          Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
        vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        request_fun: fn options ->
          send(request_pid, {:push_request, options})
          {:ok, %Req.Response{status: 201, body: ""}}
        end
      )

      sender_account = account_fixture()
      recipient_account = account_fixture()
      non_member_account = account_fixture()

      {:ok, sender_profile} =
        Social.create_profile_for_account(sender_account, %{
          username: "valpush-send",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, recipient_profile} =
        Social.create_profile_for_account(recipient_account, %{
          username: "valpush-rec",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _non_member_profile} =
        Social.create_profile_for_account(non_member_account, %{
          username: "valpush-non",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(sender_profile, root_group, %{
          "name" => "value-push-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(sender_profile, group, recipient_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, recipient_profile)

      {:ok, sender_subscription} =
        Accounts.upsert_push_subscription(sender_account, valid_push_subscription_attrs())

      {:ok, recipient_subscription} =
        Accounts.upsert_push_subscription(recipient_account, valid_push_subscription_attrs())

      {:ok, _non_member_subscription} =
        Accounts.upsert_push_subscription(non_member_account, valid_push_subscription_attrs())

      assert {:ok, _value} =
               Social.create_value(sender_profile, group, %{
                 "content" => "Fresh group value",
                 "content_format" => :markdown
               })

      assert_receive {:push_request, request_options}
      assert request_options[:url] == recipient_subscription.endpoint
      refute request_options[:url] == sender_subscription.endpoint
      refute_receive {:push_request, _other_request}
    end

    test "pushes to every device of each member account and skips members without one" do
      request_pid = self()
      original_config = Application.get_env(:potok_ide, PushNotifications, [])
      on_exit(fn -> Application.put_env(:potok_ide, PushNotifications, original_config) end)

      Application.put_env(
        :potok_ide,
        PushNotifications,
        ttl: 60,
        vapid_subject: "mailto:test@example.com",
        vapid_public_key:
          Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
        vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        request_fun: fn options ->
          send(request_pid, {:push_request, options[:url]})
          {:ok, %Req.Response{status: 201, body: ""}}
        end
      )

      [sender, two_devices, no_device] =
        for name <- ["devices-send", "devices-two", "devices-none"] do
          account = account_fixture()

          {:ok, profile} =
            Social.create_profile_for_account(account, %{
              username: name,
              profile_picture_url: nil,
              description: "",
              description_format: :markdown,
              sharing: :unique
            })

          {account, profile}
        end

      {_sender_account, sender_profile} = sender

      {:ok, group} =
        Social.create_group(sender_profile, Social.get_root_group!(), %{
          "name" => "devices-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      for {_account, profile} <- [two_devices, no_device] do
        {:ok, invitation} = Social.invite_profile_to_group(sender_profile, group, profile)
        {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
      end

      {two_devices_account, _profile} = two_devices

      endpoints =
        for _device <- 1..2 do
          {:ok, subscription} =
            Accounts.upsert_push_subscription(
              two_devices_account,
              valid_push_subscription_attrs()
            )

          subscription.endpoint
        end

      assert {:ok, _value} =
               Social.create_value(sender_profile, group, %{
                 "content" => "to both devices",
                 "content_format" => :markdown
               })

      assert_receive {:push_request, first_url}
      assert_receive {:push_request, second_url}
      assert Enum.sort([first_url, second_url]) == Enum.sort(endpoints)
      refute_receive {:push_request, _other_url}
    end

    test "does not send push notifications for data values" do
      request_pid = self()
      original_config = Application.get_env(:potok_ide, PushNotifications, [])

      on_exit(fn ->
        Application.put_env(:potok_ide, PushNotifications, original_config)
      end)

      Application.put_env(
        :potok_ide,
        PushNotifications,
        ttl: 60,
        vapid_subject: "mailto:test@example.com",
        vapid_public_key:
          Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
        vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        request_fun: fn options ->
          send(request_pid, {:push_request, options})
          {:ok, %Req.Response{status: 201, body: ""}}
        end
      )

      sender_account = account_fixture()
      recipient_account = account_fixture()

      {:ok, sender_profile} =
        Social.create_profile_for_account(sender_account, %{
          username: "vp-data-send",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, recipient_profile} =
        Social.create_profile_for_account(recipient_account, %{
          username: "vp-data-rec",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(sender_profile, root_group, %{
          "name" => "value-push-data-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(sender_profile, group, recipient_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, recipient_profile)

      {:ok, _sender_subscription} =
        Accounts.upsert_push_subscription(sender_account, valid_push_subscription_attrs())

      {:ok, _recipient_subscription} =
        Accounts.upsert_push_subscription(recipient_account, valid_push_subscription_attrs())

      assert {:ok, value} =
               Social.create_value(sender_profile, group, %{
                 "content" => "Structured data payload",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert value.is_data == true
      refute_receive {:push_request, _request}
    end
  end

  describe "create_value/3" do
    test "defaults is_data to false and accepts explicit true" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "valdata-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      group = Social.get_root_group!()

      assert {:ok, default_value} =
               Social.create_value(profile, group, %{
                 "content" => "regular value",
                 "content_format" => :markdown
               })

      assert default_value.is_data == false

      assert {:ok, data_value} =
               Social.create_value(profile, group, %{
                 "content" => "structured value",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert data_value.is_data == true

      values_by_id =
        group
        |> Social.list_group_values()
        |> Map.new(fn value -> {value.id, value} end)

      data_values_by_id =
        group
        |> Social.list_group_data_values()
        |> Map.new(fn value -> {value.id, value} end)

      assert values_by_id[default_value.id].is_data == false
      assert data_values_by_id[data_value.id].is_data == true
    end

    test "keeps the group's last_value_at on its newest chat value" do
      {:ok, profile} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "lastval-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(profile, Social.get_root_group!(), %{
          "name" => "last-value-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      last_value_at = fn -> PotokIde.Repo.get!(Group, group.id).last_value_at end
      assert last_value_at.() == nil

      {:ok, older} =
        Social.create_value(profile, group, %{"content" => "older", "content_format" => :markdown})

      older_at = DateTime.add(older.inserted_at, -60, :second)

      from(v in PotokIde.Social.Value, where: v.id == ^older.id)
      |> PotokIde.Repo.update_all(set: [inserted_at: older_at])

      {:ok, newer} =
        Social.create_value(profile, group, %{"content" => "newer", "content_format" => :markdown})

      assert last_value_at.() == newer.inserted_at

      # App data never moves it.
      {:ok, _data} = Social.create_data_value(profile, group, %{"content" => "data:"})
      assert last_value_at.() == newer.inserted_at

      # Deleting the newest falls back to the one before it, then to none.
      {:ok, _deleted} = Social.delete_value(profile, newer)
      assert last_value_at.() == older_at

      {:ok, _deleted} = Social.delete_value(profile, older)
      assert last_value_at.() == nil
    end
  end

  describe "delete_value/2" do
    test "deletes a value created by the profile" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delval-own",
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
          username: "delval-auth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "delval-unauth",
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

  describe "delete_group_data_values/2" do
    test "allows the group creator to delete all data values without deleting regular values" do
      owner_account = account_fixture()
      member_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "deldata-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "deldata-mem",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "delete-data-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, member_profile)

      assert {:ok, regular_value} =
               Social.create_value(owner_profile, group, %{
                 "content" => "keep me",
                 "content_format" => :markdown
               })

      assert {:ok, _owner_data_value} =
               Social.create_value(owner_profile, group, %{
                 "content" => "owner data",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert {:ok, _member_data_value} =
               Social.create_value(member_profile, group, %{
                 "content" => "member data",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert {:ok, 2} = Social.delete_group_data_values(owner_profile, group)

      assert [] == Social.list_group_data_values(group)
      assert [%{id: retained_id}] = Social.list_group_values(group)
      assert retained_id == regular_value.id
    end

    test "rejects deleting group data values for a non-creator member" do
      owner_account = account_fixture()
      member_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "deldata-own2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "deldata-mem2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "delete-data-group-2",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, member_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, member_profile)

      assert {:ok, _data_value} =
               Social.create_value(owner_profile, group, %{
                 "content" => "owner data",
                 "content_format" => :markdown,
                 "is_data" => true
               })

      assert {:error, :not_permitted} = Social.delete_group_data_values(member_profile, group)
      assert Social.count_group_data_values(group) == 1
    end
  end

  defp valid_push_subscription_attrs do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      endpoint:
        "https://updates.push.services.mozilla.com/wpush/v2/#{System.unique_integer([:positive])}",
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      p256dh: Base.url_encode64(public_key, padding: false),
      expires_at: nil,
      user_agent: "ExUnit"
    }
  end

  defp configure_push_notifications(request_pid) do
    original_config = Application.get_env(:potok_ide, PushNotifications, [])

    on_exit(fn ->
      Application.put_env(:potok_ide, PushNotifications, original_config)
    end)

    Application.put_env(
      :potok_ide,
      PushNotifications,
      ttl: 60,
      vapid_subject: "mailto:test@example.com",
      vapid_public_key: Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
      vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      request_fun: fn options ->
        send(request_pid, {:push_request, options})
        {:ok, %Req.Response{status: 201, body: ""}}
      end
    )
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
          username: "editval-auth",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "editval-una",
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
          username: "social-mem",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "social-other",
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

    test "paginates child groups by unread count and latest value date" do
      owner_account = account_fixture()
      writer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "ordchild-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, writer_profile} =
        Social.create_profile_for_account(writer_account, %{
          username: "ordchild-wrt",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, newest_unread_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "alpha-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, older_unread_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "beta-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, read_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "gamma-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      for group <- [newest_unread_group, older_unread_group, read_group] do
        assert {:ok, invitation} =
                 Social.invite_profile_to_group(owner_profile, group, writer_profile)

        assert {:ok, _accepted_invitation} =
                 Social.accept_group_invitation(invitation, writer_profile)
      end

      assert {:ok, older_unread_value} =
               Social.create_value(writer_profile, older_unread_group, %{
                 "content" => "older unread value",
                 "content_format" => :markdown
               })

      assert {:ok, read_value} =
               Social.create_value(writer_profile, read_group, %{
                 "content" => "read value",
                 "content_format" => :markdown
               })

      assert {:ok, newest_unread_value} =
               Social.create_value(writer_profile, newest_unread_group, %{
                 "content" => "newest unread value",
                 "content_format" => :markdown
               })

      base_inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)

      from(v in PotokIde.Social.Value, where: v.id == ^older_unread_value.id)
      |> PotokIde.Repo.update_all(
        set: [
          inserted_at: DateTime.add(base_inserted_at, -120, :second),
          updated_at: DateTime.add(base_inserted_at, -120, :second)
        ]
      )

      from(v in PotokIde.Social.Value, where: v.id == ^read_value.id)
      |> PotokIde.Repo.update_all(
        set: [
          inserted_at: DateTime.add(base_inserted_at, -60, :second),
          updated_at: DateTime.add(base_inserted_at, -60, :second)
        ]
      )

      from(v in PotokIde.Social.Value, where: v.id == ^newest_unread_value.id)
      |> PotokIde.Repo.update_all(
        set: [inserted_at: base_inserted_at, updated_at: base_inserted_at]
      )

      # The list sorts by `groups.last_value_at`, which follows each group's newest value.
      for {group, seconds_ago} <- [
            {older_unread_group, 120},
            {read_group, 60},
            {newest_unread_group, 0}
          ] do
        from(g in Group, where: g.id == ^group.id)
        |> PotokIde.Repo.update_all(
          set: [last_value_at: DateTime.add(base_inserted_at, -seconds_ago, :second)]
        )
      end

      assert :ok = Social.mark_group_values_read(owner_profile, read_group)

      assert Enum.map(
               Social.list_child_groups_for_profile(root_group, owner_profile, limit: 2),
               & &1.id
             ) == [
               newest_unread_group.id,
               older_unread_group.id
             ]

      assert Enum.map(Social.list_child_groups_for_profile(root_group, owner_profile), & &1.id) ==
               [
                 newest_unread_group.id,
                 older_unread_group.id,
                 read_group.id
               ]
    end
  end

  describe "group unread counts" do
    test "aggregates unread values across sub-groups and marks the current group as read" do
      owner_account = account_fixture()
      writer_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "unread-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, writer_profile} =
        Social.create_profile_for_account(writer_account, %{
          username: "unread-writer",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "unread-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, grandchild_group} =
        Social.create_group(owner_profile, child_group, %{
          "name" => "unread-grandchild",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, hidden_child_group} =
        Social.create_group(writer_profile, root_group, %{
          "name" => "writer-private-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, child_group, writer_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, writer_profile)

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, grandchild_group, writer_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, writer_profile)

      assert {:ok, _child_value} =
               Social.create_value(writer_profile, child_group, %{
                 "content" => "child unread value",
                 "content_format" => :markdown
               })

      assert {:ok, _grandchild_value} =
               Social.create_value(writer_profile, grandchild_group, %{
                 "content" => "grandchild unread value",
                 "content_format" => :markdown
               })

      assert {:ok, _root_value} =
               Social.create_value(writer_profile, root_group, %{
                 "content" => "root unread value",
                 "content_format" => :markdown
               })

      assert {:ok, _hidden_child_value} =
               Social.create_value(writer_profile, hidden_child_group, %{
                 "content" => "hidden unread value",
                 "content_format" => :markdown
               })

      unread_counts =
        Social.list_group_unread_counts(owner_profile, [
          root_group,
          child_group,
          grandchild_group
        ])

      assert unread_counts[root_group.id] == 2
      assert unread_counts[child_group.id] == 2
      assert unread_counts[grandchild_group.id] == 1

      # The flat root query must agree with the recursive one.
      assert Social.count_root_group_unread_values(owner_profile) == 2
      assert Social.count_root_group_unread_values(writer_profile) == 0

      # Root children summary: child_group (non-direct, 2 unread); the writer's
      # private child is not visible to the owner.
      assert Social.child_group_unread_summary(owner_profile, root_group) == %{
               direct: 0,
               other: 2
             }

      assert {:ok, _direct_group} =
               Social.get_or_create_direct_group(writer_profile, owner_profile)

      direct_group = Social.get_or_create_direct_group(writer_profile, owner_profile) |> elem(1)

      assert {:ok, _direct_value} =
               Social.create_value(writer_profile, direct_group, %{
                 "content" => "direct unread value",
                 "content_format" => :markdown
               })

      assert Social.child_group_unread_summary(owner_profile, root_group) == %{
               direct: 1,
               other: 2
             }

      assert Social.count_root_group_unread_values(owner_profile) == 3

      writer_unread_counts =
        Social.list_group_unread_counts(writer_profile, [
          root_group,
          child_group,
          grandchild_group
        ])

      assert writer_unread_counts[root_group.id] == 0
      assert writer_unread_counts[child_group.id] == 0
      assert writer_unread_counts[grandchild_group.id] == 0

      assert :ok = Social.mark_group_values_read(owner_profile, child_group)

      unread_counts_after_read =
        Social.list_group_unread_counts(owner_profile, [
          root_group,
          child_group,
          grandchild_group
        ])

      assert unread_counts_after_read[root_group.id] == 2
      assert unread_counts_after_read[child_group.id] == 1
      assert unread_counts_after_read[grandchild_group.id] == 1
      assert Social.count_root_group_unread_values(owner_profile) == 2

      # Marking an already-read group again must not broadcast.
      forward_profile_messages(owner_profile)
      assert :ok = Social.mark_group_values_read(owner_profile, child_group)
      refute_receive {:forwarded, {:group_unread_counts_updated, _profile_id, _group_id}}
    end

    test "unread_overview/1 gives own and sub-group counts; a value id moves the marker" do
      [owner_profile, writer_profile] =
        for name <- ["overview-own", "overview-wri"] do
          {:ok, profile} =
            Social.create_profile_for_account(account_fixture(), %{
              username: name,
              profile_picture_url: nil,
              description: "",
              description_format: :markdown,
              sharing: :unique
            })

          profile
        end

      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "overview-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, grandchild_group} =
        Social.create_group(owner_profile, child_group, %{
          "name" => "overview-grandchild",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      for group <- [child_group, grandchild_group] do
        {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
        {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      end

      post = fn group, content ->
        {:ok, value} =
          Social.create_value(writer_profile, group, %{
            "content" => content,
            "content_format" => :markdown
          })

        value
      end

      first_value = post.(child_group, "first")
      _second_value = post.(child_group, "second")
      _grandchild_value = post.(grandchild_group, "below")

      overview = Social.unread_overview(owner_profile)
      root_id = root_group.id

      assert overview.total == 3
      assert overview.groups[root_group.id].subtree == 3

      assert %{own: 2, subtree: 3, parent_id: ^root_id, direct?: false, visible?: true} =
               overview.groups[child_group.id]

      assert %{own: 1, subtree: 1} = overview.groups[grandchild_group.id]

      assert Social.unread_counts_for(overview, [child_group.id, -1]) == %{
               child_group.id => 3,
               -1 => 0
             }

      assert Social.child_unread_summary(overview, child_group.id) == %{direct: 0, other: 1}
      assert Social.unread_overview(nil) == %{total: 0, as_of: 0, groups: %{}}

      assert :ok = Social.mark_group_values_read(owner_profile, child_group, first_value.id)
      assert %{own: 1, subtree: 2} = Social.unread_overview(owner_profile).groups[child_group.id]

      # The marker never moves back.
      assert :ok = Social.mark_group_values_read(owner_profile, child_group)
      assert :ok = Social.mark_group_values_read(owner_profile, child_group, first_value.id)
      assert %{own: 0, subtree: 1} = Social.unread_overview(owner_profile).groups[child_group.id]
    end

    test "a new value reaches the other members as one more unread value, counted without a query" do
      [owner_profile, writer_profile] = unread_profiles(["delta-owner", "delta-writer"])
      root_group = Social.get_root_group!()
      child_group = unread_group!(owner_profile, root_group, "delta-child")
      grandchild_group = unread_group!(owner_profile, child_group, "delta-grandchild")

      for group <- [child_group, grandchild_group] do
        {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
        {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      end

      before = Social.unread_overview(owner_profile)
      Social.subscribe_profile(owner_profile)
      forward_profile_messages(writer_profile)

      {:ok, value} =
        Social.create_value(writer_profile, grandchild_group, %{"content" => "news"})

      owner_id = owner_profile.id
      writer_id = writer_profile.id
      grandchild_id = grandchild_group.id
      assert_receive {:group_value_unread, ^owner_id, unread}

      assert %{group_id: ^grandchild_id} = unread
      assert unread.value_id == value.id

      assert MapSet.new(unread.chain, & &1.id) ==
               MapSet.new([root_group.id, child_group.id, grandchild_group.id])

      # The writer read it by posting it; the writer's other pages recount.
      assert_receive {:forwarded, {:group_unread_counts_updated, ^writer_id, ^grandchild_id}}
      refute_received {:forwarded, {:group_value_unread, _profile_id, _unread}}

      {:ok, added} = Social.add_unread_value(before, unread, MapSet.new())
      counted = Social.unread_overview(owner_profile)

      assert added.total == counted.total

      assert Map.new(added.groups, &unread_entry/1) == Map.new(counted.groups, &unread_entry/1)
      assert Social.add_unread_value(counted, unread, MapSet.new()) == :counted

      # The value's own group is a membership; the others only the page can tell.
      assert added.groups[grandchild_group.id].visible? == true
      assert added.groups[child_group.id].visible? == nil

      {:ok, shown} = Social.add_unread_value(before, unread, MapSet.new([child_group.id]))
      assert shown.groups[child_group.id].visible? == true
    end

    test "root values reach no one, and a read is not echoed to the page that marked it" do
      [owner_profile, writer_profile] = unread_profiles(["echo-owner", "echo-writer"])
      root_group = Social.get_root_group!()
      group = unread_group!(owner_profile, root_group, "echo-group")
      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      {:ok, _value} = Social.create_value(writer_profile, group, %{"content" => "unread"})

      Social.subscribe_profile(owner_profile)
      forward_profile_messages(owner_profile)

      {:ok, _root_value} = Social.create_value(writer_profile, root_group, %{"content" => "root"})
      refute_receive {:group_value_unread, _profile_id, _unread}

      owner_id = owner_profile.id
      group_id = group.id
      assert :ok = Social.mark_group_values_read(owner_profile, group)
      assert_receive {:forwarded, {:group_unread_counts_updated, ^owner_id, ^group_id}}
      refute_received {:group_unread_counts_updated, _profile_id, _group_id}
    end

    test "sort_child_groups/2 orders sub-groups like the database" do
      [owner_profile, writer_profile] = unread_profiles(["sort-owner", "sort-writer"])
      parent = unread_group!(owner_profile, Social.get_root_group!(), "sort-parent")

      [quiet, one, read, two] =
        for name <- ~w(quiet one read two),
            do: unread_group!(owner_profile, parent, "sort-#{name}")

      for group <- [one, two] do
        {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
        {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      end

      {:ok, _value} = Social.create_value(writer_profile, one, %{"content" => "one"})
      {:ok, _value} = Social.create_value(writer_profile, two, %{"content" => "two"})
      {:ok, _value} = Social.create_value(writer_profile, two, %{"content" => "two again"})
      {:ok, _value} = Social.create_value(owner_profile, read, %{"content" => "own"})

      groups = Social.list_child_groups_for_profile(parent, owner_profile)
      overview = Social.unread_overview(owner_profile)

      assert Enum.map(groups, & &1.id) == Enum.map([two, one, read, quiet], & &1.id)

      assert groups
             |> Enum.reverse()
             |> Social.sort_child_groups(overview)
             |> Enum.map(& &1.id) == Enum.map(groups, & &1.id)
    end

    test "a page of sub-groups comes with the count of all, like the list and the count" do
      [owner_profile, writer_profile] = unread_profiles(["page-owner", "page-writer"])
      parent = unread_group!(owner_profile, Social.get_root_group!(), "page-parent")

      [_first, _second, third] =
        for name <- ~w(first second third),
            do: unread_group!(owner_profile, parent, "page-#{name}")

      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, third, writer_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      {:ok, _value} = Social.create_value(writer_profile, third, %{"content" => "unread"})

      # A thread of a value in the parent is one more sub-group of it.
      {:ok, value} = Social.create_value(owner_profile, parent, %{"content" => "thread start"})

      {:ok, _thread} =
        Social.get_or_create_value_thread(owner_profile, parent, value, %{"name" => "talk"})

      for opts <- [[], [limit: 2], [limit: 0], [search: "thi"], [is_thread: false]] do
        assert Social.list_child_groups_page_for_profile(parent, owner_profile, opts) ==
                 {Social.list_child_groups_for_profile(parent, owner_profile, opts),
                  Social.count_child_groups_for_profile(parent, owner_profile, opts)}
      end

      third_id = third.id

      assert {[%{id: ^third_id}], 4} =
               Social.list_child_groups_page_for_profile(parent, owner_profile, limit: 1)

      assert {_groups, 3} =
               Social.list_child_groups_page_for_profile(parent, owner_profile, is_thread: false)
    end

    test "unread_overview/1 keeps as_of when nothing is unread" do
      [profile] = unread_profiles(["asof-quiet"])
      group = unread_group!(profile, Social.get_root_group!(), "asof-group")
      {:ok, value} = Social.create_value(profile, group, %{"content" => "own"})

      overview = Social.unread_overview(profile)

      assert %{total: 0, groups: groups} = overview
      assert groups == %{}
      assert overview.as_of >= value.id
    end
  end

  defp unread_profiles(names) do
    for name <- names do
      {:ok, profile} =
        Social.create_profile_for_account(account_fixture(), %{
          username: name,
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      profile
    end
  end

  defp unread_group!(profile, parent, name) do
    {:ok, group} =
      Social.create_group(profile, parent, %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    group
  end

  defp unread_entry({group_id, entry}),
    do: {group_id, Map.take(entry, [:own, :subtree, :parent_id, :direct?])}

  # Subscribes another process to the profile's topic, as another page of the
  # profile would be, and forwards what it gets to the test: a broadcast from
  # the test process itself may skip the test process.
  defp forward_profile_messages(profile) do
    test_pid = self()

    start_supervised!(
      Supervisor.child_spec(
        {Task,
         fn ->
           Social.subscribe_profile(profile)
           send(test_pid, :forwarding)
           forward_messages(test_pid)
         end},
        id: {:forward_profile_messages, profile.id}
      )
    )

    assert_receive :forwarding
  end

  defp forward_messages(test_pid) do
    receive do
      message ->
        send(test_pid, {:forwarded, message})
        forward_messages(test_pid)
    end
  end

  describe "list_group_path/1" do
    test "returns the path from the root down to the group" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "path-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "path-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, grandchild_group} =
        Social.create_group(profile, child_group, %{
          "name" => "path-grandchild",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert Enum.map(Social.list_group_path(grandchild_group), & &1.id) ==
               [root_group.id, child_group.id, grandchild_group.id]

      assert Enum.map(Social.list_group_path(root_group), & &1.id) == [root_group.id]
    end

    test "the visible path keeps the group, public ancestors and memberships" do
      [owner, viewer] = unread_profiles(["vpath-owner", "vpath-viewer"])
      root_group = Social.get_root_group!()
      private_group = unread_group!(owner, root_group, "vpath-private")

      {:ok, public_group} =
        Social.create_group(owner, private_group, %{
          "name" => "vpath-public",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      member_group = unread_group!(owner, public_group, "vpath-member")
      leaf_group = unread_group!(owner, member_group, "vpath-leaf")
      {:ok, invitation} = Social.invite_profile_to_group(owner, member_group, viewer)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, viewer)

      # The viewer is not in the private group, so it is left out of the path.
      assert Enum.map(Social.list_visible_group_path_for_profile(leaf_group, viewer), & &1.id) ==
               [root_group.id, public_group.id, member_group.id, leaf_group.id]

      # The owner sees the whole path, loaded like any other query loads groups.
      assert Social.list_visible_group_path_for_profile(leaf_group, owner) ==
               Social.list_group_path(leaf_group)

      assert [%Group{} = loaded] = Social.list_visible_group_path_for_profile(root_group, viewer)
      assert loaded.id == root_group.id
    end
  end

  describe "load_picture/1" do
    test "pictures are excluded from regular queries and loaded on demand" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "pic-owner",
          profile_picture_url: "https://example.com/pic.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert is_nil(Social.get_profile!(profile.id).profile_picture_url)

      assert Social.load_picture(Social.get_profile!(profile.id)).profile_picture_url ==
               "https://example.com/pic.png"

      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "pic-group",
          "group_picture_url" => "data:image/png;base64,QUJD",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert is_nil(Social.get_group!(group.id).group_picture_url)

      assert Social.load_picture(Social.get_group!(group.id)).group_picture_url ==
               "data:image/png;base64,QUJD"
    end
  end

  describe "app data values" do
    setup do
      account = account_fixture()

      {:ok, owner} =
        Social.create_profile_for_account(account, %{
          username: "app-data-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "app-data-member",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "app-data-group",
          "description" => "<p>app</p>",
          "description_format" => :html,
          "is_public" => false,
          "uses_api" => true
        })

      {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
      {:ok, _} = Social.accept_group_invitation(invitation, member)

      %{owner: owner, member: member, group: group}
    end

    test "create_data_value/3 skips read markers and unread broadcasts", %{
      owner: owner,
      member: member,
      group: group
    } do
      Social.subscribe_group(group)
      Social.subscribe_profile(member)

      assert {:ok, value} =
               Social.create_data_value(owner, group, %{
                 "content" => "data:",
                 "data" => ~s({"n": 1})
               })

      assert value.is_data
      assert value.data == %{"n" => 1}
      assert value.creator.id == owner.id

      assert_receive {:data_value_created, group_id, %{id: value_id}}
      assert group_id == group.id
      assert value_id == value.id

      refute_receive {:group_unread_counts_updated, _profile_id, _group_id}
      refute_receive {:value_created, _group_id, _value}

      refute Repo.exists?(
               from r in PotokIde.Social.GroupValueRead,
                 where: r.group_id == ^group.id and r.last_read_value_id == ^value.id
             )
    end

    test "create_value/3 routes is_data values to create_data_value/3", %{
      owner: owner,
      group: group
    } do
      Social.subscribe_group(group)

      assert {:ok, value} =
               Social.create_value(owner, group, %{"content" => "data:", "is_data" => true})

      assert value.is_data
      assert_receive {:data_value_created, _group_id, %{id: value_id}}
      assert value_id == value.id
    end

    test "list_group_data_value_rows/2 caps the limit and supports cursors", %{
      owner: owner,
      group: group
    } do
      values =
        for n <- 1..3 do
          {:ok, value} =
            Social.create_data_value(owner, group, %{"content" => "data:", "data" => %{"n" => n}})

          value
        end

      [first, second, third] = values

      assert {[row], true} = Social.list_group_data_value_rows(group, limit: 1)
      assert row.id == first.id
      assert row.creator_username == "app-data-owner"
      assert row.data == %{"n" => 1}

      assert {rows, false} = Social.list_group_data_value_rows(group, after_id: first.id)
      assert Enum.map(rows, & &1.id) == [second.id, third.id]

      assert {rows, false} = Social.list_group_data_value_rows(group, before_id: third.id)
      assert Enum.map(rows, & &1.id) == [first.id, second.id]

      assert {rows, false} = Social.list_group_data_value_rows(group, limit: 10_000)
      assert length(rows) == 3
    end
  end

  describe "list_group_values_page/2" do
    test "returns the newest page oldest-first and pages backwards by id" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "keyset-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(profile, Social.get_root_group!(), %{
          "name" => "keyset-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      ids =
        for n <- 1..5 do
          {:ok, value} =
            Social.create_value(profile, group, %{
              "content" => "keyset #{n}",
              "content_format" => :markdown
            })

          value.id
        end

      {:ok, _data_value} =
        Social.create_data_value(profile, group, %{"content" => "data:", "data" => %{}})

      assert {newest, true} = Social.list_group_values_page(group, limit: 2)
      assert Enum.map(newest, & &1.id) == Enum.slice(ids, 3, 2)

      assert {older, true} =
               Social.list_group_values_page(group, before_id: hd(newest).id, limit: 2)

      assert Enum.map(older, & &1.id) == Enum.slice(ids, 1, 2)

      assert {oldest, false} =
               Social.list_group_values_page(group, before_id: hd(older).id, limit: 2)

      assert Enum.map(oldest, & &1.id) == [hd(ids)]
    end
  end

  describe "toggle_value_reaction/4" do
    setup do
      {:ok, owner} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "react-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, outsider} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "react-outsider",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "react-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, value} =
        Social.create_value(owner, group, %{
          "content" => "react to me",
          "content_format" => :markdown
        })

      %{owner: owner, outsider: outsider, group: group, value: value}
    end

    test "adds a reaction and removes it on the second toggle", %{
      owner: owner,
      group: group,
      value: value
    } do
      assert value.reactions == []

      assert {:ok, reacted} = Social.toggle_value_reaction(owner, group, value, "👍")
      assert [%{emoji: "👍", profile_id: profile_id, profile: profile}] = reacted.reactions
      assert profile_id == owner.id
      assert profile.username == "react-owner"

      assert {:ok, unreacted} = Social.toggle_value_reaction(owner, group, value, "👍")
      assert unreacted.reactions == []
    end

    test "lets one profile hold several different emoji on a value", %{
      owner: owner,
      group: group,
      value: value
    } do
      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "👍")
      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "👍🏽")
      {:ok, reacted} = Social.toggle_value_reaction(owner, group, value, "👨‍👩‍👧")

      assert Enum.map(reacted.reactions, & &1.emoji) == ["👍", "👍🏽", "👨‍👩‍👧"]

      assert [%{reactions: reactions}] = Social.list_group_values(group)
      assert length(reactions) == 3
    end

    test "broadcasts the reloaded value to the group", %{
      owner: owner,
      group: group,
      value: value
    } do
      Social.subscribe_group(group)

      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "🎉")

      assert_receive {:value_updated, group_id, %{id: value_id, reactions: [%{emoji: "🎉"}]}}
      assert group_id == group.id
      assert value_id == value.id
    end

    test "pushes to the value's author when another member adds a reaction", %{
      owner: owner,
      group: group
    } do
      configure_push_notifications(self())
      author_account = account_fixture()

      {:ok, author} =
        Social.create_profile_for_account(author_account, %{
          username: "react-author",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitation} = Social.invite_profile_to_group(owner, group, author)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, author)

      {:ok, subscription} =
        author_account.id
        |> Accounts.get_account!()
        |> Accounts.upsert_push_subscription(valid_push_subscription_attrs())

      {:ok, value} = Social.create_value(author, group, %{"content" => "react to mine"})

      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "👍")
      assert_receive {:push_request, request_options}
      assert request_options[:url] == subscription.endpoint

      # Removing a reaction and reacting to one's own value notify nobody.
      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "👍")
      {:ok, _value} = Social.toggle_value_reaction(author, group, value, "🎉")
      refute_receive {:push_request, _request}
    end

    test "rejects profiles that are not group members", %{
      outsider: outsider,
      group: group,
      value: value
    } do
      assert {:error, :not_a_member_of_group} =
               Social.toggle_value_reaction(outsider, group, value, "👍")

      assert [%{reactions: []}] = Social.list_group_values(group)
    end

    test "rejects anything that is not a single emoji", %{
      owner: owner,
      group: group,
      value: value
    } do
      for invalid <- ["", "a", "ab", "7", " ", "👍👍"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Social.toggle_value_reaction(owner, group, value, invalid)

        assert changeset.errors[:emoji], "expected #{inspect(invalid)} to be rejected"
      end

      assert {:error, :invalid_emoji} = Social.toggle_value_reaction(owner, group, value, nil)
    end

    test "rejects data values and values from another group", %{
      owner: owner,
      group: group,
      value: value
    } do
      {:ok, data_value} =
        Social.create_data_value(owner, group, %{"content" => "data:", "data" => %{}})

      assert {:error, :value_not_found} =
               Social.toggle_value_reaction(owner, group, data_value, "👍")

      {:ok, other_group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "react-other",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:error, :value_not_found} =
               Social.toggle_value_reaction(owner, other_group, value, "👍")
    end

    test "deleting a value deletes its reactions", %{owner: owner, group: group, value: value} do
      {:ok, _value} = Social.toggle_value_reaction(owner, group, value, "👍")
      {:ok, _deleted} = Social.delete_value(owner, value)

      refute Repo.exists?(from r in PotokIde.Social.ValueReaction, where: r.value_id == ^value.id)
    end
  end

  describe "update_group_description/3" do
    test "updates only the description and notifies only the group" do
      account = account_fixture()

      {:ok, owner} =
        Social.create_profile_for_account(account, %{
          username: "desc-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "desc-group",
          "description" => "<p>old</p>",
          "description_format" => :html,
          "is_public" => false,
          "uses_api" => true
        })

      Social.subscribe_group(group)
      Social.subscribe_group(%Group{id: group.parent_id})

      assert {:ok, updated} =
               Social.update_group_description(owner, group, %{
                 "description" => "<p>new</p>",
                 "name" => "ignored"
               })

      assert updated.description == "<p>new</p>"
      assert updated.name == "desc-group"

      assert_receive {:group_description_updated, group_id}
      assert group_id == group.id
      refute_receive {:group_updated, _group_id}
    end

    test "rejects non-creators" do
      account = account_fixture()

      {:ok, owner} =
        Social.create_profile_for_account(account, %{
          username: "desc-owner-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other} =
        Social.create_profile_for_account(account_fixture(), %{
          username: "desc-other",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "desc-group-2",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:error, :not_permitted} =
               Social.update_group_description(other, group, %{"description" => "x"})
    end
  end

  describe "value replies" do
    setup do
      owner = reply_profile!("reply-owner")
      member = reply_profile!("reply-member")
      group = reply_group!(owner, "reply-group", %{"is_public" => false})
      add_member!(owner, group, member)

      {:ok, parent} = Social.create_value(owner, group, %{"content" => "the question"})

      %{owner: owner, member: member, group: group, parent: parent}
    end

    test "creates a reply that preloads its parent and the parent's author", %{
      member: member,
      group: group,
      parent: parent
    } do
      assert {:ok, reply} =
               Social.create_value(member, group, %{
                 "content" => "the answer",
                 "parent_id" => to_string(parent.id)
               })

      assert reply.parent_id == parent.id
      assert reply.parent.creator.username == "reply-owner"
    end

    test "rejects a parent from another group or a data value", %{
      owner: owner,
      group: group
    } do
      other_group = reply_group!(owner, "reply-other", %{"is_public" => false})
      {:ok, foreign} = Social.create_value(owner, other_group, %{"content" => "secret"})

      {:ok, data_value} =
        Social.create_data_value(owner, group, %{"content" => "data:", "data" => %{"k" => 1}})

      assert {:error, :invalid_parent} =
               Social.create_value(owner, group, %{"content" => "x", "parent_id" => foreign.id})

      assert {:error, :invalid_parent} =
               Social.create_value(owner, group, %{
                 "content" => "x",
                 "parent_id" => data_value.id
               })

      assert {:error, :invalid_parent} =
               Social.create_value(owner, group, %{"content" => "x", "parent_id" => "nope"})
    end

    test "ignores client-sent creator and group ids", %{
      owner: owner,
      member: member,
      group: group
    } do
      other_group = reply_group!(owner, "reply-elsewhere", %{})

      assert {:ok, value} =
               Social.create_value(member, group, %{
                 "content" => "mine",
                 "creator_id" => owner.id,
                 "group_id" => other_group.id
               })

      assert value.creator_id == member.id
      assert value.group_id == group.id
    end

    test "update_value only changes the content", %{owner: owner, group: group, parent: parent} do
      {:ok, other_parent} = Social.create_value(owner, group, %{"content" => "other"})

      {:ok, reply} =
        Social.create_value(owner, group, %{"content" => "r", "parent_id" => parent.id})

      assert {:ok, updated} =
               Social.update_value(owner, reply, %{
                 "content" => "edited",
                 "parent_id" => other_parent.id,
                 "group_id" => Social.get_root_group!().id
               })

      assert updated.content == "edited"
      assert updated.parent_id == parent.id
      assert updated.group_id == group.id
    end

    test "editing a parent re-broadcasts its replies", %{
      owner: owner,
      member: member,
      group: group,
      parent: parent
    } do
      {:ok, reply} =
        Social.create_value(member, group, %{"content" => "r", "parent_id" => parent.id})

      Social.subscribe_group(group)

      {:ok, _parent} = Social.update_value(owner, parent, %{"content" => "the new question"})

      reply_id = reply.id

      assert_receive {:value_updated, _group_id,
                      %{id: ^reply_id, parent: %{content: "the new question"}}}
    end

    test "deleting a parent re-broadcasts its replies without the parent", %{
      owner: owner,
      member: member,
      group: group,
      parent: parent
    } do
      {:ok, reply} =
        Social.create_value(member, group, %{"content" => "r", "parent_id" => parent.id})

      Social.subscribe_group(group)

      {:ok, _deleted} = Social.delete_value(owner, parent)

      reply_id = reply.id
      assert_receive {:value_updated, _group_id, %{id: ^reply_id, parent_id: nil, parent: nil}}
    end
  end

  describe "get_or_create_value_thread/4" do
    setup do
      owner = reply_profile!("thread-owner")
      member = reply_profile!("thread-member")
      outsider = reply_profile!("thread-outsider")
      group = reply_group!(owner, "thread-group", %{"is_public" => true})
      add_member!(owner, group, member)

      {:ok, value} = Social.create_value(owner, group, %{"content" => "start a thread"})

      %{owner: owner, member: member, outsider: outsider, group: group, value: value}
    end

    test "creates a chat sub-group of the value's group with all of its members", %{
      owner: owner,
      member: member,
      group: group,
      value: value
    } do
      assert {:ok, thread} =
               Social.get_or_create_value_thread(member, group, value, %{"name" => "Thread name"})

      assert thread.name == "Thread name"
      assert thread.parent_id == group.id
      assert thread.parent_value_id == value.id
      assert thread.creator_id == member.id
      assert thread.home_page == :chat
      assert thread.is_public
      refute thread.is_direct

      member_ids = thread |> Social.list_group_members() |> Enum.map(& &1.id) |> Enum.sort()
      assert member_ids == Enum.sort([owner.id, member.id])
    end

    test "returns the same thread on later calls and adds members who joined since", %{
      owner: owner,
      group: group,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "t"})

      latecomer = reply_profile!("thread-late")
      add_member!(owner, group, latecomer)
      refute Social.member_of_group?(latecomer, thread)

      assert {:ok, same_thread} =
               Social.get_or_create_value_thread(latecomer, group, value, %{"name" => "other"})

      assert same_thread.id == thread.id
      assert same_thread.name == "t"
      assert Social.member_of_group?(latecomer, thread)
    end

    test "broadcasts the value with its thread to the group", %{
      owner: owner,
      group: group,
      value: value
    } do
      Social.subscribe_group(group)

      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "t"})

      value_id = value.id
      thread_id = thread.id
      assert_receive {:value_updated, _group_id, %{id: ^value_id, thread: %Group{id: ^thread_id}}}

      assert %{thread: %Group{id: ^thread_id}} = Social.get_value_for_display(value.id)
    end

    test "rejects non-members, foreign values and direct groups", %{
      owner: owner,
      member: member,
      outsider: outsider,
      group: group,
      value: value
    } do
      assert {:error, :not_a_member_of_group} =
               Social.get_or_create_value_thread(outsider, group, value, %{"name" => "t"})

      other_group = reply_group!(owner, "thread-other", %{})

      assert {:error, :value_not_found} =
               Social.get_or_create_value_thread(owner, other_group, value, %{"name" => "t"})

      {:ok, direct} = Social.get_or_create_direct_group(owner, member)
      {:ok, direct_value} = Social.create_value(owner, direct, %{"content" => "dm"})

      assert {:error, :threads_not_supported} =
               Social.get_or_create_value_thread(owner, direct, direct_value, %{"name" => "t"})
    end

    test "allows only one group per value", %{owner: owner, group: group, value: value} do
      {:ok, _thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "t"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_group(owner, group, %{
                 "name" => "second",
                 "parent_value_id" => to_string(value.id)
               })

      assert {"has already been taken", _} = changeset.errors[:parent_value_id]
    end

    test "child group listings can keep, drop or only return threads", %{
      owner: owner,
      group: group,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "t"})
      {:ok, plain} = Social.create_group(owner, group, %{"name" => "plain"})

      ids = fn opts ->
        group
        |> Social.list_child_groups_for_profile(owner, opts)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      assert ids.([]) == Enum.sort([thread.id, plain.id])
      assert ids.(is_thread: false) == [plain.id]
      assert ids.(is_thread: true) == [thread.id]
      assert ids.(is_thread: false, limit: 5, offset: 0) == [plain.id]
      assert length(ids.(limit: 1, offset: 1)) == 1
      assert length(ids.(offset: 1)) == 1

      assert Social.count_child_groups_for_profile(group, owner) == 2
      assert Social.count_child_groups_for_profile(group, owner, is_thread: true) == 1
      assert Social.count_child_groups_for_profile(group, owner, is_thread: false) == 1
    end

    test "create_group rejects a parent value from another group", %{owner: owner, value: value} do
      other_group = reply_group!(owner, "thread-foreign", %{})

      assert {:error, :invalid_parent_value} =
               Social.create_group(owner, other_group, %{
                 "name" => "hijack",
                 "parent_value_id" => to_string(value.id)
               })
    end

    test "get_thread_origin/2 returns the value only to profiles that can read its group", %{
      owner: owner,
      outsider: outsider,
      value: value
    } do
      private_group = reply_group!(owner, "thread-private", %{"is_public" => false})
      {:ok, private_value} = Social.create_value(owner, private_group, %{"content" => "hidden"})

      {:ok, thread} =
        Social.get_or_create_value_thread(owner, private_group, private_value, %{"name" => "t"})

      assert %{id: origin_id, creator: %{username: "thread-owner"}} =
               Social.get_thread_origin(owner, thread)

      assert origin_id == private_value.id
      assert Social.get_thread_origin(outsider, thread) == nil

      public_group = Social.get_group!(value.group_id)

      {:ok, public_thread} =
        Social.get_or_create_value_thread(owner, public_group, value, %{"name" => "p"})

      assert %{id: _} = Social.get_thread_origin(outsider, public_thread)
    end
  end

  defp reply_profile!(username) do
    {:ok, profile} =
      Social.create_profile_for_account(account_fixture(), %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  defp reply_group!(owner, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
