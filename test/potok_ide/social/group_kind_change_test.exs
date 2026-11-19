defmodule PotokIde.Social.GroupKindChangeTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    AppData,
    AppFiles,
    AppProfileStore,
    Group,
    GroupPresets,
    Value
  }

  @park_name "Prethodno"

  setup do
    {_account, owner} = account_with_profile!("kind-owner")
    {_account, member} = account_with_profile!("kind-member")
    parent = group_with_members!(owner, [member])

    %{owner: owner, member: member, parent: parent}
  end

  defp create(ctx, preset) do
    {:ok, %{group: group}} =
      Social.create_group_from_preset(
        ctx.owner,
        ctx.parent,
        preset,
        Map.merge(GroupPresets.defaults(preset, ctx.parent), %{"name" => "Grupa #{preset}"})
      )

    group
  end

  defp change(ctx, group, key), do: Social.change_group_preset(ctx.owner, group, key, @park_name)

  defp alts(group), do: Social.list_alt_descriptions(group)

  defp picture(group), do: Social.load_picture(Repo.get!(Group, group.id)).group_picture_url

  describe "between kinds without an app" do
    test "a chat becomes a folder: the home page and picture follow, the text stays", ctx do
      chat = create(ctx, "chat")
      {:ok, chat} = Social.update_group(ctx.owner, chat, %{"description" => "Pravila četa"})

      assert {:ok, %{group: folder, parked: nil, plan: plan}} = change(ctx, chat, "folder")

      assert folder.preset == :folder
      assert folder.home_page == :subgroups
      assert folder.description == "Pravila četa"
      refute folder.uses_api
      assert plan.picture == :replace
      assert picture(folder) == GroupPresets.picture("folder")
      assert alts(folder) == []
    end

    test "a picture of the group's own stays", ctx do
      chat = create(ctx, "chat")
      own = "data:image/png;base64,iVBORw0KGgo="
      {:ok, chat} = Social.update_group(ctx.owner, chat, %{"group_picture_url" => own})

      assert {:ok, %{group: page}} = change(ctx, chat, "page")

      assert page.home_page == :description
      assert picture(page) == own
    end

    test "no kind only drops the kind's name", ctx do
      form = create(ctx, "questionnaire")

      assert {:ok, %{group: group, parked: nil}} = change(ctx, form, nil)

      assert group.preset == nil
      assert group.uses_api
      assert group.description == form.description
      assert group.home_page == form.home_page
      assert picture(group) == GroupPresets.picture("questionnaire")
    end
  end

  describe "to an app" do
    test "a written text goes to an alternative only editors see", ctx do
      page = create(ctx, "page")

      {:ok, page} =
        Social.update_group(ctx.owner, page, %{
          "description" => "# Dobro došli",
          "description_name" => "Uvod"
        })

      assert {:ok, %{group: polls, parked: parked}} = change(ctx, page, "polls")

      assert polls.preset == :polls
      assert polls.uses_api
      assert polls.description_format == :html
      assert polls.description == File.read!("priv/apps/glasanje.html")
      assert polls.description_name == nil
      assert polls.home_page == :description

      assert parked.name == "Uvod"
      assert parked.description == "# Dobro došli"
      refute parked.uses_api
      assert parked.visible_role_keys == ["admin"]
      refute parked.for_guests
    end

    test "an empty description parks nothing", ctx do
      chat = create(ctx, "chat")

      assert {:ok, %{group: map, parked: nil}} = change(ctx, chat, "map")

      assert map.uses_api
      assert alts(map) == []
    end

    test "an app is overwritten and leaves with all it kept", ctx do
      form = create(ctx, "questionnaire")
      {:ok, _config} = AppData.save_config(ctx.owner, form, nil, %{"rules" => %{}}, 0)
      {:ok, answer} = data_value!(ctx.owner, form)
      {:ok, :ok} = AppProfileStore.put(ctx.owner, form, nil, "seen", 3)

      assert {:ok, %{group: orders, parked: parked}} = change(ctx, form, "orders")

      assert orders.preset == :orders
      assert orders.description == File.read!("priv/apps/narucivanje.html")
      assert parked.name == @park_name
      assert parked.uses_api
      assert parked.description == form.description

      # The new app starts empty; the old one keeps its config and answers.
      assert AppData.get_config(orders, nil) == nil
      assert AppData.get_config(orders, parked) != nil
      assert Repo.get!(Value, answer.id).alt_description_id == parked.id
      assert AppProfileStore.get(ctx.owner, orders, nil, "seen") == {:ok, nil}
      assert AppProfileStore.get(ctx.owner, orders, parked, "seen") == {:ok, 3}
      assert picture(orders) == GroupPresets.picture("orders")
    end

    test "a name taken by another description gets a number", ctx do
      form = create(ctx, "questionnaire")
      {:ok, _alt} = Social.create_alt_description(ctx.owner, form, %{"name" => @park_name})

      assert {:ok, %{parked: parked}} = change(ctx, form, "polls")

      assert parked.name == "#{@park_name} 2"
    end

    test "the parked app comes back as the default with its data", ctx do
      form = create(ctx, "questionnaire")
      {:ok, answer} = data_value!(ctx.owner, form)
      {:ok, %{group: polls, parked: parked}} = change(ctx, form, "polls")

      assert {:ok, back, _demoted} =
               Social.promote_alt_description(ctx.owner, polls, parked, "Opis", open: true)

      assert back.description == form.description
      assert Repo.get!(Value, answer.id).alt_description_id == nil
    end
  end

  describe "from an app to a kind without one" do
    test "the app leaves and the description starts empty", ctx do
      orders = create(ctx, "orders")

      assert {:ok, %{group: chat, parked: parked}} = change(ctx, orders, "chat")

      assert chat.preset == :chat
      refute chat.uses_api
      assert chat.description == ""
      assert chat.home_page == :chat
      assert parked.uses_api
    end

    test "an app pasted into a chat leaves too", ctx do
      chat = create(ctx, "chat")

      {:ok, chat} =
        Social.update_group(ctx.owner, chat, %{
          "uses_api" => "true",
          "description" => "<p>app</p>"
        })

      assert GroupPresets.shown(chat) == nil

      assert {:ok, %{group: folder, parked: parked}} = change(ctx, chat, "folder")

      refute folder.uses_api
      assert parked.description == "<p>app</p>"
    end
  end

  describe "a feed" do
    test "a group that becomes a feed gets its .feed", ctx do
      chat = create(ctx, "chat")

      assert {:ok, %{group: feed, feed: %Group{} = posts}} = change(ctx, chat, "feed")

      assert feed.uses_api
      assert posts.name == ".feed"
      assert posts.parent_id == feed.id
      assert posts.description == File.read!("priv/apps/feed_creator.html")
    end

    test "a feed that becomes a chat keeps its .feed, and takes it back later", ctx do
      feed = create(ctx, "feed")
      [posts] = Repo.all(from(g in Group, where: g.parent_id == ^feed.id))

      assert {:ok, %{group: chat, plan: plan}} = change(ctx, feed, "chat")
      assert plan.leaves_feed
      assert Repo.get(Group, posts.id)

      assert {:ok, %{feed: nil, plan: %{feed: :reuse}}} = change(ctx, chat, "feed")
      assert Repo.aggregate(from(g in Group, where: g.parent_id == ^feed.id), :count) == 1
    end

    test "its .feed has no kind to change", ctx do
      feed = create(ctx, "feed")
      posts = Repo.one!(from(g in Group, where: g.parent_id == ^feed.id))

      assert {:error, :kind_not_here} = change(ctx, posts, "chat")
    end
  end

  describe "what stands in the way" do
    test "the same kind again", ctx do
      chat = create(ctx, "chat")

      assert {:error, :same_kind} = change(ctx, chat, "chat")
    end

    test "a kind that lost its app is set up again", ctx do
      polls = create(ctx, "polls")
      {:ok, polls} = Social.update_group(ctx.owner, polls, %{"uses_api" => "false"})

      assert {:ok, %{group: group, parked: parked}} = change(ctx, polls, "polls")

      assert group.uses_api
      assert parked.description == polls.description
    end

    test "only an editor changes it", ctx do
      chat = create(ctx, "chat")

      assert {:error, :not_permitted} =
               Social.change_group_preset(ctx.member, chat, "folder", @park_name)
    end

    test "no map right under the root", ctx do
      chat = group_with_members!(ctx.owner, [])

      assert {:error, :kind_not_allowed} = change(ctx, chat, "map")
    end

    test "a group an app keeps its files in", ctx do
      form = create(ctx, "questionnaire")
      {:ok, _config} = AppData.save_config(ctx.owner, form, nil, %{"rules" => %{}}, 0)
      {:ok, %{"public" => files_id}} = AppFiles.ensure_groups(ctx.owner, form, nil)

      assert {:error, :kind_not_here} = change(ctx, Repo.get!(Group, files_id), "chat")
    end

    test "a group with all its alternatives taken", ctx do
      form = create(ctx, "questionnaire")

      for n <- 1..Social.max_alt_descriptions() do
        {:ok, _alt} = Social.create_alt_description(ctx.owner, form, %{"name" => "d#{n}"})
      end

      assert {:error, :too_many_alt_descriptions} = change(ctx, form, "polls")
      assert Repo.get!(Group, form.id).preset == :questionnaire
    end

    test "the root, a direct group and a thread have no kind" do
      facts = %{
        parent: %Group{id: 1, is_root: true},
        alt_names: [],
        max_alts: 20,
        feed_child?: false,
        file_group?: false,
        feed_part?: false,
        can_create_subgroups?: true,
        picture: nil
      }

      for group <- [
            %Group{is_root: true},
            %Group{is_direct: true},
            %Group{parent_value_id: 7}
          ] do
        assert {:error, :kind_not_here} = GroupPresets.change_plan(group, "chat", facts, "x")
      end

      assert {:error, :feed_not_permitted} =
               GroupPresets.change_plan(
                 %Group{preset: :chat},
                 "feed",
                 %{facts | can_create_subgroups?: false},
                 "x"
               )
    end
  end

  test "the page hears of it", ctx do
    form = create(ctx, "questionnaire")
    Social.subscribe_group(form)

    assert {:ok, _changed} = change(ctx, form, "polls")

    group_id = form.id
    assert_receive {:group_updated, ^group_id}
    assert_receive {:alt_descriptions_updated, ^group_id}
  end

  defp data_value!(profile, group) do
    Social.create_data_value(profile, group, %{"content" => "data:", "data" => %{"n" => 1}})
  end
end
