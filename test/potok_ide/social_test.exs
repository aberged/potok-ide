defmodule PotokIde.SocialTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Social

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

      assert {:error, :not_group_creator} =
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

      assert {:error, :not_group_creator} = Social.delete_group_data_values(member_profile, group)
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

      assert unread_counts_after_read[root_group.id] == 1
      assert unread_counts_after_read[child_group.id] == 1
      assert unread_counts_after_read[grandchild_group.id] == 1
    end
  end
end
