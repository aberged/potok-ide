defmodule PotokIde.Social.GroupPresetsTest do
  # The test of the failed second step locks the groups table with a trigger.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupPresets}

  @feed_build "priv/apps/feed.html"
  @feed_creator_build "priv/apps/feed_creator.html"
  @polls_build "priv/apps/glasanje.html"

  setup do
    {_account, owner} = account_with_profile!("preset-owner")
    {_account, member} = account_with_profile!("preset-member")
    {_account, outsider} = account_with_profile!("preset-outsider")

    root = Social.get_root_group!()
    parent = group_with_members!(owner, [member], %{"is_public" => true})

    %{owner: owner, member: member, outsider: outsider, root: root, parent: parent}
  end

  defp create(ctx, preset, choices \\ %{}, parent \\ nil) do
    parent = parent || ctx.parent

    Social.create_group_from_preset(
      ctx.owner,
      parent,
      preset,
      Map.merge(
        Map.merge(GroupPresets.defaults(preset, parent), %{"name" => "Nova grupa"}),
        choices
      )
    )
  end

  defp group_named?(name), do: Repo.exists?(from(g in Group, where: g.name == ^name))

  describe "a preset" do
    test "chat opens on the messages, for the members of the parent", ctx do
      assert {:ok, %{group: group, feed: nil}} = create(ctx, "chat")

      assert group.home_page == :chat
      assert group.inherits_members
      refute group.is_public
      refute group.uses_api
      assert Access.can?(ctx.member, group, :post_values)
    end

    test "folder opens on its sub-groups", ctx do
      assert {:ok, %{group: group}} = create(ctx, "folder")

      assert group.home_page == :subgroups
      assert group.inherits_members
      refute group.is_public
    end

    test "page opens on its description", ctx do
      assert {:ok, %{group: group}} = create(ctx, "page")

      assert group.home_page == :description
      refute group.uses_api
    end

    test "announcements let only administrators write", ctx do
      assert {:ok, %{group: group}} = create(ctx, "announcements")

      assert group.home_page == :chat

      assert Access.can?(ctx.owner, group, :post_values)
      assert Access.can?(ctx.member, group, :react)

      for permission <- [:post_values, :attach_files, :open_threads, :create_subgroups] do
        refute Access.can?(ctx.member, group, permission), "#{permission} stayed with the member"
      end

      assert Access.can?(ctx.member, ctx.parent, :post_values)
    end

    test "announcements keep the vote and leave starting polls to administrators", ctx do
      assert {:ok, %{group: group}} = create(ctx, "announcements")

      assert Access.can?(ctx.member, group, :vote_polls)
      refute Access.can?(ctx.member, group, :create_polls)
      assert Access.can?(ctx.owner, group, :create_polls)
    end

    test "polls open on the app, for members who start polls in it", ctx do
      assert {:ok, %{group: group} = created} = create(ctx, "polls")

      assert group.uses_api
      assert group.home_page == :description
      assert group.description_format == :html
      assert group.description == File.read!(@polls_build)
      refute group.is_public
      refute Map.has_key?(created, :feed) and created.feed

      assert Access.can?(ctx.member, group, :create_polls)
    end

    test "takes from the viewer only what is theirs to pick", ctx do
      assert {:ok, %{group: group}} =
               create(ctx, "chat", %{
                 "uses_api" => "true",
                 "description" => "<script></script>",
                 "home_page" => "description",
                 "parent_id" => ctx.root.id
               })

      refute group.uses_api
      refute group.description
      assert group.home_page == :chat
      assert group.parent_id == ctx.parent.id
    end
  end

  describe "a feed" do
    test "is a group with Feed and a .feed with FeedCreator", ctx do
      assert {:ok, %{group: group, feed: feed}} = create(ctx, "feed")

      assert group.uses_api
      assert group.home_page == :description
      assert group.description == File.read!(@feed_build)

      assert feed.name == ".feed"
      assert feed.parent_id == group.id
      assert feed.uses_api
      assert feed.description_format == :html
      assert feed.description == File.read!(@feed_creator_build)
    end

    # What `audience.ts` of FeedCreator checks, and warns about when it fails.
    test "leaves FeedCreator nothing to warn about", ctx do
      assert {:ok, %{group: group, feed: feed}} = create(ctx, "feed")

      assert group.is_public
      assert feed.is_public
      assert feed.inherits_members
      assert Social.member_of_group?(ctx.member, feed)

      refute Access.can?(ctx.member, feed, :create_subgroups)
      assert Access.can?(ctx.owner, feed, :create_subgroups)
      assert Access.can?(ctx.owner, feed, :edit_group)
      assert Access.can?(ctx.member, group, :create_subgroups)
    end

    test "a closed one has a closed .feed", ctx do
      assert {:ok, %{group: group, feed: feed}} = create(ctx, "feed", %{"is_public" => "false"})

      refute group.is_public
      refute feed.is_public
    end

    test "works at the top, where the group itself cannot inherit", ctx do
      assert {:ok, %{group: group, feed: feed}} = create(ctx, "feed", %{}, ctx.root)

      assert group.is_public
      refute group.inherits_members
      assert feed.inherits_members
    end

    test "stands whole or not at all, and nobody hears of it before", ctx do
      Repo.query!("""
      CREATE FUNCTION refuse_dot_feed() RETURNS trigger AS $$
      BEGIN
        IF NEW.name = '.feed' THEN RAISE EXCEPTION 'no feed'; END IF;
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_dot_feed BEFORE INSERT ON groups
      FOR EACH ROW EXECUTE FUNCTION refuse_dot_feed()
      """)

      Social.subscribe_group(ctx.parent)

      assert_raise Postgrex.Error, fn -> create(ctx, "feed", %{"name" => "Pola feeda"}) end

      refute group_named?("Pola feeda")
      refute_received {:group_updated, _group_id}
    end
  end

  describe "who starts from what" do
    test "only a feed is public", ctx do
      for preset <- GroupPresets.keys() -- ["feed"] do
        refute GroupPresets.defaults(preset, ctx.parent)["is_public"]
      end

      assert GroupPresets.defaults("feed", ctx.parent)["is_public"]
      assert GroupPresets.defaults("feed", ctx.root)["is_public"]
    end

    test "a feed under a closed group stays closed", ctx do
      closed = group_with_members!(ctx.owner, [], %{"is_public" => false})

      refute GroupPresets.defaults("feed", closed)["is_public"]
    end

    test "nothing inherits at the top", ctx do
      for preset <- GroupPresets.keys() do
        refute GroupPresets.defaults(preset, ctx.root)["inherits_members"]
        assert GroupPresets.defaults(preset, ctx.parent)["inherits_members"]
      end
    end
  end

  describe "what stands in the way" do
    test "no group without a name", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} = create(ctx, "feed", %{"name" => ""})

      assert Keyword.has_key?(changeset.errors, :name)
      refute group_named?(".feed")
    end

    test "only members of the parent create in it", ctx do
      assert {:error, :not_a_member_of_parent_group} =
               Social.create_group_from_preset(ctx.outsider, ctx.parent, "feed", %{
                 "name" => "Tuđ feed"
               })

      refute group_named?("Tuđ feed")
    end

    test "nor those who lost the right to", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.parent)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.parent,
          "everyone",
          :create_subgroups,
          :neutral
        )

      assert {:error, :not_permitted} =
               Social.create_group_from_preset(ctx.member, ctx.parent, "chat", %{
                 "name" => "Bez prava"
               })
    end
  end

  test "the news of a new group goes out", ctx do
    Social.subscribe_group(ctx.parent)
    parent_id = ctx.parent.id

    assert {:ok, _created} = create(ctx, "chat")

    assert_received {:group_updated, ^parent_id}
  end

  test "the builds of both apps are in place" do
    assert File.read!(@feed_build) =~ "potok"
    assert File.read!(@feed_creator_build) =~ "potok"
  end
end
