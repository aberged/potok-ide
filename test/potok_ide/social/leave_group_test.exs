defmodule PotokIde.Social.LeaveGroupTest do
  @moduledoc """
  A member leaving a group of their own accord: what goes with them, where
  they cannot leave, and what the access history keeps.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, GroupAccessChange, GroupRoleRequest, GroupValueRead}

  setup do
    {_owner_account, owner} = account_with_profile!("lv-owner")
    {_member_account, member} = account_with_profile!("lv-member")
    group = group_with_members!(owner, [member])

    {:ok, _} = Social.create_own_group_manifest(owner, group)
    {:ok, helpers} = Social.create_group_role(owner, group, %{"name" => "helpers"})
    {:ok, _} = Social.assign_group_member_role(owner, group, member.id, helpers.key)

    %{owner: owner, member: member, group: Social.get_group!(group.id), helpers: helpers}
  end

  test "a member leaves with their roles, and the history keeps it", ctx do
    assert {:ok, _} = Social.leave_group(ctx.member, ctx.group)

    refute Social.member_of_group?(ctx.member, ctx.group)
    assert Access.role_keys_by_profile(ctx.group, [ctx.member.id]) == %{}

    refute Repo.exists?(
             from(r in GroupValueRead,
               where: r.group_id == ^ctx.group.id and r.profile_id == ^ctx.member.id
             )
           )

    change =
      Repo.one!(
        from(c in GroupAccessChange,
          where: c.group_id == ^ctx.group.id and c.kind == :member_left
        )
      )

    assert change.actor_id == ctx.member.id
    assert change.subject_id == ctx.member.id
    assert change.data["roles"] == [%{"key" => ctx.helpers.key, "name" => "helpers"}]
  end

  test "a refused leave changes nothing and leaves no trace", ctx do
    assert {:error, :last_admin} = Social.leave_group(ctx.owner, ctx.group)
    assert Social.member_of_group?(ctx.owner, ctx.group)
    refute Repo.exists?(from(c in GroupAccessChange, where: c.kind == :member_left))
  end

  test "there is no leaving the root, a direct conversation or a group one is not in", ctx do
    {_account, stranger} = account_with_profile!("lv-stranger")
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

    assert {:error, :root_group} = Social.leave_group(ctx.member, Social.get_root_group!())
    assert {:error, :direct_group} = Social.leave_group(ctx.member, direct)
    assert {:error, :not_a_group_member} = Social.leave_group(stranger, ctx.group)
  end

  test "an admin may leave while another admin stays", ctx do
    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")

    assert {:ok, _} = Social.leave_group(ctx.owner, ctx.group)
    refute Social.member_of_group?(ctx.owner, ctx.group)
    assert Access.for_profile(ctx.member, ctx.group).admin?
  end

  test "an elected admin may resign, as long as an admin is left", ctx do
    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
    {:ok, group} = Social.set_elects_admins(ctx.owner, ctx.group, true)

    # Removing an admin takes a decision, leaving does not.
    assert {:error, :elected_admin} = Social.remove_group_member(ctx.owner, group, ctx.member)
    assert {:ok, _} = Social.leave_group(ctx.member, group)
    assert {:error, :last_admin} = Social.leave_group(ctx.owner, group)

    change =
      Repo.one!(
        from(c in GroupAccessChange, where: c.group_id == ^group.id and c.kind == :member_left)
      )

    assert "admin" in Enum.map(change.data["roles"], & &1["key"])
  end

  test "whoever is held through the parent leaves there, and leaves the sub-groups too", ctx do
    child =
      group_with_members!(ctx.owner, [], %{:parent => ctx.group, "inherits_members" => "true"})

    assert Social.member_of_group?(ctx.member, child)
    assert {:error, :inherited_member} = Social.leave_group(ctx.member, child)

    assert {:ok, _} = Social.leave_group(ctx.member, ctx.group)
    refute Social.member_of_group?(ctx.member, Social.get_group!(child.id))
  end

  test "a request for roles that waits goes with the membership", ctx do
    {:ok, _} =
      Social.set_role_request_rule(ctx.owner, ctx.group, ctx.helpers.key, %{
        "request_mode" => "approve"
      })

    {:ok, other} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "editors"})

    {:ok, _} =
      Social.set_role_request_rule(ctx.owner, ctx.group, other.key, %{"request_mode" => "approve"})

    assert {:ok, _} =
             PotokIde.Social.GroupRequests.request_roles(ctx.member, ctx.group, %{
               "role_keys" => [other.key],
               "note" => ""
             })

    assert Repo.exists?(from(r in GroupRoleRequest, where: r.profile_id == ^ctx.member.id))
    assert {:ok, _} = Social.leave_group(ctx.member, ctx.group)
    refute Repo.exists?(from(r in GroupRoleRequest, where: r.profile_id == ^ctx.member.id))
  end
end
