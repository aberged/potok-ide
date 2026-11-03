defmodule PotokIde.Social.ShareTargetsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {_account, owner} = account_with_profile!("share-owner")
    {_account, member} = account_with_profile!("share-member")
    %{owner: owner, member: member}
  end

  defp ids(groups), do: Enum.map(groups, & &1.id)

  test "lists the profile's groups with a chat, the most recently active first", ctx do
    quiet = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Quiet"})
    busy = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Busy"})
    other = group_with_members!(ctx.owner, [], %{"name" => "Not mine"})
    {:ok, _value} = Social.create_value(ctx.owner, busy, %{"content" => "hello"})

    groups = Social.list_share_target_groups(ctx.member)

    assert ids(groups) == [busy.id, quiet.id]
    refute other.id in ids(groups)
    # The root has no chat.
    refute Social.get_root_group!().id in ids(Social.list_share_target_groups(ctx.owner))
    assert Enum.all?(groups, &(&1.parent.id == Social.get_root_group!().id))
  end

  test "leaves out threads and groups where the profile may not post", ctx do
    group = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Talk"})
    muted = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Muted"})
    {:ok, value} = Social.create_value(ctx.owner, group, %{"content" => "thread me"})
    {:ok, thread} = Social.get_or_create_value_thread(ctx.owner, group, value, %{"name" => "t"})

    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, muted)

    {:ok, _role} =
      Social.set_group_role_permission(ctx.owner, muted, "everyone", :post_values, :neutral)

    member_ids = ids(Social.list_share_target_groups(ctx.member))

    assert group.id in member_ids
    refute thread.id in member_ids
    refute muted.id in member_ids
    # The owner is the admin there, who may always post.
    assert muted.id in ids(Social.list_share_target_groups(ctx.owner))
  end

  test "searches group names and the other member of direct conversations", ctx do
    {_account, friend} = account_with_profile!("share-friend")
    garden = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Garden club"})
    _books = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Books"})
    {:ok, direct} = Social.get_or_create_direct_group(ctx.member, friend)
    # The name is set once from both usernames; the search goes by the member.
    direct = Repo.update!(Ecto.Changeset.change(direct, name: "dm"))

    assert ids(Social.list_share_target_groups(ctx.member, search: "garden")) == [garden.id]

    [found] = Social.list_share_target_groups(ctx.member, search: "FRIEND")
    assert found.id == direct.id

    assert Enum.map(found.members, & &1.id) |> Enum.sort() ==
             Enum.sort([ctx.member.id, friend.id])

    # Their own name does not match every direct conversation.
    assert Social.list_share_target_groups(ctx.member, search: "share-member") == []
  end

  test "takes at most :limit groups", ctx do
    for name <- ["One", "Two", "Three"] do
      group_with_members!(ctx.owner, [ctx.member], %{"name" => name})
    end

    assert length(Social.list_share_target_groups(ctx.member, limit: 2)) == 2
  end
end
