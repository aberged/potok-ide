defmodule PotokIde.SocialTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.EventsFixtures
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
    test "sub-groups come with their members, visible sub-groups and the viewer's membership" do
      {_account, owner} = EventsFixtures.account_with_profile!("details-owner")
      {_account, viewer} = EventsFixtures.account_with_profile!("details-viewer")
      {_account, member} = EventsFixtures.account_with_profile!("details-member")
      parent = EventsFixtures.group_with_members!(owner, [viewer])
      joined = EventsFixtures.group_with_members!(owner, [viewer, member], %{parent: parent})

      open =
        EventsFixtures.group_with_members!(owner, [], %{:parent => parent, "is_public" => true})

      # Below `joined`: a public group, one with the viewer, one it can't see and a thread.
      EventsFixtures.group_with_members!(owner, [], %{:parent => joined, "is_public" => true})
      EventsFixtures.group_with_members!(owner, [viewer], %{parent: joined})
      EventsFixtures.group_with_members!(owner, [], %{parent: joined})
      {:ok, value} = Social.create_value(owner, joined, %{"content" => "thread start"})

      {:ok, _thread} =
        Social.get_or_create_value_thread(owner, joined, value, %{"name" => "talk"})

      details = fn opts ->
        parent
        |> Social.list_child_groups_for_profile(viewer, opts)
        |> Map.new(&{&1.id, {&1.member_count, &1.sub_group_count, &1.viewer_is_member}})
      end

      assert details.([]) == %{joined.id => {3, 3, true}, open.id => {1, 0, false}}
      assert %{joined.id => {3, 2, true}} == Map.take(details.(is_thread: false), [joined.id])

      # Direct conversations load none.
      {:ok, _direct} = Social.get_or_create_direct_group(viewer, owner)

      assert [%Group{member_count: nil, sub_group_count: nil, viewer_is_member: nil}] =
               Social.list_child_groups_for_profile(Social.get_root_group!(), viewer,
                 is_direct: true
               )
    end

    test "public: false leaves out public groups the viewer is not in, but the way to its own" do
      {_account, owner} = EventsFixtures.account_with_profile!("pubhide-owner")
      {_account, viewer} = EventsFixtures.account_with_profile!("pubhide-viewer")
      parent = EventsFixtures.group_with_members!(owner, [viewer])
      joined = EventsFixtures.group_with_members!(owner, [viewer], %{parent: parent})

      open =
        EventsFixtures.group_with_members!(owner, [], %{:parent => parent, "is_public" => true})

      # Public, the viewer is not in it, but in a group two levels below it.
      way =
        EventsFixtures.group_with_members!(owner, [], %{:parent => parent, "is_public" => true})

      below = EventsFixtures.group_with_members!(owner, [], %{parent: way})
      EventsFixtures.group_with_members!(owner, [viewer], %{parent: below})

      # Private and the viewer is not in it: never listed.
      EventsFixtures.group_with_members!(owner, [], %{parent: parent})

      ids = fn opts ->
        parent |> Social.list_child_groups_for_profile(viewer, opts) |> Enum.map(& &1.id)
      end

      assert Enum.sort(ids.([])) == Enum.sort([joined.id, open.id, way.id])
      assert Enum.sort(ids.(public: false)) == Enum.sort([joined.id, way.id])

      assert Enum.sort(Social.list_child_group_ids_for_profile(parent, viewer, public: false)) ==
               Enum.sort([joined.id, way.id])

      assert Social.count_child_groups_for_profile(parent, viewer, public: false) == 2
      assert Social.count_child_groups_for_profile(parent, viewer) == 3

      assert {[_group], 2} =
               Social.list_child_groups_page_for_profile(parent, viewer, public: false, limit: 1)
    end

    test "preset: keeps the groups of the kind their avatar shows" do
      {_account, owner} = EventsFixtures.account_with_profile!("kind-owner")
      parent = EventsFixtures.group_with_members!(owner, [])

      kind! = fn preset, uses_api ->
        group = EventsFixtures.group_with_members!(owner, [], %{parent: parent})

        from(g in Group, where: g.id == ^group.id)
        |> PotokIde.Repo.update_all(set: [preset: preset, uses_api: uses_api])

        group.id
      end

      chat = kind!.(:chat, false)
      announcements = kind!.(:announcements, false)
      feed = kind!.(:feed, true)
      # Made as a chat, then given an app: the avatar shows the puzzle.
      chat_with_app = kind!.(:chat, true)
      # A feed whose app was taken away shows no kind either.
      feed_without_app = kind!.(:feed, false)
      by_hand = kind!.(nil, false)
      pasted_app = kind!.(nil, true)

      ids = fn opts ->
        parent |> Social.list_child_groups_for_profile(owner, opts) |> Enum.map(& &1.id)
      end

      assert ids.(preset: "chat") == [chat]
      assert ids.(preset: "announcements") == [announcements]
      assert ids.(preset: "feed") == [feed]
      assert ids.(preset: "polls") == []

      # An app that fits no preset shows the puzzle: a kind of its own.
      assert Enum.sort(ids.(preset: "app")) == Enum.sort([chat_with_app, pasted_app])
      assert Enum.sort(ids.(preset: "none")) == Enum.sort([feed_without_app, by_hand])

      # Anything else is no filter at all.
      assert length(ids.(preset: "bogus")) == 7
      assert length(ids.(preset: nil)) == 7

      assert Social.list_child_group_ids_for_profile(parent, owner, preset: "feed") == [feed]
      assert Social.count_child_groups_for_profile(parent, owner, preset: "none") == 2
      assert Social.count_child_groups_for_profile(parent, owner, preset: "app") == 2

      assert {[_group], 2} =
               Social.list_child_groups_page_for_profile(parent, owner, preset: "none", limit: 1)

      assert ids.(preset: "chat", search: "nothing-like-it") == []
    end

    test "relation: keeps the viewer's memberships or the groups it made" do
      {_account, owner} = EventsFixtures.account_with_profile!("rel-owner")
      {_account, viewer} = EventsFixtures.account_with_profile!("rel-viewer")
      parent = EventsFixtures.group_with_members!(owner, [viewer])

      # Made by the owner, the viewer in it.
      joined = EventsFixtures.group_with_members!(owner, [viewer], %{parent: parent})

      # Made by the owner, the viewer a member through inheritance.
      inherited =
        EventsFixtures.group_with_members!(owner, [], %{
          :parent => parent,
          "inherits_members" => true
        })

      # Public, made by the owner, the viewer not in it.
      open =
        EventsFixtures.group_with_members!(owner, [], %{:parent => parent, "is_public" => true})

      # Made by the viewer.
      {:ok, own} =
        Social.create_group(viewer, parent, %{
          "name" => "rel-own",
          "description" => "",
          "description_format" => :markdown
        })

      # Made by the viewer, who has left it since; public, so still listed.
      {:ok, left} =
        Social.create_group(viewer, parent, %{
          "name" => "rel-left",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      from(m in PotokIde.Social.GroupMembership,
        where: m.group_id == ^left.id and m.profile_id == ^viewer.id
      )
      |> PotokIde.Repo.delete_all()

      ids = fn opts ->
        parent |> Social.list_child_groups_for_profile(viewer, opts) |> Enum.map(& &1.id)
      end

      assert Enum.sort(ids.([])) == Enum.sort([joined.id, inherited.id, open.id, own.id, left.id])

      assert Enum.sort(ids.(relation: "member")) == Enum.sort([joined.id, inherited.id, own.id])
      assert Enum.sort(ids.(relation: "creator")) == Enum.sort([own.id, left.id])
      assert length(ids.(relation: "bogus")) == 5

      assert Social.count_child_groups_for_profile(parent, viewer, relation: "member") == 3

      assert {[_group], 2} =
               Social.list_child_groups_page_for_profile(parent, viewer,
                 relation: "creator",
                 limit: 1
               )

      assert ids.(relation: "creator", search: "own") == [own.id]

      from(g in Group, where: g.id == ^own.id)
      |> PotokIde.Repo.update_all(set: [preset: :chat])

      assert ids.(relation: "member", preset: "chat") == [own.id]
      assert ids.(relation: "creator", preset: "folder") == []
    end

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

      assert %{own: 2, subtree: 3, parent_id: ^root_id, direct?: false} =
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

    test "threads count in the groups above them, and thread_unread_counts/2 names them" do
      [owner_profile, writer_profile] = unread_profiles(["nothread-owner", "nothread-writer"])
      parent = unread_group!(owner_profile, Social.get_root_group!(), "nothread-parent")
      child = unread_group!(owner_profile, parent, "nothread-child")

      for group <- [parent, child] do
        unread_member!(owner_profile, group, writer_profile)
      end

      {:ok, start} = Social.create_value(writer_profile, parent, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(writer_profile, parent, start, %{"name" => "talk"})

      {:ok, _value} = Social.create_value(writer_profile, thread, %{"content" => "in thread"})
      {:ok, _value} = Social.create_value(writer_profile, thread, %{"content" => "again"})
      {:ok, _value} = Social.create_value(writer_profile, child, %{"content" => "in child"})

      overview = Social.unread_overview(owner_profile)
      assert %{thread?: true, subtree: 2} = overview.groups[thread.id]
      assert %{thread?: false, own: 1, subtree: 4} = overview.groups[parent.id]
      assert Social.child_unread_summary(overview, parent.id) == %{direct: 0, other: 3}

      assert Social.thread_unread_counts(overview, [parent.id]) == %{thread.id => 2}
      assert Social.thread_unread_counts(overview, [child.id]) == %{}
    end

    test "a group below one the profile cannot see counts at the root, not further up" do
      [owner, reader] = unread_profiles(["hang-owner", "hang-reader"])
      root = Social.get_root_group!()
      hidden = unread_group!(owner, root, "hang-hidden")
      below = unread_group!(owner, hidden, "hang-below")
      joined = unread_group!(owner, root, "hang-joined")
      hidden_inside = unread_group!(owner, joined, "hang-hidden-inside")
      below_inside = unread_group!(owner, hidden_inside, "hang-below-inside")
      memberships = [below, joined, below_inside]

      for group <- memberships, do: unread_member!(owner, group, reader)
      for group <- [below, below_inside], do: unread_value!(owner, group)

      overview = Social.unread_overview(reader)
      root_id = root.id

      assert overview.total == 2
      assert overview.groups[root_id].subtree == 2
      assert %{parent_id: ^root_id, own: 1, subtree: 1} = overview.groups[below.id]
      assert %{parent_id: ^root_id, own: 1, subtree: 1} = overview.groups[below_inside.id]

      for group <- [hidden, hidden_inside, joined] do
        refute Map.has_key?(overview.groups, group.id)
      end

      assert Social.child_unread_summary(overview, root_id) == %{direct: 0, other: 2}
      assert Social.child_unread_summary(overview, joined.id) == %{direct: 0, other: 0}

      # Counted live, a value lands in the same places.
      Social.subscribe_group_unread(below_inside.id)
      unread_value!(owner, below_inside)
      assert_receive {:group_value_unread, unread}

      {:ok, added} =
        Social.add_unread_value(overview, unread, MapSet.new(memberships, & &1.id))

      counted = Social.unread_overview(reader)

      assert added.total == counted.total
      assert Map.new(added.groups, &unread_entry/1) == Map.new(counted.groups, &unread_entry/1)
    end

    test "the root lists the groups no other list leads to" do
      [owner, reader] = unread_profiles(["detached-owner", "detached-reader"])
      root = Social.get_root_group!()
      hidden = unread_group!(owner, root, "detached-hidden")
      below = unread_group!(owner, hidden, "detached-below")
      deep = unread_group!(owner, below, "detached-deep")
      joined = unread_group!(owner, root, "detached-joined")
      hidden_inside = unread_group!(owner, joined, "detached-hidden-inside")
      below_inside = unread_group!(owner, hidden_inside, "detached-below-inside")

      {:ok, public_below} =
        Social.create_group(owner, hidden, %{
          "name" => "detached-public",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      inside_public = unread_group!(owner, public_below, "detached-inside-public")

      for group <- [below, deep, joined, below_inside, inside_public] do
        unread_member!(owner, group, reader)
      end

      listed = fn group, opts ->
        group
        |> Social.list_child_groups_for_profile(reader, opts)
        |> Enum.map(& &1.id)
        |> Enum.sort()
      end

      # The way down from the root reaches the rest: `deep` through `below`,
      # `inside_public` through the public group above it.
      everything = Enum.sort([below.id, joined.id, below_inside.id, public_below.id])

      assert listed.(root, public: false) == everything
      assert listed.(root, []) -- everything == []
      assert listed.(root, public: false, is_thread: false) == everything
      assert Social.count_child_groups_for_profile(root, reader, public: false) == 4
      assert listed.(root, public: false, search: "below-inside") == [below_inside.id]
      assert listed.(root, public: false, is_direct: true) == []

      # The kind filter reaches them too.
      from(g in Group, where: g.id == ^below_inside.id)
      |> PotokIde.Repo.update_all(set: [preset: :chat])

      assert listed.(root, public: false, preset: "chat") == [below_inside.id]
      refute below_inside.id in listed.(root, public: false, preset: "none")

      # So do the membership filters: the reader is in each of them, made by the owner.
      assert listed.(root, public: false, relation: "member") == everything -- [public_below.id]
      assert listed.(root, public: false, relation: "creator") == []

      # Only the root: a group's own list stays what the profile can see in it.
      assert listed.(joined, []) == []
      assert listed.(below, []) == [deep.id]

      root_id = root.id

      assert %{^root_id => {folders, false}} =
               Social.list_sub_group_folders(reader, [{root_id, 50, nil}], public?: false)

      assert folders |> Enum.map(& &1.id) |> Enum.sort() == everything

      assert {[%{id: id, parent_id: ^root_id}], false} =
               Social.search_sub_group_folders(root, reader, "below-inside", public?: false)

      assert id == below_inside.id

      assert {[%{id: ^id, parent_id: ^root_id}], false} =
               Social.search_sub_group_folders(root, reader, nil, public?: false, preset: "chat")
    end

    test "the root lists a thread left without its parent, though threads are hidden" do
      [owner, reader] = unread_profiles(["orphan-owner", "orphan-reader"])
      root = Social.get_root_group!()
      hidden = unread_group!(owner, root, "orphan-hidden")
      unread_member!(owner, hidden, reader)

      {:ok, value} = Social.create_value(reader, hidden, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(reader, hidden, value, %{"name" => "orphan-talk"})

      assert {:ok, _removed} = Social.remove_group_member(owner, hidden, reader)
      assert Social.member_of_group?(reader, thread)

      assert [listed] =
               Social.list_child_groups_for_profile(root, reader, public: false, is_thread: false)

      assert listed.id == thread.id

      root_id = root.id

      assert %{^root_id => {[folder], false}} =
               Social.list_sub_group_folders(reader, [{root_id, 50, nil}],
                 public?: false,
                 threads?: false
               )

      assert folder.id == thread.id
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
      Social.subscribe_group_unread(grandchild_group.id)
      forward_profile_messages(writer_profile)

      {:ok, value} =
        Social.create_value(writer_profile, grandchild_group, %{"content" => "news"})

      writer_id = writer_profile.id
      grandchild_id = grandchild_group.id
      assert_receive {:group_value_unread, unread}

      assert %{group_id: ^grandchild_id, creator_id: ^writer_id} = unread
      assert unread.value_id == value.id

      assert MapSet.new(unread.chain, & &1.id) ==
               MapSet.new([root_group.id, child_group.id, grandchild_group.id])

      # The writer read it by posting it; the writer's other pages recount.
      assert_receive {:forwarded, {:group_unread_counts_updated, ^writer_id, ^grandchild_id}}
      refute_received {:forwarded, {:group_value_unread, _unread}}

      member_ids = MapSet.new([child_group.id, grandchild_group.id])
      {:ok, added} = Social.add_unread_value(before, unread, member_ids)
      counted = Social.unread_overview(owner_profile)

      assert added.total == counted.total

      assert Map.new(added.groups, &unread_entry/1) == Map.new(counted.groups, &unread_entry/1)
      assert Social.add_unread_value(counted, unread, member_ids) == :counted
    end

    test "root values reach no one, and a read is not echoed to the page that marked it" do
      [owner_profile, writer_profile] = unread_profiles(["echo-owner", "echo-writer"])
      root_group = Social.get_root_group!()
      group = unread_group!(owner_profile, root_group, "echo-group")
      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      {:ok, _value} = Social.create_value(writer_profile, group, %{"content" => "unread"})

      Social.subscribe_profile(owner_profile)
      Social.subscribe_group_unread(root_group.id)
      forward_profile_messages(owner_profile)

      {:ok, _root_value} = Social.create_value(writer_profile, root_group, %{"content" => "root"})
      refute_receive {:group_value_unread, _unread}

      owner_id = owner_profile.id
      group_id = group.id
      assert :ok = Social.mark_group_values_read(owner_profile, group)
      assert_receive {:forwarded, {:group_unread_counts_updated, ^owner_id, ^group_id}}
      refute_received {:group_unread_counts_updated, _profile_id, _group_id}
    end

    test "a deleted value makes the group's members count again" do
      [owner_profile, writer_profile] = unread_profiles(["del-owner", "del-writer"])
      group = unread_group!(owner_profile, Social.get_root_group!(), "del-group")
      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, writer_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, writer_profile)
      {:ok, value} = Social.create_value(writer_profile, group, %{"content" => "gone"})

      Social.subscribe_group_unread(group.id)
      {:ok, _deleted} = Social.delete_value(writer_profile, value)

      group_id = group.id
      assert_receive {:group_members_unread_changed, ^group_id}
    end

    test "member_group_ids/1 and nav_counts/2 give the profile's groups without the root" do
      [profile] = unread_profiles(["member-ids"])
      group = unread_group!(profile, Social.get_root_group!(), "member-ids-group")

      assert Social.member_group_ids(profile) == [group.id]
      assert Social.nav_counts(profile).member_group_ids == [group.id]
      assert Social.nav_counts(profile, unread: false).member_group_ids == [group.id]
    end

    test "joining and leaving a group reach the profile's pages" do
      [owner_profile, member_profile] = unread_profiles(["join-owner", "join-member"])
      group = unread_group!(owner_profile, Social.get_root_group!(), "join-group")
      member_id = member_profile.id
      group_id = group.id
      Social.subscribe_profile(member_profile)

      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, group, member_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member_profile)
      assert_receive {:group_membership_changed, ^member_id, ^group_id, :added}
      assert_receive {:group_unread_counts_updated, ^member_id, ^group_id}

      {:ok, _removed} = Social.remove_group_member(owner_profile, group, member_profile)
      assert_receive {:group_membership_changed, ^member_id, ^group_id, :removed}
      assert_receive {:group_unread_counts_updated, ^member_id, ^group_id}
    end

    test "inherited membership reaches the profile's pages" do
      [owner_profile, member_profile] = unread_profiles(["inh-owner", "inh-member"])
      parent = unread_group!(owner_profile, Social.get_root_group!(), "inh-parent")
      {:ok, invitation} = Social.invite_profile_to_group(owner_profile, parent, member_profile)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member_profile)
      member_id = member_profile.id
      Social.subscribe_profile(member_profile)

      {:ok, child} =
        Social.create_group(owner_profile, parent, %{
          "name" => "inh-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false,
          "inherits_members" => "true"
        })

      child_id = child.id
      assert_receive {:group_membership_changed, ^member_id, ^child_id, :added}
    end

    test "a new group reaches its creator's other pages" do
      [owner_profile] = unread_profiles(["new-owner"])
      owner_id = owner_profile.id
      Social.subscribe_profile(owner_profile)

      group = unread_group!(owner_profile, Social.get_root_group!(), "new-group")

      group_id = group.id
      assert_receive {:group_membership_changed, ^owner_id, ^group_id, :added}
    end

    test "a new direct group reaches the pages of both profiles" do
      [first_profile, second_profile] = unread_profiles(["direct-one", "direct-two"])
      first_id = first_profile.id
      second_id = second_profile.id
      Social.subscribe_profile(first_profile)
      Social.subscribe_profile(second_profile)

      {:ok, group} = Social.get_or_create_direct_group(first_profile, second_profile)

      group_id = group.id
      assert_receive {:group_membership_changed, ^first_id, ^group_id, :added}
      assert_receive {:group_membership_changed, ^second_id, ^group_id, :added}
    end

    test "an invited account's first profile reaches the inviter's pages" do
      [inviter_profile] = unread_profiles(["inviter"])
      inviter_id = inviter_profile.id
      Social.subscribe_profile(inviter_profile)

      {:ok, invited_account} =
        Accounts.register_account(valid_account_attributes(), inviter_profile)

      {:ok, invited_profile} =
        Social.create_profile_for_account(invited_account, %{
          username: "invited",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      assert [group_id] = Social.member_group_ids(invited_profile)
      assert_receive {:group_membership_changed, ^inviter_id, ^group_id, :added}
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

  defp unread_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
  end

  defp unread_value!(profile, group) do
    {:ok, value} = Social.create_value(profile, group, %{"content" => "news"})
    value
  end

  defp unread_entry({group_id, entry}),
    do: {group_id, Map.take(entry, [:own, :subtree, :parent_id, :direct?, :thread?])}

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

  # The structs here come from regular queries, without their pictures, like
  # the ones the pages save from.
  describe "clearing a picture" do
    setup do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "pic-clearer",
          profile_picture_url: "https://example.com/pic.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(profile, Social.get_root_group!(), %{
          "name" => "pic-clear-group",
          "group_picture_url" => "https://example.com/group.png",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      %{account: account, profile: Social.get_profile!(profile.id), group: group.id}
    end

    defp profile_picture(id), do: Social.load_picture(Social.get_profile!(id)).profile_picture_url
    defp group_picture(id), do: Social.load_picture(Social.get_group!(id)).group_picture_url

    test "an empty value removes a profile's picture", ctx do
      assert {:ok, _profile} =
               Social.update_profile_for_account(ctx.account, ctx.profile.id, %{
                 "profile_picture_url" => ""
               })

      assert profile_picture(ctx.profile.id) == nil
    end

    test "an empty value removes a group's picture", ctx do
      group = Social.get_group!(ctx.group)

      assert {:ok, _group} =
               Social.update_group(ctx.profile, group, %{"group_picture_url" => ""})

      assert group_picture(group.id) == nil
    end

    test "a save that leaves the picture out keeps it", ctx do
      assert {:ok, _profile} =
               Social.update_profile_for_account(ctx.account, ctx.profile.id, %{
                 "description" => "changed"
               })

      assert {:ok, _group} =
               Social.update_group(ctx.profile, Social.get_group!(ctx.group), %{
                 "name" => "renamed"
               })

      assert profile_picture(ctx.profile.id) == "https://example.com/pic.png"
      assert group_picture(ctx.group) == "https://example.com/group.png"
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

    test "list_group_data_value_rows/2 pages next to the cursor in either order", %{
      owner: owner,
      group: group
    } do
      [v1, v2, v3, v4, v5] =
        for n <- 1..5 do
          {:ok, value} =
            Social.create_data_value(owner, group, %{"content" => "data:", "data" => %{"n" => n}})

          value
        end

      ids = fn opts ->
        {rows, more?} = Social.list_group_data_value_rows(group, opts)
        {Enum.map(rows, & &1.id), more?}
      end

      assert ids.([]) == {[v1.id, v2.id, v3.id, v4.id, v5.id], false}

      assert ids.(before_id: v5.id, limit: 2) == {[v3.id, v4.id], true}
      assert ids.(before_id: v3.id, limit: 2) == {[v1.id, v2.id], false}
      assert ids.(before_id: v5.id, offset: 1, limit: 2) == {[v2.id, v3.id], true}
      assert ids.(after_id: v1.id, before_id: v5.id, limit: 2) == {[v2.id, v3.id], true}

      assert ids.(order_dir: "desc", limit: 2) == {[v5.id, v4.id], true}
      assert ids.(order_dir: "desc", before_id: v4.id, limit: 2) == {[v3.id, v2.id], true}
      assert ids.(order_dir: "desc", after_id: v2.id, limit: 2) == {[v4.id, v3.id], true}
      assert ids.(order_dir: "desc", after_id: v3.id, limit: 2) == {[v5.id, v4.id], false}

      # Ordered by a key of the data, the cursor only narrows.
      assert ids.(order_by: "n", order_dir: "desc", before_id: v4.id) ==
               {[v3.id, v2.id, v1.id], false}
    end

    test "list_group_data_value_rows/2 combines match and search", %{
      owner: owner,
      group: group
    } do
      for {status, title} <- [{"open", "Roof"}, {"open", "Door"}, {"done", "Roof window"}] do
        {:ok, _} =
          Social.create_data_value(owner, group, %{
            "content" => "data:",
            "data" => %{"status" => status, "title" => title}
          })
      end

      filters = [match: %{"status" => "open"}, search_field: "title", search_value: "roof"]

      assert {[row], false} = Social.list_group_data_value_rows(group, filters)
      assert row.data == %{"status" => "open", "title" => "Roof"}
      assert Social.count_group_data_value_rows(group, filters) == 1
      assert Social.count_group_data_value_rows(group, match: %{"status" => "open"}) == 2
    end

    test "aggregate_group_data_values/2 adds up numbers, in all and per group", %{
      owner: owner,
      group: group
    } do
      for data <- [
            %{"status" => "open", "amount" => 10},
            %{"status" => "open", "amount" => "2.5"},
            %{"status" => "done", "amount" => "abc"},
            %{"status" => "done", "amount" => "1,5"},
            %{"status" => true, "amount" => -4},
            %{"amount" => 7}
          ] do
        {:ok, _} = Social.create_data_value(owner, group, %{"content" => "data:", "data" => data})
      end

      assert {:ok, all} = Social.aggregate_group_data_values(group, fields: ["amount"])
      assert %{total: 6, buckets: nil, other: nil} = all
      assert all.fields["amount"] == %{count: 4, sum: 15.5, avg: 3.875, min: -4.0, max: 10.0}

      assert {:ok, grouped} =
               Social.aggregate_group_data_values(group, group_by: "status", fields: ["amount"])

      assert grouped.total == 6
      assert grouped.fields == all.fields

      assert Enum.map(grouped.buckets, &{&1.value, &1.count}) ==
               [{"done", 2}, {"open", 2}, {"true", 1}, {nil, 1}]

      [done, open | _] = grouped.buckets
      assert open.fields["amount"] == %{count: 2, sum: 12.5, avg: 6.25, min: 2.5, max: 10.0}
      assert done.fields["amount"] == %{count: 0, sum: 0.0, avg: nil, min: nil, max: nil}

      assert {:ok, %{total: 2, fields: %{"amount" => %{sum: 12.5}}}} =
               Social.aggregate_group_data_values(group,
                 match: %{"status" => "open"},
                 fields: ["amount"]
               )

      assert {:ok, %{total: 0, fields: %{"amount" => %{count: 0, avg: nil}}, buckets: []}} =
               Social.aggregate_group_data_values(group,
                 search_field: "status",
                 search_value: "nothing",
                 group_by: "status",
                 fields: ["amount"]
               )
    end

    test "aggregate_group_data_values/2 reads under a path and sums up past 50 groups", %{
      owner: owner,
      group: group
    } do
      for n <- 1..52 do
        {:ok, _} =
          Social.create_data_value(owner, group, %{
            "content" => "data:",
            "data" => %{"a" => %{"q" => "o#{n}", "n" => n}}
          })
      end

      assert {:ok, result} =
               Social.aggregate_group_data_values(group,
                 under: ["a"],
                 group_by: "q",
                 fields: ["n"]
               )

      assert result.total == 52
      assert length(result.buckets) == 50
      assert result.other == %{buckets: 2, count: 2}
      assert result.fields["n"] == %{count: 52, sum: 1378.0, avg: 26.5, min: 1.0, max: 52.0}

      # Without a path the numbers are not at the top.
      assert {:ok, %{fields: %{"n" => %{count: 0}}}} =
               Social.aggregate_group_data_values(group, fields: ["n"])
    end

    test "aggregate_group_data_values/2 refuses what it cannot add up", %{group: group} do
      too_long = String.duplicate("k", 65)

      for opts <- [
            [fields: ~w(a b c d e f)],
            [fields: "amount"],
            [fields: [too_long]],
            [group_by: 5],
            [group_by: ""],
            [under: ~w(a b c d)],
            [under: "a"]
          ] do
        assert {:error, :invalid_aggregate} = Social.aggregate_group_data_values(group, opts)
      end
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

  describe "list_group_values_around/3" do
    setup do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "around-prof",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      [group, other_group] =
        for name <- ["around-group", "around-other"] do
          {:ok, group} =
            Social.create_group(profile, Social.get_root_group!(), %{
              "name" => name,
              "description" => "",
              "description_format" => :markdown,
              "is_public" => false
            })

          group
        end

      ids =
        for n <- 1..9 do
          {:ok, value} = Social.create_value(profile, group, %{"content" => "around #{n}"})
          value.id
        end

      %{profile: profile, group: group, other_group: other_group, ids: ids}
    end

    test "pages forwards with after_id", %{group: group, ids: ids} do
      assert {newer, true} =
               Social.list_group_values_page(group, after_id: Enum.at(ids, 2), limit: 3)

      assert Enum.map(newer, & &1.id) == Enum.slice(ids, 3, 3)

      assert {last, false} =
               Social.list_group_values_page(group, after_id: Enum.at(ids, 5), limit: 3)

      assert Enum.map(last, & &1.id) == Enum.slice(ids, 6, 3)
    end

    test "returns the values before and after one, oldest first", %{group: group, ids: ids} do
      assert {values, true, true} =
               Social.list_group_values_around(group, Enum.at(ids, 4), older: 2, newer: 2)

      assert Enum.map(values, & &1.id) == Enum.slice(ids, 2, 5)

      assert {values, false, true} =
               Social.list_group_values_around(group, hd(ids), older: 2, newer: 2)

      assert Enum.map(values, & &1.id) == Enum.slice(ids, 0, 3)

      assert {values, true, false} =
               Social.list_group_values_around(group, List.last(ids), older: 2, newer: 2)

      assert Enum.map(values, & &1.id) == Enum.slice(ids, 6, 3)
    end

    test "is nil for a value that is not a chat value of the group", %{
      profile: profile,
      group: group,
      other_group: other_group,
      ids: ids
    } do
      {:ok, data_value} =
        Social.create_data_value(profile, group, %{"content" => "data:", "data" => %{}})

      {:ok, elsewhere} = Social.create_value(profile, other_group, %{"content" => "elsewhere"})

      assert Social.list_group_values_around(group, data_value.id) == nil
      assert Social.list_group_values_around(group, elsewhere.id) == nil
      assert Social.list_group_values_around(other_group, hd(ids)) == nil
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

    # Erlang's PCRE sees these single-codepoint emoji as unassigned; the kiss
    # with two skin tones is 35 bytes.
    test "accepts emoji newer than Erlang's Unicode tables and long ZWJ sequences", %{
      owner: owner,
      group: group,
      value: value
    } do
      emoji = ["🤣", "🙃", "🫠", "🥲", "🧑🏻‍❤️‍💋‍🧑🏼"]

      for e <- emoji do
        assert {:ok, _value} = Social.toggle_value_reaction(owner, group, value, e)
      end

      assert [%{reactions: reactions}] = Social.list_group_values(group)
      assert Enum.map(reactions, & &1.emoji) == emoji
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
      for invalid <- ["", "a", "ab", "7", " ", "👍👍", "‍", "", " "] do
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

    test "returns the same thread on later calls, which already holds members who joined since",
         %{
           owner: owner,
           group: group,
           value: value
         } do
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "t"})

      latecomer = reply_profile!("thread-late")
      add_member!(owner, group, latecomer)
      assert Social.member_of_group?(latecomer, thread)

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

  describe "opening a closed group" do
    setup do
      {_account, owner} = EventsFixtures.account_with_profile!("publish-owner")

      {:ok, parent} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "publish-parent",
          "description" => "",
          "description_format" => :markdown
        })

      {:ok, group} =
        Social.create_group(owner, parent, %{
          "name" => "publish-group",
          "description" => "",
          "description_format" => :markdown
        })

      %{owner: owner, group: group}
    end

    test "a closed group has not been published", %{group: group} do
      assert Group.closed?(group)
      assert group.published_at == nil
    end

    test "counts from when it opens up, by either switch", %{owner: owner, group: group} do
      {:ok, public} = Social.update_group(owner, group, %{"is_public" => "true"})
      assert public.published_at

      {:ok, inheriting} = Social.update_group(owner, group, %{"inherits_members" => "true"})
      assert inheriting.published_at
    end

    test "any other change leaves the time alone", %{owner: owner, group: group} do
      {:ok, renamed} = Social.update_group(owner, group, %{"name" => "still closed"})
      assert renamed.published_at == nil

      {:ok, opened} = Social.update_group(owner, group, %{"is_public" => "true"})
      stamped = DateTime.add(opened.published_at, -1, :day)

      Repo.update_all(
        from(g in Group, where: g.id == ^group.id),
        set: [published_at: stamped]
      )

      {:ok, again} =
        Social.update_group(owner, Repo.get!(Group, group.id), %{"inherits_members" => "true"})

      assert again.published_at == stamped
    end
  end
end
