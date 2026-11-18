defmodule PotokIde.Social.MemberCountTest do
  @moduledoc """
  `groups.member_count`, which Postgres keeps from the memberships: it follows
  joins, removals and inheritance, counts people and never an app's process,
  and leaves the root at 0.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupMembership, Profile}

  defp count(%Group{id: id}),
    do: Repo.one!(from(g in Group, where: g.id == ^id, select: g.member_count))

  setup do
    {_account, owner} = account_with_profile!("mc-owner")
    {_account, member} = account_with_profile!("mc-member")
    group = group_with_members!(owner, [])
    %{owner: owner, member: member, group: group}
  end

  test "follows joins and removals", ctx do
    assert count(ctx.group) == 1

    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.member)
    assert count(ctx.group) == 2
    assert Social.count_group_members(ctx.group) == 2

    {:ok, _member} = Social.remove_group_member(ctx.owner, ctx.group, ctx.member)
    assert count(ctx.group) == 1
  end

  test "follows inheritance, all members of a statement at once", ctx do
    {_account, other} = account_with_profile!("mc-other")
    parent = group_with_members!(ctx.owner, [ctx.member, other])
    assert count(parent) == 3

    {:ok, child} =
      Social.create_group(ctx.owner, parent, %{"name" => "mc-child", "inherits_members" => "true"})

    assert count(child) == 3

    {:ok, _member} = Social.remove_group_member(ctx.owner, parent, other)
    assert count(child) == 2
  end

  test "counts people, not an app's process", ctx do
    process =
      Repo.insert!(%Profile{
        username: "proces.mc-#{System.unique_integer([:positive])}",
        kind: :process,
        description: "",
        description_format: :markdown
      })

    Repo.insert!(%GroupMembership{group_id: ctx.group.id, profile_id: process.id})
    assert count(ctx.group) == 1

    Repo.delete_all(from(m in GroupMembership, where: m.profile_id == ^process.id))
    assert count(ctx.group) == 1
  end

  test "leaves the root at 0, and counts its people when asked", ctx do
    root = Social.get_root_group!()
    assert count(root) == 0
    assert Social.count_group_members(root) >= 2
    assert ctx.owner.id > 0
  end
end
