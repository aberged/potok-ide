defmodule PotokIde.Social.AccessTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupRole}

  describe "for_profile/2" do
    test "the creator is the admin of a new group and members hold everyone" do
      owner = profile!("acc-owner")
      member = profile!("acc-member")
      outsider = profile!("acc-outsider")
      group = group!(owner, "acc-group")
      add_member!(owner, group, member)

      owner_access = Access.for_profile(owner, group)
      assert owner_access.member? and owner_access.admin?
      assert owner_access.role_keys == ["everyone", "admin"]
      assert MapSet.new(GroupRole.permissions()) == owner_access.permissions

      member_access = Access.for_profile(member, group)
      assert member_access.member?
      refute member_access.admin?
      assert member_access.role_keys == ["everyone"]
      assert member_access.permissions == MapSet.new(GroupRole.default_everyone_permissions())
      refute Access.can?(member_access, :edit_group)

      outsider_access = Access.for_profile(outsider, group)
      refute outsider_access.member?
      assert outsider_access.permissions == MapSet.new()
    end

    test "a denial wins over an allowance and admins are never restricted" do
      owner = profile!("deny-owner")
      member = profile!("deny-member")
      group = group!(owner, "deny-group")
      add_member!(owner, group, member)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      muted = role!(owner, group, "muted")

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, muted.key, :post_values, :deny)

      {:ok, _} = Social.assign_group_member_role(owner, group, member.id, muted.key)
      {:ok, _} = Social.assign_group_member_role(owner, group, owner.id, muted.key)

      refute Access.can?(member, group, :post_values)
      assert Access.can?(member, group, :react)
      assert Access.can?(owner, group, :post_values)

      assert {:error, :not_permitted} =
               Social.create_value(member, group, %{"content" => "hello"})

      assert {:ok, _value} = Social.create_value(owner, group, %{"content" => "hello"})
    end

    test "a custom role grants permissions that were creator-only" do
      owner = profile!("mod-owner")
      moderator = profile!("mod-mod")
      member = profile!("mod-member")
      group = group!(owner, "mod-group")
      add_member!(owner, group, moderator)
      add_member!(owner, group, member)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      moderators = role!(owner, group, "moderators")

      for permission <- [:remove_members, :delete_values, :edit_group] do
        {:ok, _role} =
          Social.set_group_role_permission(owner, group, moderators.key, permission, :allow)
      end

      {:ok, _} = Social.assign_group_member_role(owner, group, moderator.id, moderators.key)

      {:ok, value} = Social.create_value(member, group, %{"content" => "spam"})
      assert {:ok, _deleted} = Social.delete_value(moderator, value)

      assert {:ok, _group} = Social.update_group(moderator, group, %{"name" => "renamed"})

      # Admins are only removed by admins.
      assert {:error, :not_permitted} = Social.remove_group_member(moderator, group, owner.id)
      assert {:ok, _member} = Social.remove_group_member(moderator, group, member.id)
    end
  end

  describe "effective manifests" do
    test "groups inherit until they create their own manifest, and can inherit again" do
      owner = profile!("inh-owner")
      root = Social.get_root_group!()
      group = group!(owner, "inh-group")
      {:ok, child} = Social.create_group(owner, group, group_attrs("inh-child"))

      assert Access.effective_manifest(group).group_id == root.id
      assert Access.effective_manifest(child).group_id == root.id

      {:ok, manifest} = Social.create_own_group_manifest(owner, group)
      assert manifest.group_id == group.id
      assert Enum.map(manifest.roles, & &1.key) == ["admin", "everyone"]
      assert Access.effective_manifest(child).group_id == group.id

      assert {:error, :own_manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, inherited} = Social.revert_to_inherited_group_manifest(owner, group)
      assert inherited.group_id == root.id
      assert Access.effective_manifest(child).group_id == root.id
    end

    test "only admins of the owning group change a manifest, and the default one is fixed" do
      owner = profile!("edit-owner")
      member = profile!("edit-member")
      group = group!(owner, "edit-group")
      add_member!(owner, group, member)
      root = Social.get_root_group!()

      assert {:error, :manifest_is_inherited} =
               Social.create_group_role(owner, group, %{"name" => "helpers"})

      assert {:error, :not_permitted} = Social.create_own_group_manifest(member, group)

      assert {:error, :root_manifest_is_fixed} =
               Social.revert_to_inherited_group_manifest(owner, root)

      assert {:error, :root_manifest_is_fixed} =
               Social.create_group_role(owner, root, %{"name" => "helpers"})

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      assert {:error, :not_permitted} =
               Social.create_group_role(member, group, %{"name" => "helpers"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_group_role(owner, group, %{"name" => "admin"})

      assert %{name: ["is reserved"]} = errors_on(changeset)

      assert {:error, :builtin_role} = Social.delete_group_role(owner, group, "everyone")

      assert {:error, :invalid_permission} =
               Social.set_group_role_permission(owner, group, "everyone", :post_values, :deny)

      assert {:error, :builtin_role} =
               Social.set_group_role_permission(owner, group, "admin", :post_values, :deny)
    end

    test "deleting a role clears it only in groups that use that manifest" do
      owner = profile!("del-owner")
      member = profile!("del-member")
      group = group!(owner, "del-group")
      add_member!(owner, group, member)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      helpers = role!(owner, group, "helpers")

      {:ok, inheriting} = Social.create_group(owner, group, group_attrs("del-inheriting"))
      {:ok, forked} = Social.create_group(owner, group, group_attrs("del-forked"))
      add_member!(owner, inheriting, member)
      add_member!(owner, forked, member)

      for target <- [group, inheriting, forked] do
        {:ok, _} = Social.assign_group_member_role(owner, target, member.id, helpers.key)
      end

      # The fork keeps the role's key, so its assignment stays valid.
      {:ok, _manifest} = Social.create_own_group_manifest(owner, forked)
      assert helpers.key in Access.for_profile(member, forked).role_keys

      {:ok, _role} = Social.delete_group_role(owner, group, helpers.key)

      refute helpers.key in Access.for_profile(member, group).role_keys
      assert Access.role_keys_by_profile(inheriting, [member.id]) == %{}
      assert helpers.key in Access.for_profile(member, forked).role_keys
    end

    test "inheriting again drops assignments of roles the parent manifest lacks" do
      owner = profile!("rev-owner")
      member = profile!("rev-member")
      group = group!(owner, "rev-group")
      add_member!(owner, group, member)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      helpers = role!(owner, group, "helpers")
      {:ok, _} = Social.assign_group_member_role(owner, group, member.id, helpers.key)

      {:ok, _manifest} = Social.revert_to_inherited_group_manifest(owner, group)

      assert Access.role_keys_by_profile(group, [member.id, owner.id]) == %{
               owner.id => ["admin"]
             }
    end
  end

  describe "role assignments" do
    test "a group always keeps an admin" do
      owner = profile!("last-owner")
      member = profile!("last-member")
      group = group!(owner, "last-group")
      add_member!(owner, group, member)

      assert {:error, :last_admin} =
               Social.unassign_group_member_role(owner, group, owner.id, "admin")

      assert {:error, :last_admin} = Social.remove_group_member(owner, group, owner.id)

      assert {:error, :role_not_found} =
               Social.assign_group_member_role(owner, group, member.id, "everyone")

      assert {:error, :not_permitted} =
               Social.assign_group_member_role(member, group, member.id, "admin")

      {:ok, _} = Social.assign_group_member_role(owner, group, member.id, "admin")
      assert :ok = Social.unassign_group_member_role(member, group, owner.id, "admin")
      refute Access.admin?(owner, group)
    end

    test "roles are assigned per group and leave with the membership" do
      owner = profile!("per-owner")
      member = profile!("per-member")
      group = group!(owner, "per-group")
      add_member!(owner, group, member)
      {:ok, child} = Social.create_group(owner, group, group_attrs("per-child"))
      add_member!(owner, child, member)

      {:ok, _} = Social.assign_group_member_role(owner, group, member.id, "admin")
      assert Access.admin?(member, group)
      refute Access.admin?(member, child)

      assert {:error, :not_a_group_member} =
               Social.assign_group_member_role(owner, child, profile!("per-out").id, "admin")

      {:ok, _} = Social.assign_group_member_role(owner, child, member.id, "admin")
      {:ok, _} = Social.remove_group_member(owner, child, member.id)
      assert Access.role_keys_by_profile(child, [member.id]) == %{}
    end

    test "a thread copies the members' roles and its opener becomes an admin" do
      owner = profile!("thr-owner")
      member = profile!("thr-member")
      late = profile!("thr-late")
      group = group!(owner, "thr-group")
      add_member!(owner, group, member)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      helpers = role!(owner, group, "helpers")
      {:ok, _} = Social.assign_group_member_role(owner, group, member.id, helpers.key)

      {:ok, value} = Social.create_value(owner, group, %{"content" => "thread me"})
      {:ok, thread} = Social.get_or_create_value_thread(member, group, value, %{"name" => "t"})

      assert Access.for_profile(owner, thread).admin?
      member_access = Access.for_profile(member, thread)
      assert member_access.admin?
      assert helpers.key in member_access.role_keys

      add_member!(owner, group, late)
      {:ok, _} = Social.assign_group_member_role(owner, group, late.id, helpers.key)
      {:ok, joined} = Social.get_or_create_value_thread(late, group, value, %{"name" => "t"})
      assert joined.id == thread.id
      assert Access.for_profile(late, thread).role_keys == ["everyone", helpers.key]
    end

    test "a role can let members approve access requests" do
      owner = profile!("req-owner")
      gatekeeper = profile!("req-gate")
      requester = profile!("req-asker")
      group = group!(owner, "req-group", %{"is_public" => true})
      add_member!(owner, group, gatekeeper)
      {:ok, request} = Social.request_group_access(requester, group)

      assert Social.list_pending_group_join_requests_for_approver(gatekeeper) == []
      assert Social.count_pending_group_join_requests_for_approver(gatekeeper) == 0

      assert {:error, :not_permitted} =
               Social.accept_group_join_request(gatekeeper, group, request.id)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      gate = role!(owner, group, "gate")

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, gate.key, :manage_join_requests, :allow)

      {:ok, _} = Social.assign_group_member_role(owner, group, gatekeeper.id, gate.key)

      assert [%{id: request_id}] =
               Social.list_pending_group_join_requests_for_approver(gatekeeper)

      assert request_id == request.id
      assert Social.count_pending_group_join_requests_for_approver(gatekeeper) == 1
      assert {:ok, _requester} = Social.accept_group_join_request(gatekeeper, group, request.id)
      assert Social.member_of_group?(requester, group)
    end
  end

  defp profile!(username) do
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

  defp group_attrs(name, attrs \\ %{}) do
    Map.merge(%{"name" => name, "description" => "", "description_format" => :markdown}, attrs)
  end

  defp group!(owner, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), group_attrs(name, attrs))
    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end

  defp role!(owner, group, name) do
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => name})
    role
  end
end
