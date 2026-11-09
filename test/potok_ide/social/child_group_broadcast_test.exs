defmodule PotokIde.Social.ChildGroupBroadcastTest do
  @moduledoc """
  What the parent's pages hear when a sub-group comes, changes or goes: one
  targeted message, never `group_updated`, which reloaded every page on the
  parent (on the root, every user's). A direct chat tells the root nothing.
  """

  # The root's topic is shared: tests running at the same time would post there.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {_account, owner} = account_with_profile!("child-owner")
    {_other_account, other} = account_with_profile!("child-other")
    root = Social.get_root_group!()
    Social.subscribe_group(root)
    %{owner: owner, other: other, root: root}
  end

  test "a direct chat tells the root's pages nothing", %{owner: owner, other: other, root: root} do
    root_id = root.id
    assert {:ok, _chat} = Social.get_or_create_direct_group(owner, other)

    refute_received {:group_updated, ^root_id}
    refute_received {:child_group_changed, ^root_id, _child}
  end

  test "a new, changed or deleted sub-group sends the parent one targeted message",
       %{owner: owner, root: root} do
    root_id = root.id

    {:ok, group} =
      Social.create_group(owner, root, %{"name" => "child-public", "is_public" => true})

    group_id = group.id
    owner_id = owner.id

    assert_received {:child_group_changed, ^root_id,
                     %{
                       id: ^group_id,
                       change: :created,
                       public?: true,
                       inherits?: false,
                       creator_id: ^owner_id
                     }}

    refute_received {:group_updated, ^root_id}

    {:ok, _updated} = Social.update_group(owner, group, %{"is_public" => false})

    assert_received {:child_group_changed, ^root_id,
                     %{id: ^group_id, change: :updated, public?: false}}

    refute_received {:group_updated, ^root_id}

    {:ok, _deleted} = Social.delete_group(owner, Social.get_group!(group_id))
    assert_received {:child_group_changed, ^root_id, %{id: ^group_id, change: :deleted}}
    refute_received {:group_updated, ^root_id}
  end
end
