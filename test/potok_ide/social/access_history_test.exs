defmodule PotokIde.Social.AccessHistoryTest do
  @moduledoc """
  Each change of access is written in the step that makes it, with who did
  it; a change that did not happen, or was refused, leaves nothing; blocks
  are read only by those who may lift them, and nothing by someone outside.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccessHistory, GroupAccessChange}

  setup do
    {_, owner} = account_with_profile!("ah-owner")
    {_, member} = account_with_profile!("ah-member")
    {_, other} = account_with_profile!("ah-other")
    {_, outsider} = account_with_profile!("ah-outsider")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "ah-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    add_member!(owner, group, member)
    add_member!(owner, group, other)

    %{owner: owner, member: member, other: other, outsider: outsider, group: group}
  end

  defp kinds(group) do
    Repo.all(
      from(c in GroupAccessChange, where: c.group_id == ^group.id, order_by: c.id, select: c.kind)
    )
  end

  defp last(group) do
    Repo.one(
      from(c in GroupAccessChange,
        where: c.group_id == ^group.id,
        order_by: [desc: c.id],
        limit: 1
      )
    )
  end

  test "roles given and taken by an admin, once each", ctx do
    {:ok, _} = Social.create_own_group_manifest(ctx.owner, ctx.group)
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "savet"})

    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)
    # Giving it again changes nothing, and says nothing.
    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)

    given = last(ctx.group)
    assert %{kind: :role_given, role_key: key, data: %{}} = given
    assert {given.actor_id, given.subject_id, key} == {ctx.owner.id, ctx.member.id, role.key}

    :ok = Social.unassign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)
    assert %{kind: :role_taken, actor_id: actor_id} = last(ctx.group)
    assert actor_id == ctx.owner.id

    assert kinds(ctx.group) == [:manifest_copied, :role_added, :role_given, :role_taken]
  end

  test "a refused change leaves nothing", ctx do
    assert {:error, :not_permitted} =
             Social.assign_group_member_role(ctx.member, ctx.group, ctx.other.id, "admin")

    assert {:error, :not_permitted} = Social.set_elects_admins(ctx.member, ctx.group, true)
    assert {:error, _} = Social.remove_group_member(ctx.member, ctx.group, ctx.other)
    assert kinds(ctx.group) == []
  end

  test "the statute: permissions, names and how a role is had, only when they change", ctx do
    {:ok, _} = Social.create_own_group_manifest(ctx.owner, ctx.group)
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "savet"})

    {:ok, _} =
      Social.set_group_role_permission(ctx.owner, ctx.group, role.key, :delete_values, :allow)

    {:ok, _} =
      Social.set_group_role_permission(ctx.owner, ctx.group, role.key, :delete_values, :allow)

    assert %{kind: :permission_set, data: data} = last(ctx.group)

    assert data == %{
             "role" => "savet",
             "permission" => "delete_values",
             "from" => "neutral",
             "to" => "allow"
           }

    {:ok, _} = Social.rename_group_role(ctx.owner, ctx.group, role.key, %{"name" => "savet"})
    {:ok, _} = Social.rename_group_role(ctx.owner, ctx.group, role.key, %{"name" => "odbor"})
    assert %{kind: :role_renamed, data: %{"from" => "savet", "to" => "odbor"}} = last(ctx.group)

    {:ok, _} =
      Social.set_role_request_rule(ctx.owner, ctx.group, role.key, %{"request_mode" => "approve"})

    assert %{kind: :request_rule_set, data: %{"to" => "approve"}} = last(ctx.group)

    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)
    {:ok, _} = Social.delete_group_role(ctx.owner, ctx.group, role.key)

    assert %{kind: :role_removed, data: %{"role" => "odbor", "assignments" => 1}} =
             last(ctx.group)

    {:ok, _} = Social.revert_to_inherited_group_manifest(ctx.owner, ctx.group)

    assert kinds(ctx.group) == [
             :manifest_copied,
             :role_added,
             :permission_set,
             :role_renamed,
             :request_rule_set,
             :role_given,
             :role_removed,
             :manifest_dropped
           ]
  end

  test "settings that let people in, with what they were and became", ctx do
    {:ok, group} = Social.update_group(ctx.owner, ctx.group, %{"name" => "ah-renamed"})
    assert kinds(group) == []

    {:ok, group} = Social.update_group(ctx.owner, group, %{"is_public" => false})

    assert %{kind: :settings_changed, data: %{"is_public" => [true, false]}, actor_id: actor_id} =
             last(group)

    assert actor_id == ctx.owner.id

    {:ok, group} =
      Social.set_join_rule(ctx.owner, group, %{
        "join_mode" => "choose",
        "join_poll" => %{"quorum_percent" => "50", "majority" => "simple", "hours" => "24"}
      })

    assert %{kind: :join_rule_set, data: %{"from" => "approve", "to" => "choose"}} = last(group)

    {:ok, _group} = Social.set_elects_admins(ctx.owner, group, true)
    assert %{kind: :elections_on} = last(group)
  end

  test "removals and blocks, which only those who may remove members read", ctx do
    {:ok, _} = Social.remove_group_member(ctx.owner, ctx.group, ctx.other)
    assert %{kind: :member_removed, subject_id: subject_id} = last(ctx.group)
    assert subject_id == ctx.other.id

    {:ok, _} = Social.block_from_group(ctx.owner, ctx.group, ctx.outsider)
    {:ok, _} = Social.block_from_group(ctx.owner, ctx.group, ctx.outsider)
    :ok = Social.unblock_from_group(ctx.owner, ctx.group, ctx.outsider.id)
    :ok = Social.unblock_from_group(ctx.owner, ctx.group, ctx.outsider.id)

    assert kinds(ctx.group) == [:member_removed, :member_blocked, :member_unblocked]

    owner_sees = AccessHistory.list(ctx.group, Access.for_profile(ctx.owner, ctx.group))
    member_sees = AccessHistory.list(ctx.group, Access.for_profile(ctx.member, ctx.group))
    outsider_sees = AccessHistory.list(ctx.group, Access.for_profile(ctx.outsider, ctx.group))

    assert Enum.map(owner_sees, & &1.kind) == [
             :member_unblocked,
             :member_blocked,
             :member_removed
           ]

    assert Enum.map(member_sees, & &1.kind) == [:member_removed]
    assert outsider_sees == []
    # Who did it and to whom come along.
    assert [%{actor: %{username: "ah-owner"}, subject: %{username: "ah-other"}}] = member_sees
  end

  test "who sees an alternative description", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "Za savet",
        "description" => "x"
      })

    assert kinds(ctx.group) == []

    {:ok, _} =
      Social.update_alt_description(ctx.owner, ctx.group, alt, %{"visible_role_keys" => ["admin"]})

    assert %{kind: :alt_visibility_set, data: %{"alt" => "Za savet", "roles" => ["admin"]}} =
             last(ctx.group)
  end

  test "the history goes back a page at a time", ctx do
    access = Access.for_profile(ctx.owner, ctx.group)

    for _ <- 1..3 do
      {:ok, _} = Social.set_elects_admins(ctx.owner, %{ctx.group | elects_admins: false}, true)

      Repo.update_all(from(g in PotokIde.Social.Group, where: g.id == ^ctx.group.id),
        set: [elects_admins: false]
      )
    end

    [first, second | _] = AccessHistory.list(ctx.group, access)

    assert [^second | _] =
             AccessHistory.list(ctx.group, access, before: {first.inserted_at, first.id})
  end
end
