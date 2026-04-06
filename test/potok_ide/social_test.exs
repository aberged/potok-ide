defmodule PotokIde.SocialTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
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
      assert group.has_public_chat == false
    end
  end

  describe "create_profile_for_account/2" do
    test "sets both current and default profiles for the first account profile only" do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-first-profile",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      assert Social.get_account_current_profile(account).id == first_profile.id
      assert Social.get_account_default_profile(account).id == first_profile.id

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "default-second-profile",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)

      assert Social.get_account_current_profile(account).id == first_profile.id
      assert Social.get_account_default_profile(account).id == first_profile.id
      refute Social.get_account_default_profile(account).id == second_profile.id
    end
  end

  describe "delete_group/2" do
    test "deletes a non-root leaf group for a member" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delete-group-owner",
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
          username: "delete-root-profile",
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
          username: "delete-parent-profile",
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
          username: "shared-profile-push-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :shared
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "shared-profile-push-invitee",
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

  describe "remove_group_member/3" do
    test "allows the group creator to remove another member" do
      owner_account = account_fixture()
      member_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "remove-member-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "remove-member-target",
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
          username: "remove-member-owner-2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, member_profile} =
        Social.create_profile_for_account(member_account, %{
          username: "remove-member-non-creator",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, target_profile} =
        Social.create_profile_for_account(target_account, %{
          username: "remove-member-target-2",
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
          username: "group-push-inviter",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "group-push-invitee",
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
          username: "value-push-sender",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, recipient_profile} =
        Social.create_profile_for_account(recipient_account, %{
          username: "value-push-recipient",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _non_member_profile} =
        Social.create_profile_for_account(non_member_account, %{
          username: "value-push-non-member",
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
  end

  describe "create_value/3" do
    test "defaults is_data to false and accepts explicit true" do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "value-is-data-owner",
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

      assert values_by_id[default_value.id].is_data == false
      assert values_by_id[data_value.id].is_data == true
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
