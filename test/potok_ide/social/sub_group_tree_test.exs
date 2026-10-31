defmodule PotokIde.Social.SubGroupTreeTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Social

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

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
