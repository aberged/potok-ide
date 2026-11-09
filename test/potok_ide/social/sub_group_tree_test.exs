defmodule PotokIde.Social.SubGroupTreeTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIdeWeb.GroupLive.Show.SubGroupTree

  setup do
    owner = profile!("subtree-owner")
    other = profile!("subtree-other")
    group = group!(owner, "subtree-root")
    add_member!(owner, group, other)

    # Sorted by name, not by creation.
    beta = child!(owner, group, "Beta")
    alpha = child!(owner, group, "alpha")
    nested = child!(owner, alpha, "alpha-nested")
    deep = child!(owner, nested, "deep-leaf")

    # Public, but the owner is not a member: shown, as a non-member.
    public_child = child!(other, group, "gamma-public", %{"is_public" => true})

    # Private and the owner is not a member: never shown, nor what is below it.
    private_child = child!(other, group, "hidden-private")
    add_member!(other, child!(other, private_child, "below-private"), owner)

    {:ok, value} = Social.create_value(owner, beta, %{"content" => "thread start"})
    {:ok, thread} = Social.get_or_create_value_thread(owner, beta, value, %{"name" => "talk"})
    thread_child = child!(owner, thread, "under-thread")

    %{
      owner: owner,
      other: other,
      group: group,
      alpha: alpha,
      beta: beta,
      nested: nested,
      deep: deep,
      public_child: public_child,
      private_child: private_child,
      thread: thread,
      thread_child: thread_child
    }
  end

  describe "list_sub_group_folders/3" do
    test "lists the visible sub-groups of each folder, sorted by name", ctx do
      pages =
        Social.list_sub_group_folders(ctx.owner, [
          {ctx.group.id, 10, nil},
          {ctx.alpha.id, 10, nil},
          {ctx.deep.id, 10, nil}
        ])

      assert {[alpha, beta, public], false} = pages[ctx.group.id]
      assert Enum.map([alpha, beta, public], & &1.name) == ["alpha", "Beta", "gamma-public"]

      assert %{child_count: 1, thread_child_count: 0, member?: true, public?: false} = alpha
      refute alpha.thread?
      assert %{child_count: 1, thread_child_count: 1} = beta

      assert public.id == ctx.public_child.id
      assert public.public?
      refute public.member?

      assert {[%{id: nested_id, child_count: 1}], false} = pages[ctx.alpha.id]
      assert nested_id == ctx.nested.id
      assert pages[ctx.deep.id] == {[], false}
    end

    test "pages on after the last folder shown", ctx do
      group_id = ctx.group.id

      assert %{^group_id => {[_alpha, beta], true}} =
               Social.list_sub_group_folders(ctx.owner, [{group_id, 2, nil}])

      assert %{^group_id => {[%{name: "gamma-public"}], false}} =
               Social.list_sub_group_folders(ctx.owner, [{group_id, 2, beta}])
    end

    test "can leave out threads, still counting them", ctx do
      pages =
        Social.list_sub_group_folders(
          ctx.owner,
          [{ctx.group.id, 10, nil}, {ctx.beta.id, 10, nil}],
          threads?: false
        )

      assert {[_alpha, beta, _public], false} = pages[ctx.group.id]
      assert %{child_count: 0, thread_child_count: 1} = beta
      assert pages[ctx.beta.id] == {[], false}

      pages = Social.list_sub_group_folders(ctx.owner, [{ctx.beta.id, 10, nil}])
      assert {[%{id: thread_id, thread?: true}], false} = pages[ctx.beta.id]
      assert thread_id == ctx.thread.id
    end

    test "without a profile only public groups are shown", ctx do
      pages = Social.list_sub_group_folders(nil, [{ctx.group.id, 10, nil}])

      assert {[public], false} = pages[ctx.group.id]
      assert public.id == ctx.public_child.id
      refute public.member?
    end
  end

  describe "search_sub_group_folders/4" do
    test "finds matches at any depth with the folders on the way", ctx do
      assert {folders, false} = Social.search_sub_group_folders(ctx.group, ctx.owner, " DEEP ")

      assert Enum.map(folders, &{&1.name, &1.parent_id}) == [
               {"alpha", ctx.group.id},
               {"alpha-nested", ctx.alpha.id},
               {"deep-leaf", ctx.nested.id}
             ]

      assert {folders, false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "alph")
      assert Enum.map(folders, & &1.name) == ["alpha", "alpha-nested"]
      assert [%{child_count: 1}, %{child_count: 1}] = folders
    end

    test "leaves out threads and what is below them when asked", ctx do
      assert {folders, false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "under")
      assert Enum.map(folders, & &1.name) == ["Beta", "talk", "under-thread"]

      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "under", threads?: false)
    end

    test "never finds what is below a group the profile cannot see", ctx do
      assert {[], false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "below")
      assert {[], false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "nothing-here")
      assert {[], false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "  ")
    end
  end

  describe "search_sub_group_folders/4 by kind" do
    setup ctx do
      kind!(ctx.deep, :chat, false)
      kind!(ctx.public_child, :feed, true)
      # Made as a chat, then given an app: no longer a chat.
      kind!(ctx.beta, :chat, true)
      :ok
    end

    test "finds the groups of a kind at any depth with the folders on the way", ctx do
      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, preset: "chat")

      assert Enum.map(folders, &{&1.name, &1.parent_id}) == [
               {"alpha", ctx.group.id},
               {"alpha-nested", ctx.alpha.id},
               {"deep-leaf", ctx.nested.id}
             ]

      assert {[%{name: "gamma-public"}], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "", preset: "feed")
    end

    test "takes the search and the kind together", ctx do
      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "alpha", preset: "chat")

      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "leaf", preset: "chat")

      assert List.last(folders).name == "deep-leaf"
    end

    test "none finds the groups that show no kind", ctx do
      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, preset: "none")

      names = Enum.map(folders, & &1.name)
      assert "alpha" in names
      assert "Beta" in names
      refute "deep-leaf" in names
      refute "gamma-public" in names
    end

    test "an unknown kind and no search find nothing", ctx do
      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, preset: "bogus")
    end

    test "the tree opens the way to them and starts closed after", ctx do
      tree = SubGroupTree.load(ctx.group, ctx.owner, nil, preset: "chat")

      assert [%{group: %{name: "alpha"}, open?: true, children: [nested]}] = tree.nodes
      assert %{open?: true, children: [%{group: %{name: "deep-leaf"}}]} = nested

      after_kind = SubGroupTree.load(ctx.group, ctx.owner, tree)
      assert Enum.map(after_kind.nodes, & &1.group.name) == ["alpha", "Beta", "gamma-public"]
      assert Enum.all?(after_kind.nodes, &(not &1.open?))
    end
  end

  describe "search_sub_group_folders/4 by membership and authorship" do
    setup ctx do
      # Made by the other profile, the owner in it, deep down.
      add_member!(ctx.owner, ctx.deep, ctx.other)
      theirs = child!(ctx.other, ctx.deep, "theirs")
      add_member!(ctx.other, theirs, ctx.owner)
      %{theirs: theirs}
    end

    test "member finds the profile's groups at any depth, not the public ones it is not in",
         ctx do
      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, relation: "member")

      names = Enum.map(folders, & &1.name)
      assert "theirs" in names
      assert "deep-leaf" in names
      refute "gamma-public" in names
    end

    test "creator finds only the profile's own groups, with the folders on the way", ctx do
      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, relation: "creator")

      names = Enum.map(folders, & &1.name)
      assert "deep-leaf" in names
      assert "under-thread" in names
      refute "theirs" in names
      refute "gamma-public" in names

      # The other profile's own: `theirs` sits below the owner's private
      # folders, which it cannot see, so the search cannot reach it.
      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.other, "", relation: "creator")

      assert Enum.map(folders, &{&1.name, &1.parent_id}) == [
               {"below-private", ctx.private_child.id},
               {"gamma-public", ctx.group.id},
               {"hidden-private", ctx.group.id}
             ]

      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "theirs",
                 relation: "creator"
               )
    end

    test "takes the kind together with it", ctx do
      kind!(ctx.theirs, :chat, false)

      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil,
                 relation: "member",
                 preset: "chat"
               )

      assert List.last(folders).name == "theirs"

      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil,
                 relation: "creator",
                 preset: "chat"
               )
    end

    test "an unknown relation and no search find nothing", ctx do
      assert {[], false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, nil, relation: "bogus")
    end

    test "the tree opens the way and starts closed after", ctx do
      tree = SubGroupTree.load(ctx.group, ctx.other, nil, relation: "creator")
      assert Enum.any?(tree.nodes, & &1.open?)

      after_relation = SubGroupTree.load(ctx.group, ctx.other, tree)
      assert Enum.all?(after_relation.nodes, &(not &1.open?))
    end
  end

  describe "without the public groups the profile is not in" do
    setup %{owner: owner, other: other, group: group, alpha: alpha} do
      # Public and the owner is not in it, but in a group below it.
      way = child!(other, group, "delta-public", %{"is_public" => true})
      mine = child!(other, way, "delta-mine")
      add_member!(other, mine, owner)

      # Public and the owner is not in it, inside one of the owner's groups.
      add_member!(owner, alpha, other)
      child!(other, alpha, "alpha-public", %{"is_public" => true})

      %{way: way, mine: mine}
    end

    test "lists folders on every level without them, but on the way to the owner's", ctx do
      parents = [{ctx.group.id, 10, nil}, {ctx.alpha.id, 10, nil}, {ctx.way.id, 10, nil}]
      pages = Social.list_sub_group_folders(ctx.owner, parents, public?: false)

      assert {[alpha, _beta, way], false} = pages[ctx.group.id]
      assert way.id == ctx.way.id
      assert %{member?: false, public?: true, child_count: 1} = way
      assert %{child_count: 1} = alpha
      assert {[%{name: "alpha-nested"}], false} = pages[ctx.alpha.id]
      assert {[%{name: "delta-mine", member?: true}], false} = pages[ctx.way.id]

      pages = Social.list_sub_group_folders(ctx.owner, parents)

      assert {[%{child_count: 2}, _beta, _way, %{name: "gamma-public"}], false} =
               pages[ctx.group.id]
    end

    test "searches without them", ctx do
      assert {folders, false} = Social.search_sub_group_folders(ctx.group, ctx.owner, "public")

      assert Enum.map(folders, & &1.name) == [
               "alpha",
               "alpha-public",
               "delta-public",
               "gamma-public"
             ]

      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "public", public?: false)

      assert Enum.map(folders, & &1.name) == ["delta-public"]

      assert {folders, false} =
               Social.search_sub_group_folders(ctx.group, ctx.owner, "mine", public?: false)

      assert Enum.map(folders, & &1.name) == ["delta-mine", "delta-public"]
    end
  end

  test "leaves out direct conversations below the root group" do
    owner = profile!("subtree-dm-owner")
    other = profile!("subtree-dm-other")
    {:ok, direct_group} = Social.get_or_create_direct_group(owner, other)
    group = group!(owner, "subtree-direct-group")
    root_id = Social.get_root_group!().id

    assert %{^root_id => {folders, false}} =
             Social.list_sub_group_folders(owner, [{root_id, 1000, nil}])

    ids = Enum.map(folders, & &1.id)
    assert group.id in ids
    refute direct_group.id in ids
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

  defp group_attrs(name, attrs) do
    Map.merge(%{"name" => name, "description" => "", "description_format" => :markdown}, attrs)
  end

  defp group!(owner, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), group_attrs(name, attrs))
    group
  end

  defp child!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, parent, group_attrs(name, attrs))
    group
  end

  defp kind!(group, preset, uses_api) do
    from(g in Group, where: g.id == ^group.id)
    |> Repo.update_all(set: [preset: preset, uses_api: uses_api])
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
