defmodule PotokIde.Social.AccessCacheTest do
  @moduledoc """
  What `Access` keeps of who holds which roles: a second ask costs no query,
  every change through `Social` reaches it at once, and a transaction always
  reads the database.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Access

  setup do
    {_account, owner} = account_with_profile!("ac-owner")
    {_account, member} = account_with_profile!("ac-member")
    group = group_with_members!(owner, [member], %{"is_public" => true})
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "savet"})
    %{owner: owner, member: member, group: Social.get_group!(group.id), role: role.key}
  end

  # The queries this process makes while `fun` runs.
  defp queries(fun) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:potok_ide, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:query, ref})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  defp drain(ref, count) do
    receive do
      {:query, ^ref} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end

  test "a second ask for the same profile and group costs no query", ctx do
    first = Access.for_profile(ctx.member, ctx.group)
    {second, count} = queries(fn -> Access.for_profile(ctx.member, ctx.group) end)

    assert count == 0
    assert second == first
    assert second.member?
  end

  test "a role given or taken reaches a kept access", ctx do
    refute ctx.role in Access.for_profile(ctx.member, ctx.group).role_keys

    {:ok, _role} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, ctx.role)
    assert ctx.role in Access.for_profile(ctx.member, ctx.group).role_keys

    :ok = Social.unassign_group_member_role(ctx.owner, ctx.group, ctx.member.id, ctx.role)
    refute ctx.role in Access.for_profile(ctx.member, ctx.group).role_keys
  end

  test "a removal and a block reach a kept access", ctx do
    assert Access.for_profile(ctx.member, ctx.group).member?

    {:ok, _member} = Social.remove_group_member(ctx.owner, ctx.group, ctx.member)
    access = Access.for_profile(ctx.member, ctx.group)
    refute access.member?
    refute access.blocked?

    {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.member)
    assert Access.for_profile(ctx.member, ctx.group).blocked?

    :ok = Social.unblock_from_group(ctx.owner, ctx.group, ctx.member.id)
    refute Access.for_profile(ctx.member, ctx.group).blocked?
  end

  test "several groups at once keep and use the same", ctx do
    other = group_with_members!(ctx.owner, [])
    groups = [ctx.group, other]

    first = Access.for_profile_in_groups(ctx.member, groups)
    {second, count} = queries(fn -> Access.for_profile_in_groups(ctx.member, groups) end)

    assert count == 0
    assert second == first
    assert second[ctx.group.id].member?
    refute second[other.id].member?
    assert Access.for_profile(ctx.member, other) == second[other.id]
  end

  test "a transaction reads the database", ctx do
    _kept = Access.for_profile(ctx.member, ctx.group)

    {:ok, count} =
      Repo.transaction(fn ->
        {_access, count} = queries(fn -> Access.for_profile(ctx.member, ctx.group) end)
        count
      end)

    assert count > 0
  end
end
