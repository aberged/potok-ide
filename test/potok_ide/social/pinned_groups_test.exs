defmodule PotokIde.Social.PinnedGroupsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.PinnedGroups

  setup do
    {_account, owner} = account_with_profile!("pin-owner")
    {_account, member} = account_with_profile!("pin-member")
    %{owner: owner, member: member}
  end

  test "pins the groups it sees, in order, with the way to them", ctx do
    building =
      group_with_members!(ctx.owner, [], %{"name" => "Pin building", "is_public" => true})

    entrance =
      group_with_members!(ctx.owner, [ctx.member], %{:parent => building, "name" => "Entrance"})

    garden = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Garden"})

    assert :ok = Social.pin_group(ctx.member, entrance.id)
    assert :ok = Social.pin_group(ctx.member, garden.id)
    # Twice is once.
    assert :ok = Social.pin_group(ctx.member, entrance.id)

    assert [
             %{group: %{id: entrance_id}, path: ["Pin building"]},
             %{group: %{id: garden_id}, path: []}
           ] = Social.list_pinned_groups(ctx.member)

    assert {entrance_id, garden_id} == {entrance.id, garden.id}
    assert Social.group_pinned?(ctx.member, garden.id)
    refute Social.group_pinned?(ctx.owner, garden.id)

    :ok = Social.unpin_group(ctx.member, entrance.id)
    assert [%{group: %{id: ^garden_id}}] = Social.list_pinned_groups(ctx.member)
  end

  test "tells the profile's pages", ctx do
    garden = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Garden"})
    Social.subscribe_profile(ctx.member)
    member_id = ctx.member.id

    :ok = Social.pin_group(ctx.member, garden.id)
    assert_receive {:group_pins_changed, ^member_id}

    :ok = Social.unpin_group(ctx.member, garden.id)
    assert_receive {:group_pins_changed, ^member_id}
  end

  test "refuses what it cannot see, the root and a direct conversation", ctx do
    private = group_with_members!(ctx.owner, [], %{"name" => "Private"})
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

    assert {:error, :not_found} = Social.pin_group(ctx.member, private.id)
    assert {:error, :not_pinnable} = Social.pin_group(ctx.member, Social.get_root_group!().id)
    assert {:error, :not_pinnable} = Social.pin_group(ctx.member, direct.id)
    assert Social.list_pinned_groups(ctx.member) == []
  end

  test "keeps to #{PinnedGroups.max()} pins", ctx do
    groups =
      for n <- 1..(PinnedGroups.max() + 1),
          do: group_with_members!(ctx.owner, [ctx.member], %{"name" => "Pin #{n}"})

    {first, [last]} = Enum.split(groups, PinnedGroups.max())

    for group <- first, do: assert(:ok = Social.pin_group(ctx.member, group.id))
    assert {:error, :too_many} = Social.pin_group(ctx.member, last.id)
    assert length(Social.list_pinned_groups(ctx.member)) == PinnedGroups.max()
  end

  test "a group it no longer sees is not listed, and a deleted one drops its pin", ctx do
    kept = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Kept"})
    left = group_with_members!(ctx.owner, [ctx.member], %{"name" => "Left"})
    :ok = Social.pin_group(ctx.member, kept.id)
    :ok = Social.pin_group(ctx.member, left.id)

    {:ok, _} = Social.remove_group_member(ctx.owner, left, ctx.member)
    assert [%{group: %{name: "Kept"}}] = Social.list_pinned_groups(ctx.member)

    {:ok, _} = Social.delete_group(ctx.owner, kept)
    assert Social.list_pinned_groups(ctx.member) == []
    refute Social.group_pinned?(ctx.member, kept.id)
  end
end
