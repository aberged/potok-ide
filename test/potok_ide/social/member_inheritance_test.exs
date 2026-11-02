defmodule PotokIde.Social.MemberInheritanceTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupMembership}

  setup do
    owner = profile!("inh-owner")
    member = profile!("inh-member")
    parent = group!(owner, "inh-parent")
    add_member!(owner, parent, member)

    %{owner: owner, member: member, parent: parent}
  end

  describe "creating a sub-group" do
    test "an inheriting sub-group holds the parent's members with their roles", %{
      owner: owner,
      member: member,
      parent: parent
    } do
      {:ok, _manifest} = Social.create_own_group_manifest(owner, parent)
      helpers = role!(owner, parent, "helpers")
      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, helpers.key)

      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})

      assert child.inherits_members
      assert member_ids(child) == Enum.sort([owner.id, member.id])
      assert Access.for_profile(owner, child).admin?
      assert Access.for_profile(member, child).role_keys == ["everyone", helpers.key]
      refute inherited_membership?(child, owner)
      assert inherited_membership?(child, member)
    end

    test "a sub-group that does not inherit holds only its creator", %{
      owner: owner,
      parent: parent
    } do
      child = child!(owner, parent, "inh-plain")

      refute child.inherits_members
      assert member_ids(child) == [owner.id]
    end

    test "groups in the root group cannot inherit, their sub-groups can", %{
      owner: owner,
      parent: parent
    } do
      root = Social.get_root_group!()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_group(
                 owner,
                 root,
                 group_attrs("inh-root-child", %{"inherits_members" => "true"})
               )

      assert changeset.errors[:inherits_members]

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.update_group(owner, parent, %{"inherits_members" => "true"})

      assert changeset.errors[:inherits_members]

      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})

      refute Social.inherits_members_option?(root)
      refute Social.inherits_members_option?(parent)
      assert Social.inherits_members_option?(child)
    end
  end

  describe "parent memberships" do
    test "members joining the parent reach inheriting descendants only", %{
      owner: owner,
      parent: parent
    } do
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})
      grandchild = child!(owner, child, "inh-grandchild", %{"inherits_members" => "true"})
      other = child!(owner, parent, "inh-other")

      newcomer = profile!("inh-newcomer")
      add_member!(owner, parent, newcomer)

      assert Social.member_of_group?(newcomer, child)
      assert Social.member_of_group?(newcomer, grandchild)
      refute Social.member_of_group?(newcomer, other)
    end

    test "leaving the parent removes inherited memberships, not direct ones", %{
      owner: owner,
      parent: parent
    } do
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})
      grandchild = child!(owner, child, "inh-grandchild", %{"inherits_members" => "true"})

      plain = profile!("inh-plain")
      add_member!(owner, parent, plain)

      # A direct member of the child who joins the parent later stays direct.
      direct = profile!("inh-direct")
      add_member!(owner, child, direct)
      add_member!(owner, parent, direct)
      refute inherited_membership?(child, direct)
      assert inherited_membership?(grandchild, direct)

      {:ok, _} = Social.remove_group_member(owner, parent, plain.id)
      {:ok, _} = Social.remove_group_member(owner, parent, direct.id)

      refute Social.member_of_group?(plain, child)
      refute Social.member_of_group?(plain, grandchild)
      assert Social.member_of_group?(direct, child)
      assert Social.member_of_group?(direct, grandchild)
    end

    test "an inherited member is removed in the parent, not in the sub-group", %{
      owner: owner,
      member: member,
      parent: parent
    } do
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})

      assert {:error, :inherited_member} = Social.remove_group_member(owner, child, member.id)
      assert Social.member_of_group?(member, child)
    end

    test "joining members start with the sub-groups' history read", %{
      owner: owner,
      parent: parent
    } do
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})
      {:ok, _} = Social.create_value(owner, child, %{"content" => "before"})

      newcomer = profile!("inh-newcomer")
      add_member!(owner, parent, newcomer)
      assert unread_count(newcomer, child) == 0

      {:ok, _} = Social.create_value(owner, child, %{"content" => "after"})
      assert unread_count(newcomer, child) == 1
    end

    test "the change is broadcast to the inheriting sub-group", %{owner: owner, parent: parent} do
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})
      Social.subscribe_group(child)
      child_id = child.id

      add_member!(owner, parent, profile!("inh-newcomer"))

      assert_receive {:group_updated, ^child_id}
    end
  end

  describe "parent roles" do
    test "role changes in the parent reach the sub-group, which keeps its own roles", %{
      owner: owner,
      member: member,
      parent: parent
    } do
      {:ok, _manifest} = Social.create_own_group_manifest(owner, parent)
      helpers = role!(owner, parent, "helpers")
      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})

      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, helpers.key)
      assert role_keys(child, member) == [helpers.key]

      assert {:error, :inherited_role} =
               Social.unassign_group_member_role(owner, child, member.id, helpers.key)

      assert Access.inherited_by_profile(child, [member.id]) == %{member.id => [helpers.key]}

      :ok = Social.unassign_group_member_role(owner, parent, member.id, helpers.key)
      assert role_keys(child, member) == []

      # Given in the child itself, the role outlives the same role in the parent.
      {:ok, _} = Social.assign_group_member_role(owner, child, member.id, "admin")
      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, "admin")
      :ok = Social.unassign_group_member_role(owner, parent, member.id, "admin")
      assert role_keys(child, member) == ["admin"]
    end
  end

  describe "switching inheritance" do
    test "turning it on brings the parent's members; off keeps them as direct members", %{
      owner: owner,
      member: member,
      parent: parent
    } do
      child = child!(owner, parent, "inh-child")
      {:ok, _} = Social.create_value(owner, child, %{"content" => "before"})
      refute Social.member_of_group?(member, child)

      {:ok, child} = Social.update_group(owner, child, %{"inherits_members" => "true"})
      assert Social.member_of_group?(member, child)
      assert inherited_membership?(child, member)
      assert unread_count(member, child) == 0

      {:ok, child} = Social.update_group(owner, child, %{"inherits_members" => "false"})
      refute inherited_membership?(child, member)
      assert Access.inherited_by_profile(child, [member.id]) == %{}

      {:ok, _} = Social.remove_group_member(owner, parent, member.id)
      assert Social.member_of_group?(member, child)
    end
  end

  describe "threads" do
    setup %{owner: owner, parent: parent} do
      {:ok, value} = Social.create_value(owner, parent, %{"content" => "thread me"})
      %{value: value}
    end

    test "hold later members of their group; the opener stays after leaving it", %{
      owner: owner,
      member: member,
      parent: parent,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(member, parent, value, %{"name" => "t"})
      assert thread.inherits_members

      latecomer = profile!("inh-late")
      add_member!(owner, parent, latecomer)
      assert Social.member_of_group?(latecomer, thread)

      {:ok, _} = Social.remove_group_member(owner, parent, member.id)
      assert Social.member_of_group?(member, thread)
      assert Access.for_profile(member, thread).admin?
    end

    test "made from the sub-group form, inherit too and cannot stop", %{
      owner: owner,
      member: member,
      parent: parent,
      value: value
    } do
      {:ok, thread} =
        Social.create_group(
          owner,
          parent,
          group_attrs("t", %{"parent_value_id" => to_string(value.id)})
        )

      assert thread.inherits_members
      assert Social.member_of_group?(member, thread)

      {:ok, thread} = Social.update_group(owner, thread, %{"inherits_members" => "false"})
      assert thread.inherits_members
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

  defp group!(owner, name) do
    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), group_attrs(name))
    group
  end

  defp child!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, parent, group_attrs(name, attrs))
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

  defp member_ids(group) do
    group |> Social.list_group_members() |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp role_keys(group, profile) do
    group |> Access.role_keys_by_profile([profile.id]) |> Map.get(profile.id, []) |> Enum.sort()
  end

  defp unread_count(profile, group) do
    profile |> Social.list_group_unread_counts([group]) |> Map.get(group.id, 0)
  end

  defp inherited_membership?(group, profile) do
    Repo.get_by!(GroupMembership, group_id: group.id, profile_id: profile.id).inherited
  end
end
