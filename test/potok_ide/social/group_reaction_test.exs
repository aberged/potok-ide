defmodule PotokIde.Social.GroupReactionTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupReaction}

  setup do
    {_account, owner} = account_with_profile!("reacts-owner")
    {_account, member} = account_with_profile!("reacts-member")
    {_account, visitor} = account_with_profile!("reacts-visitor")

    group = group!(owner, "reacts-public", %{"is_public" => true})
    add_member!(owner, group, member)

    %{owner: owner, member: member, visitor: visitor, group: group}
  end

  defp group!(owner, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  # With its own manifest, whose "everyone" no longer reacts.
  defp without_everyone_react!(owner, group) do
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    {:ok, _role} =
      Social.set_group_role_permission(owner, group, "everyone", :react, :neutral)
  end

  defp can_react?(profile, group) do
    Access.can_react_to_group?(profile, Access.for_profile(profile, group), group)
  end

  describe "who may react" do
    test "a member, and a visitor of a public group", ctx do
      assert can_react?(ctx.member, ctx.group)
      assert can_react?(ctx.visitor, ctx.group)
    end

    test "no visitor of a private group", ctx do
      private = group!(ctx.owner, "reacts-private", %{"is_public" => false})

      assert can_react?(ctx.owner, private)
      refute can_react?(ctx.visitor, private)
      assert {:error, :not_permitted} = Social.toggle_group_reaction(ctx.visitor, private, "👍")
    end

    test "nobody without a profile", ctx do
      refute Access.can_react_to_group?(nil, Access.for_profile(nil, ctx.group), ctx.group)
    end

    test "with \"everyone\" not allowed to, only those with a role that is", ctx do
      without_everyone_react!(ctx.owner, ctx.group)

      refute can_react?(ctx.member, ctx.group)
      refute can_react?(ctx.visitor, ctx.group)
      assert can_react?(ctx.owner, ctx.group)
      assert {:error, :not_permitted} = Social.toggle_group_reaction(ctx.visitor, ctx.group, "👍")
    end

    test "a role that denies it binds a member, not a visitor", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, muted} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "muted"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, muted.key, :react, :deny)

      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, muted.key)

      refute can_react?(ctx.member, ctx.group)
      assert can_react?(ctx.visitor, ctx.group)
    end

    test "not on the root, a direct conversation or a thread", ctx do
      root = Social.get_root_group!()
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      refute can_react?(ctx.owner, root)
      refute can_react?(ctx.owner, direct)
      refute can_react?(ctx.owner, thread)
      assert {:error, :not_permitted} = Social.toggle_group_reaction(ctx.owner, thread, "👍")
    end
  end

  describe "toggle_group_reaction/3" do
    test "adds and takes back, and a profile can hold several emoji", ctx do
      assert {:ok, [%{emoji: "👍", count: 1, mine?: true, names: ["reacts-member"]}]} =
               Social.toggle_group_reaction(ctx.member, ctx.group, "👍")

      assert {:ok, [%{emoji: "👍"}, %{emoji: "❤️"}]} =
               Social.toggle_group_reaction(ctx.member, ctx.group, "❤️")

      assert {:ok, [%{emoji: "❤️"}]} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")
      assert {:ok, []} = Social.toggle_group_reaction(ctx.member, ctx.group, "❤️")
    end

    test "turns down what is no emoji", ctx do
      for text <- ["a", "👍👍", "", String.duplicate("👍", 40)] do
        assert {:error, %Ecto.Changeset{}} =
                 Social.toggle_group_reaction(ctx.member, ctx.group, text)
      end

      assert {:error, :invalid_emoji} = Social.toggle_group_reaction(ctx.member, ctx.group, 7)
      assert Repo.aggregate(GroupReaction, :count) == 0
    end

    test "a reaction that lost the race changes nothing", ctx do
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")

      assert {:ok, %GroupReaction{id: nil}} =
               %GroupReaction{group_id: ctx.group.id, profile_id: ctx.member.id}
               |> GroupReaction.changeset(%{emoji: "👍"})
               |> Repo.insert(on_conflict: :nothing)

      assert Repo.aggregate(GroupReaction, :count) == 1
    end

    test "tells the group's pages", ctx do
      Social.subscribe_group(ctx.group)
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.visitor, ctx.group, "👍")

      group_id = ctx.group.id
      assert_receive {:group_reactions_updated, ^group_id}
    end

    test "goes with the group and with the profile", ctx do
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")
      {:ok, _reactions} = Social.toggle_group_reaction(ctx.visitor, ctx.group, "👍")

      Repo.delete!(ctx.visitor)
      assert Repo.aggregate(GroupReaction, :count) == 1

      Repo.delete!(%Group{id: ctx.group.id})
      assert Repo.aggregate(GroupReaction, :count) == 0
    end
  end

  describe "group_reaction_summaries/2" do
    test "groups by emoji, in the order of first use, and knows the viewer's own", ctx do
      other = group!(ctx.owner, "reacts-other", %{"is_public" => true})

      {:ok, _} = Social.toggle_group_reaction(ctx.visitor, ctx.group, "❤️")
      {:ok, _} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")
      {:ok, _} = Social.toggle_group_reaction(ctx.owner, ctx.group, "❤️")

      group_id = ctx.group.id

      assert %{
               ^group_id => [
                 %{
                   emoji: "❤️",
                   count: 2,
                   mine?: true,
                   names: ["reacts-visitor", "reacts-owner"]
                 },
                 %{emoji: "👍", count: 1, mine?: false, names: ["reacts-member"]}
               ]
             } = summaries = Social.group_reaction_summaries([group_id, other.id], ctx.visitor)

      refute Map.has_key?(summaries, other.id)
    end

    test "a viewer with no profile holds none of them", ctx do
      {:ok, _} = Social.toggle_group_reaction(ctx.member, ctx.group, "👍")
      group_id = ctx.group.id

      assert %{^group_id => [%{count: 1, mine?: false}]} =
               Social.group_reaction_summaries([group_id], nil)
    end

    test "names at most 20 and counts them all", ctx do
      for number <- 1..21 do
        {_account, profile} = account_with_profile!("reacts-crowd-#{number}")
        {:ok, _} = Social.toggle_group_reaction(profile, ctx.group, "👍")
      end

      group_id = ctx.group.id
      assert %{^group_id => [reaction]} = Social.group_reaction_summaries([group_id], nil)
      assert reaction.count == 21
      assert length(reaction.names) == 20
    end
  end

  describe "group_comment_counts/1" do
    test "counts the chat, without data or threads", ctx do
      other = group!(ctx.owner, "reacts-silent", %{"is_public" => true})

      {:ok, first} = Social.create_value(ctx.owner, ctx.group, %{"content" => "one"})
      {:ok, _second} = Social.create_value(ctx.member, ctx.group, %{"content" => "two"})

      {:ok, _data} =
        Social.create_data_value(ctx.member, ctx.group, %{
          "content" => "data:",
          "data" => %{"a" => 1},
          "content_format" => "markdown"
        })

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, first, %{"name" => "talk"})

      {:ok, _in_thread} = Social.create_value(ctx.owner, thread, %{"content" => "deep"})

      group_id = ctx.group.id

      assert %{^group_id => 2} = counts = Social.group_comment_counts([group_id, other.id])
      refute Map.has_key?(counts, other.id)
    end

    test "a deleted comment no longer counts", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "one"})
      {:ok, _deleted} = Social.delete_value(ctx.owner, value)

      assert Social.group_comment_counts([ctx.group.id]) == %{}
    end
  end

  describe "Access.for_profile_in_groups/2" do
    test "gives what for_profile/2 gives, with one query for the memberships", ctx do
      private = group!(ctx.owner, "reacts-closed", %{"is_public" => false})
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, helpers} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "helpers"})
      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, helpers.key)

      groups = [ctx.group, private]

      for profile <- [ctx.owner, ctx.member, ctx.visitor, nil] do
        by_group = Access.for_profile_in_groups(profile, groups)

        for group <- groups do
          assert by_group[group.id] == Access.for_profile(profile, group)
        end
      end

      assert Access.for_profile_in_groups(ctx.owner, []) == %{}
    end
  end
end
