defmodule PotokIde.Social.SubGroupTreeTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Social

  describe "sub_group_tree/3" do
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
        group: group,
        alpha: alpha,
        beta: beta,
        nested: nested,
        deep: deep,
        public_child: public_child,
        thread: thread,
        thread_child: thread_child
      }
    end

    test "nests the visible sub-groups below the group, sorted by name", ctx do
      assert %{nodes: nodes, ids: ids, thread_count: 1, truncated?: false} =
               Social.sub_group_tree(ctx.group, ctx.owner)

      assert Enum.map(nodes, & &1.group.name) == ["alpha", "Beta", "gamma-public"]
      assert [alpha, beta, public] = nodes

      assert alpha.descendant_count == 2
      assert [%{group: %{id: nested_id}, children: [%{group: %{id: deep_id}}]}] = alpha.children
      assert {nested_id, deep_id} == {ctx.nested.id, ctx.deep.id}
      assert alpha.group.member? and not alpha.group.public?

      assert [%{group: %{id: thread_id, thread?: true}} = thread] = beta.children
      assert thread_id == ctx.thread.id
      assert [%{group: %{name: "under-thread"}}] = thread.children

      assert public.group.id == ctx.public_child.id
      assert public.group.public?
      refute public.group.member?
      refute Enum.any?(nodes, &(&1.match? or &1.open?))

      assert Enum.sort(ids) ==
               Enum.sort([
                 ctx.alpha.id,
                 ctx.nested.id,
                 ctx.deep.id,
                 ctx.beta.id,
                 ctx.thread.id,
                 ctx.thread_child.id,
                 ctx.public_child.id
               ])
    end

    test "can leave out threads and what is below them", ctx do
      assert %{nodes: [_alpha, beta, _public], ids: ids, thread_count: 1} =
               Social.sub_group_tree(ctx.group, ctx.owner, threads?: false)

      assert beta.children == []
      assert beta.descendant_count == 0
      refute ctx.thread.id in ids
      refute ctx.thread_child.id in ids
    end

    test "a search keeps the matches and the folders on the way to them", ctx do
      assert %{nodes: [alpha]} = Social.sub_group_tree(ctx.group, ctx.owner, search: " DEEP ")

      assert alpha.open? and not alpha.match?
      assert [nested] = alpha.children
      assert nested.open? and not nested.match?
      assert [%{match?: true, open?: false, children: []}] = nested.children

      assert %{nodes: [%{group: %{name: "alpha"}, match?: true} = alpha]} =
               Social.sub_group_tree(ctx.group, ctx.owner, search: "alph")

      assert alpha.open?
      assert [%{group: %{name: "alpha-nested"}, match?: true, children: []}] = alpha.children

      # The counts are those of the whole tree, not of the search.
      assert alpha.descendant_count == 2
      assert [%{descendant_count: 1}] = alpha.children

      assert %{nodes: []} = Social.sub_group_tree(ctx.group, ctx.owner, search: "nothing-here")
    end

    test "without a profile only public groups are shown", ctx do
      assert %{nodes: [public], ids: [public_id], thread_count: 0} =
               Social.sub_group_tree(ctx.group, nil)

      assert public_id == ctx.public_child.id
      refute public.group.member?
    end
  end

  test "leaves out direct conversations below the root group" do
    owner = profile!("subtree-dm-owner")
    other = profile!("subtree-dm-other")
    {:ok, direct_group} = Social.get_or_create_direct_group(owner, other)
    group = group!(owner, "subtree-direct-group")

    assert %{ids: ids} = Social.sub_group_tree(Social.get_root_group!(), owner)
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

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
