defmodule PotokIde.Social.MemberInheritanceTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupMembership, GroupValueRead}

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

      assert_receive {:group_members_changed, ^child_id, %{changed: [:members]}}
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

  describe "inheriting by roles" do
    setup %{owner: owner, member: member, parent: parent} do
      {:ok, _manifest} = Social.create_own_group_manifest(owner, parent)
      council = role!(owner, parent, "council")
      helpers = role!(owner, parent, "helpers")
      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, council.key)
      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, helpers.key)
      other = profile!("inh-other")
      add_member!(owner, parent, other)

      %{council: council, helpers: helpers, other: other}
    end

    test "only the holders of a picked role come in, with all their parent roles", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council,
      helpers: helpers,
      other: other
    } do
      child = by_roles!(owner, parent, [council.key])

      assert child.inherit_role_keys == [council.key]
      assert member_ids(child) == Enum.sort([owner.id, member.id])
      assert role_keys(child, member) == Enum.sort([council.key, helpers.key])
      assert inherited_membership?(child, member)
      refute Social.member_of_group?(other, child)
    end

    test "taking the role in the parent brings a member in and sends them away, down a chain",
         %{owner: owner, parent: parent, council: council, other: other} do
      child = by_roles!(owner, parent, [council.key])
      grandchild = child!(owner, child, "inh-grandchild", %{"inherits_members" => "true"})
      refute Social.member_of_group?(other, grandchild)

      {:ok, _} = Social.assign_group_member_role(owner, parent, other.id, council.key)
      assert inherited_membership?(child, other)
      assert Social.member_of_group?(other, grandchild)

      :ok = Social.unassign_group_member_role(owner, parent, other.id, council.key)
      refute Social.member_of_group?(other, child)
      refute Social.member_of_group?(other, grandchild)
    end

    test "a direct member who holds none of them keeps the membership, not the parent's roles",
         %{owner: owner, parent: parent, council: council, helpers: helpers, other: other} do
      child = by_roles!(owner, parent, [council.key])
      add_member!(owner, child, other)
      {:ok, _} = Social.assign_group_member_role(owner, parent, other.id, helpers.key)

      assert role_keys(child, other) == []
      assert Access.inherited_by_profile(child, [other.id]) == %{}

      {:ok, _} = Social.assign_group_member_role(owner, parent, other.id, council.key)
      assert role_keys(child, other) == Enum.sort([council.key, helpers.key])
      assert Map.has_key?(Access.inherited_by_profile(child, [other.id]), other.id)

      :ok = Social.unassign_group_member_role(owner, parent, other.id, council.key)
      assert role_keys(child, other) == []
      refute inherited_membership?(child, other)
      assert {:ok, _} = Social.remove_group_member(owner, child, other.id)
    end

    test "narrowing sends away whoever no longer fits; direct members and the editor stay", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council,
      other: other
    } do
      editor = profile!("inh-editor")
      add_member!(owner, parent, editor)
      {:ok, _} = Social.assign_group_member_role(owner, parent, editor.id, "admin")
      guest = profile!("inh-direct")

      child = child!(owner, parent, "inh-child", %{"inherits_members" => "true"})
      add_member!(owner, child, guest)
      {:ok, _value} = Social.create_value(owner, child, %{"content" => "read me"})
      Social.mark_group_values_read(other, child)
      assert inherited_membership?(child, editor)

      other_id = other.id
      child_id = child.id
      Social.subscribe_profile(other)

      {:ok, child} =
        Social.update_group(editor, child, %{"inherit_role_keys" => ["", council.key]})

      assert child.inherit_role_keys == [council.key]

      assert member_ids(child) ==
               Enum.sort([owner.id, member.id, editor.id, guest.id])

      assert_received {:group_membership_changed, ^other_id, ^child_id, :removed}

      refute Repo.exists?(
               from r in GroupValueRead,
                 where: r.group_id == ^child.id and r.profile_id == ^other.id
             )

      refute inherited_membership?(child, editor)
      assert Access.for_profile(editor, child).admin?
      assert Access.inherited_by_profile(child, [editor.id]) == %{}

      {:ok, child} = Social.update_group(editor, child, %{"inherit_role_keys" => [""]})
      assert child.inherit_role_keys == []
      assert inherited_membership?(child, other)
    end

    test "only roles of the parent are taken, and everyone means every member", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council,
      other: other
    } do
      child = by_roles!(owner, parent, [council.key])

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.update_group(owner, child, %{"inherit_role_keys" => ["nope"]})

      assert changeset.errors[:inherit_role_keys]

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_group(
                 owner,
                 parent,
                 group_attrs("inh-bad", %{
                   "inherits_members" => "true",
                   "inherit_role_keys" => ["everyone-else"]
                 })
               )

      assert changeset.errors[:inherit_role_keys]

      everyone = by_roles!(owner, parent, ["everyone", council.key])
      assert everyone.inherit_role_keys == []
      assert member_ids(everyone) == Enum.sort([owner.id, member.id, other.id])

      admins = by_roles!(owner, parent, ["admin"])
      assert member_ids(admins) == [owner.id]
    end

    test "are dropped when inheriting stops, on withdrawing, without inheriting and in threads",
         %{owner: owner, parent: parent, council: council} do
      child = by_roles!(owner, parent, [council.key])

      {:ok, stopped} = Social.update_group(owner, child, %{"inherits_members" => "false"})
      assert stopped.inherit_role_keys == []

      {:ok, again} =
        Social.update_group(owner, stopped, %{
          "inherits_members" => "true",
          "inherit_role_keys" => [council.key]
        })

      assert again.inherit_role_keys == [council.key]
      {:ok, withdrawn} = Social.withdraw_group(owner, again)
      assert withdrawn.inherit_role_keys == []

      plain = child!(owner, parent, "inh-plain", %{"inherit_role_keys" => [council.key]})
      assert plain.inherit_role_keys == []

      {:ok, value} = Social.create_value(owner, parent, %{"content" => "thread me"})

      {:ok, thread} =
        Social.create_group(
          owner,
          parent,
          group_attrs("t", %{
            "parent_value_id" => to_string(value.id),
            "inherit_role_keys" => [council.key]
          })
        )

      assert thread.inherits_members
      assert thread.inherit_role_keys == []
    end

    test "deleting a picked role sends away who held only that one and leaves the pick", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council,
      helpers: helpers,
      other: other
    } do
      {:ok, _} = Social.assign_group_member_role(owner, parent, other.id, council.key)
      child = by_roles!(owner, parent, [council.key, helpers.key])
      assert Social.member_of_group?(other, child)

      {:ok, _role} = Social.delete_group_role(owner, parent, council.key)

      child = Repo.get!(Group, child.id)
      assert child.inherits_members
      assert child.inherit_role_keys == [helpers.key]
      refute Social.member_of_group?(other, child)
      assert inherited_membership?(child, member)
    end

    test "a pick left with no role stops inheriting, and nobody falls out", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council,
      helpers: helpers
    } do
      child = by_roles!(owner, parent, [council.key])
      child_id = child.id
      Social.subscribe_group(child)

      {:ok, _role} = Social.delete_group_role(owner, parent, council.key)

      child = Repo.get!(Group, child.id)
      refute child.inherits_members
      assert child.inherit_role_keys == []
      assert Social.member_of_group?(member, child)
      refute inherited_membership?(child, member)
      assert role_keys(child, member) == [helpers.key]
      assert_received {:group_updated, ^child_id}
    end

    test "reverting the parent's manifest forgets its roles the same way", %{
      owner: owner,
      member: member,
      parent: parent,
      council: council
    } do
      child = by_roles!(owner, parent, [council.key])

      {:ok, _manifest} = Social.revert_to_inherited_group_manifest(owner, parent)

      child = Repo.get!(Group, child.id)
      refute child.inherits_members
      assert child.inherit_role_keys == []
      assert Social.member_of_group?(member, child)
      assert role_keys(child, member) == []
    end
  end

  describe "withdrawing a group" do
    setup %{owner: owner, parent: parent} do
      %{child: child!(owner, parent, "inh-post", %{"inherits_members" => "true"})}
    end

    test "inherited members leave with their read markers, direct ones stay", %{
      owner: owner,
      member: member,
      child: child
    } do
      guest = profile!("inh-guest")
      add_member!(owner, child, guest)
      {:ok, _value} = Social.create_value(owner, child, %{"content" => "read me"})
      Social.mark_group_values_read(member, child)

      assert {:ok, child} = Social.withdraw_group(owner, child)

      refute child.is_public
      refute child.inherits_members
      assert member_ids(child) == Enum.sort([owner.id, guest.id])

      refute Repo.exists?(
               from r in GroupValueRead,
                 where: r.group_id == ^child.id and r.profile_id == ^member.id
             )
    end

    test "unlike stopping to inherit, where nobody leaves", %{
      owner: owner,
      member: member,
      child: child
    } do
      {:ok, child} = Social.update_group(owner, child, %{"inherits_members" => "false"})

      assert Social.member_of_group?(member, child)
    end

    test "the one who withdraws stays, with the role they held", %{
      owner: owner,
      parent: parent,
      member: member,
      child: child
    } do
      {:ok, _} = Social.assign_group_member_role(owner, parent, member.id, "admin")
      assert inherited_membership?(child, member)
      assert Access.for_profile(member, child).admin?

      {:ok, child} = Social.withdraw_group(member, child)

      assert member_ids(child) == Enum.sort([owner.id, member.id])
      refute inherited_membership?(child, member)
      assert Access.for_profile(member, child).admin?
    end

    test "a direct member stays, without the role that came through the parent", %{
      owner: owner,
      parent: parent,
      child: child
    } do
      guest = profile!("inh-helper")
      add_member!(owner, child, guest)
      add_member!(owner, parent, guest)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, parent)
      helpers = role!(owner, parent, "helpers")
      {:ok, _} = Social.assign_group_member_role(owner, parent, guest.id, helpers.key)
      assert helpers.key in role_keys(child, guest)

      {:ok, _} = Social.withdraw_group(owner, child)

      assert Social.member_of_group?(guest, child)
      assert role_keys(child, guest) == []
    end

    test "threads of the group follow it", %{owner: owner, member: member, child: child} do
      {:ok, value} = Social.create_value(owner, child, %{"content" => "thread me"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, child, value, %{"name" => "t"})
      :ok = Social.join_thread(member, thread)
      assert Social.member_of_group?(member, thread)

      {:ok, _} = Social.withdraw_group(owner, child)

      refute Social.member_of_group?(member, thread)
    end

    test "tells the pages of those who left", %{owner: owner, member: member, child: child} do
      child_id = child.id
      member_id = member.id
      Social.subscribe_profile(member)
      Social.subscribe_group(child)

      {:ok, _} = Social.withdraw_group(owner, child)

      assert_received {:group_updated, ^child_id}
      assert_received {:group_membership_changed, ^member_id, ^child_id, :removed}
    end

    test "publishing again brings the members back and counts from then", %{
      owner: owner,
      member: member,
      child: child
    } do
      {:ok, child} = Social.withdraw_group(owner, child)
      assert child.published_at == nil

      {:ok, child} = Social.update_group(owner, child, %{"inherits_members" => "true"})

      assert child.published_at
      assert Social.member_of_group?(member, child)
    end

    test "needs the permission to edit the group", %{member: member, child: child} do
      assert {:error, :not_permitted} = Social.withdraw_group(member, child)
      assert Social.member_of_group?(member, child)
    end
  end

  describe "threads" do
    setup %{owner: owner, parent: parent} do
      {:ok, value} = Social.create_value(owner, parent, %{"content" => "thread me"})
      %{value: value}
    end

    test "start with the opener and the value's author, and take in members as they take part", %{
      owner: owner,
      member: member,
      parent: parent,
      value: value
    } do
      bystander = profile!("inh-bystander")
      add_member!(owner, parent, bystander)

      {:ok, thread} = Social.get_or_create_value_thread(member, parent, value, %{"name" => "t"})
      assert thread.inherits_members
      assert Social.member_of_group?(member, thread)
      assert Social.member_of_group?(owner, thread)
      refute Social.member_of_group?(bystander, thread)

      latecomer = profile!("inh-late")
      add_member!(owner, parent, latecomer)
      refute Social.member_of_group?(latecomer, thread)

      :ok = Social.join_thread(latecomer, thread)
      assert Social.member_of_group?(latecomer, thread)
      assert Access.for_profile(owner, thread).admin?
    end

    test "take in only members of their group", %{owner: owner, parent: parent, value: value} do
      {:ok, thread} = Social.get_or_create_value_thread(owner, parent, value, %{"name" => "t"})
      outsider = profile!("inh-outsider")

      :ok = Social.join_thread(outsider, thread)
      refute Social.member_of_group?(outsider, thread)
    end

    test "a participant leaves with the group; the opener stays after leaving it", %{
      owner: owner,
      member: member,
      parent: parent,
      value: value
    } do
      taking_part = profile!("inh-part")
      add_member!(owner, parent, taking_part)
      {:ok, thread} = Social.get_or_create_value_thread(member, parent, value, %{"name" => "t"})
      :ok = Social.join_thread(taking_part, thread)

      {:ok, _} = Social.remove_group_member(owner, parent, taking_part.id)
      refute Social.member_of_group?(taking_part, thread)

      {:ok, _} = Social.remove_group_member(owner, parent, member.id)
      assert Social.member_of_group?(member, thread)
      assert Access.for_profile(member, thread).admin?
    end

    test "a thread inside a thread takes a member into both", %{
      owner: owner,
      member: member,
      parent: parent,
      value: value
    } do
      {:ok, thread} = Social.get_or_create_value_thread(owner, parent, value, %{"name" => "t"})
      {:ok, inner_value} = Social.create_value(owner, thread, %{"content" => "deeper"})

      {:ok, inner} =
        Social.get_or_create_value_thread(owner, thread, inner_value, %{"name" => "t2"})

      refute Social.member_of_group?(member, thread)
      :ok = Social.join_thread(member, inner)
      assert Social.member_of_group?(member, thread)
      assert Social.member_of_group?(member, inner)
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
      refute Social.member_of_group?(member, thread)
      :ok = Social.join_thread(member, thread)
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

  defp by_roles!(owner, parent, keys) do
    child!(owner, parent, "inh-by-roles-#{System.unique_integer([:positive])}", %{
      "inherits_members" => "true",
      "inherit_role_keys" => keys
    })
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
