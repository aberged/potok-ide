defmodule PotokIde.Social.GroupShortcutsTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Notices
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupShortcut}

  setup do
    root = Social.get_root_group!()
    owner = profile!("shortcut-owner")
    ana = profile!("shortcut-ana")
    bob = profile!("shortcut-bob")

    # A public municipality, a public local community in it, and a private
    # council deep inside, where ana was invited straight in.
    town = child!(owner, root, "Opstina", %{"is_public" => true})
    community = child!(owner, town, "Mesna zajednica", %{"is_public" => true})
    council = child!(owner, community, "Savet")
    add_member!(owner, council, ana)

    %{
      root: root,
      owner: owner,
      ana: ana,
      bob: bob,
      town: town,
      community: community,
      council: council
    }
  end

  describe "create_group_shortcut/3" do
    test "puts a deep group among the root's sub-groups for those who see it", ctx do
      assert {:ok, %GroupShortcut{} = shortcut} =
               Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)

      assert shortcut.parent_id == ctx.root.id
      assert shortcut.target_id == ctx.council.id
      assert shortcut.creator_id == ctx.ana.id

      for viewer <- [ctx.ana, ctx.owner] do
        row = Enum.find(children(ctx.root, viewer), &(&1.id == ctx.council.id))
        assert row.shortcut_id == shortcut.id
        assert row.name == "Savet"
      end

      # A private group stays hidden from whoever is not in it.
      refute Enum.any?(children(ctx.root, ctx.bob), &(&1.id == ctx.council.id))
    end

    test "a shortcut to a public group follows the root's switch", ctx do
      {:ok, shortcut} = Social.create_group_shortcut(ctx.owner, ctx.root, ctx.community.id)

      assert [%{shortcut_id: shortcut_id}] =
               Enum.filter(children(ctx.root, ctx.bob), &(&1.id == ctx.community.id))

      assert shortcut_id == shortcut.id
      refute Enum.any?(children(ctx.root, ctx.bob, public: false), &(&1.id == ctx.community.id))

      {:ok, _follow} = Notices.follow(ctx.bob, ctx.community)
      assert Enum.any?(children(ctx.root, ctx.bob, public: false), &(&1.id == ctx.community.id))
    end

    test "works in any group, not only the root", ctx do
      place = child!(ctx.ana, ctx.root, "Ana's place")

      assert {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, place, ctx.council.id)
      assert [%Group{id: id}] = children(place, ctx.ana)
      assert id == ctx.council.id
    end

    test "refuses what a shortcut cannot open", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.community, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.community, value, %{"name" => "talk"})

      {:ok, direct} = Social.get_or_create_direct_group(ctx.ana, ctx.bob)
      record = child!(ctx.owner, ctx.town, "Record")
      Repo.update_all(from(g in Group, where: g.id == ^record.id), set: [external_key: "r1"])
      hidden = child!(ctx.owner, ctx.root, "Hidden")

      for target <- [ctx.root, thread, direct, record, hidden] do
        assert {:error, :invalid_target} =
                 Social.create_group_shortcut(ctx.owner, ctx.root, target.id),
               "#{target.name} should be refused"
      end

      # The group it stands in, and one of its own sub-groups.
      assert {:error, :invalid_target} =
               Social.create_group_shortcut(ctx.owner, ctx.town, ctx.town.id)

      assert {:error, :invalid_target} =
               Social.create_group_shortcut(ctx.owner, ctx.town, ctx.community.id)

      # A private group the profile does not see.
      assert {:error, :invalid_target} =
               Social.create_group_shortcut(ctx.bob, ctx.root, ctx.council.id)

      assert Repo.aggregate(GroupShortcut, :count) == 0
    end

    test "takes what making a sub-group takes, once per group", ctx do
      assert {:error, :not_a_member_of_parent_group} =
               Social.create_group_shortcut(ctx.bob, ctx.town, ctx.council.id)

      assert {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)

      assert {:error, :already_listed} =
               Social.create_group_shortcut(ctx.owner, ctx.root, ctx.council.id)
    end

    test "tells the pages of the group it stands in", ctx do
      Phoenix.PubSub.subscribe(PotokIde.PubSub, "groups:#{ctx.root.id}")
      council_id = ctx.council.id
      root_id = ctx.root.id

      {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, council_id)

      assert_receive {:child_group_changed, ^root_id, %{id: ^council_id, change: :created}}
    end
  end

  describe "delete_group_shortcut/2" do
    test "its author or an admin of the group it stands in takes it away", ctx do
      place = child!(ctx.owner, ctx.root, "Place")
      add_member!(ctx.owner, place, ctx.ana)
      add_member!(ctx.owner, place, ctx.bob)
      {:ok, by_ana} = Social.create_group_shortcut(ctx.ana, place, ctx.council.id)
      {:ok, by_owner} = Social.create_group_shortcut(ctx.owner, place, ctx.community.id)

      assert {:error, :not_permitted} = Social.delete_group_shortcut(ctx.bob, by_ana.id)
      assert {:error, :not_permitted} = Social.delete_group_shortcut(ctx.ana, by_owner.id)

      assert {:ok, _deleted} = Social.delete_group_shortcut(ctx.ana, by_ana.id)
      assert {:ok, _deleted} = Social.delete_group_shortcut(ctx.owner, by_owner.id)
      assert {:error, :not_found} = Social.delete_group_shortcut(ctx.owner, by_owner.id)

      # The groups stay where they are.
      assert Repo.get(Group, ctx.council.id)
      assert Repo.get(Group, ctx.community.id)
      assert children(place, ctx.owner) == []
    end

    test "deleting either group takes its shortcuts with it", ctx do
      place = child!(ctx.owner, ctx.root, "Place")
      leaf = child!(ctx.owner, ctx.community, "Leaf")
      {:ok, _to_leaf} = Social.create_group_shortcut(ctx.owner, ctx.root, leaf.id)
      {:ok, _in_place} = Social.create_group_shortcut(ctx.owner, place, ctx.council.id)

      root_id = ctx.root.id
      leaf_id = leaf.id
      Phoenix.PubSub.subscribe(PotokIde.PubSub, "groups:#{root_id}")

      assert {:ok, _deleted} = Social.delete_group(ctx.owner, leaf)
      assert_receive {:child_group_changed, ^root_id, %{id: ^leaf_id, change: :deleted}}

      assert {:ok, _deleted} = Social.delete_group(ctx.owner, place)
      assert Repo.aggregate(GroupShortcut, :count) == 0
    end
  end

  describe "the sub-groups list" do
    test "a group the list holds already never stands in it twice", ctx do
      # Ana sees the inner group but not the private one around it, so the
      # root lists it for her by itself (a detached group).
      secret = child!(ctx.owner, ctx.root, "Secret")
      inner = child!(ctx.owner, secret, "Inner")
      add_member!(ctx.owner, inner, ctx.ana)
      {:ok, _shortcut} = Social.create_group_shortcut(ctx.owner, ctx.root, inner.id)

      assert [%{shortcut_id: nil}] =
               Enum.filter(children(ctx.root, ctx.ana), &(&1.id == inner.id))

      assert [%{shortcut_id: id}] =
               Enum.filter(children(ctx.root, ctx.owner), &(&1.id == inner.id))

      assert is_integer(id)
    end

    test "filters by the target's name, kind and the viewer's relation to it", ctx do
      {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)

      assert ids(children(ctx.root, ctx.ana, search: "savet")) == [ctx.council.id]
      assert ctx.council.id in ids(children(ctx.root, ctx.ana, relation: "member"))
      refute ctx.council.id in ids(children(ctx.root, ctx.ana, relation: "creator"))
      refute ctx.council.id in ids(children(ctx.root, ctx.ana, is_direct: true))
      assert Social.count_child_groups_for_profile(ctx.root, ctx.ana, search: "savet") == 1
    end

    test "sorts a shortcut by the unread values of its target", ctx do
      {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
      {:ok, _value} = Social.create_value(ctx.owner, ctx.council, %{"content" => "news"})

      overview = Social.unread_overview(ctx.ana)

      assert [%{id: first} | _rest] = children(ctx.root, ctx.ana, unread_overview: overview)
      assert first == ctx.council.id
      assert Social.unread_counts_for(overview, [ctx.council.id]) == %{ctx.council.id => 1}

      # The root's own count holds the value once.
      assert overview.total == 1
    end

    test "counts a group's shortcuts among its sub-groups", ctx do
      place = child!(ctx.owner, ctx.root, "Place", %{"is_public" => true})
      {:ok, _shortcut} = Social.create_group_shortcut(ctx.owner, place, ctx.council.id)

      assert %{sub_group_count: 1} = Enum.find(children(ctx.root, ctx.ana), &(&1.id == place.id))
      assert %{sub_group_count: 0} = Enum.find(children(ctx.root, ctx.bob), &(&1.id == place.id))
    end

    test "the folder view shows a shortcut as a leaf that opens its target", ctx do
      place = child!(ctx.owner, ctx.root, "Place")
      add_member!(ctx.owner, place, ctx.ana)
      {:ok, shortcut} = Social.create_group_shortcut(ctx.owner, place, ctx.council.id)

      root_id = ctx.root.id
      place_id = place.id

      %{^root_id => {top, false}, ^place_id => {[leaf], false}} =
        Social.list_sub_group_folders(ctx.ana, [{root_id, 50, nil}, {place_id, 50, nil}])

      assert %{child_count: 1} = Enum.find(top, &(&1.id == place.id))
      assert leaf.id == ctx.council.id
      assert leaf.shortcut_id == shortcut.id
      assert leaf.child_count == 0
      assert leaf.member?

      # Bob sees neither the leaf nor a way down to it.
      assert %{^place_id => {[], false}} =
               Social.list_sub_group_folders(ctx.bob, [{place_id, 50, nil}])
    end
  end

  describe "search_shortcut_targets/3" do
    test "offers the viewer's own groups the group does not hold yet", ctx do
      results = Social.search_shortcut_targets(ctx.ana, ctx.root, "")

      assert [%{group: %{id: council_id}, parent_name: "Mesna zajednica"}] = results
      assert council_id == ctx.council.id

      {:ok, _shortcut} = Social.create_group_shortcut(ctx.ana, ctx.root, ctx.council.id)
      assert Social.search_shortcut_targets(ctx.ana, ctx.root, "") == []
    end

    test "finds every group the viewer sees by its name", ctx do
      assert [%{group: %{id: id}}] = Social.search_shortcut_targets(ctx.bob, ctx.root, "mesna")
      assert id == ctx.community.id

      # Not the private council, and not a sub-group of the group itself.
      assert Social.search_shortcut_targets(ctx.bob, ctx.root, "savet") == []
      assert Social.search_shortcut_targets(ctx.bob, ctx.root, "opstina") == []
    end
  end

  defp children(group, profile, opts \\ []),
    do: Social.list_child_groups_for_profile(group, profile, opts)

  defp ids(groups), do: Enum.map(groups, & &1.id)

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

  defp child!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
