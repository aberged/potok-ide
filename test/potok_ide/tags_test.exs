defmodule PotokIde.TagsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Social
  alias PotokIde.Tags
  alias PotokIde.Tags.Tag

  setup do
    {_account, owner} = account_with_profile!("tag-owner")
    {_account, member} = account_with_profile!("tag-member")
    {_account, outsider} = account_with_profile!("tag-outsider")
    group = group_with_members!(owner, [member])

    %{owner: owner, member: member, outsider: outsider, group: group}
  end

  defp value!(profile, group, content \\ "hello") do
    {:ok, value} = Social.create_value(profile, group, %{"content" => content})
    value
  end

  defp attachment!(profile, group) do
    {:ok, value} =
      Social.create_value(profile, group, %{"content" => ""}, [
        %{
          storage_key: "tags-test/#{System.unique_integer([:positive])}",
          filename: "notes.txt",
          content_type: "text/plain",
          byte_size: 5
        }
      ])

    hd(Repo.preload(value, :attachments).attachments)
  end

  defp names(tags_by_id, id), do: tags_by_id |> Map.get(id, []) |> Enum.map(& &1.name)

  describe "private tags" do
    test "are seen only by their owner", %{owner: owner, member: member, group: group} do
      value = value!(owner, group)

      assert {:ok, %Tag{owner_id: owner_id}} =
               Tags.add_tag(member, :value, value.id, "later", :private)

      assert owner_id == member.id
      assert names(Tags.tags_for(member, :value, [value.id]), value.id) == ["later"]
      assert Tags.tags_for(owner, :value, [value.id]) == %{}
    end

    test "are reused whatever the case, spaces or leading #", %{member: member, group: group} do
      value = value!(member, group)
      other = value!(member, group, "other")

      {:ok, tag} = Tags.add_tag(member, :value, value.id, "  Big   Ideas ", :private)
      assert tag.name == "Big Ideas"

      assert {:ok, same} = Tags.add_tag(member, :value, other.id, "#big ideas", :private)
      assert same.id == tag.id

      # Adding it again is a no-op.
      assert {:ok, ^same} = Tags.add_tag(member, :value, other.id, "BIG IDEAS", :private)
      assert names(Tags.tags_for(member, :value, [other.id]), other.id) == ["Big Ideas"]
    end

    test "reject invalid names", %{member: member, group: group} do
      value = value!(member, group)

      assert {:error, %Ecto.Changeset{}} = Tags.add_tag(member, :value, value.id, "#", :private)

      assert {:error, %Ecto.Changeset{}} =
               Tags.add_tag(member, :value, value.id, String.duplicate("a", 33), :private)

      assert {:error, %Ecto.Changeset{}} = Tags.add_tag(member, :value, value.id, "a/b", :private)
    end

    test "go on anything the profile can open", ctx do
      %{owner: owner, member: member, outsider: outsider, group: group} = ctx
      value = value!(owner, group)
      attachment = attachment!(owner, group)
      event = create_event!(owner, group, event_attrs(today()))

      for {kind, id} <- [
            value: value.id,
            attachment: attachment.id,
            event: event.id,
            group: group.id,
            profile: owner.id
          ] do
        assert {:ok, _tag} = Tags.add_tag(member, kind, id, "mine", :private)
      end

      # An outsider opens profiles and public groups only.
      assert {:error, :not_found} = Tags.add_tag(outsider, :value, value.id, "x", :private)

      assert {:error, :not_found} =
               Tags.add_tag(outsider, :attachment, attachment.id, "x", :private)

      assert {:error, :not_found} = Tags.add_tag(outsider, :event, event.id, "x", :private)
      assert {:error, :not_found} = Tags.add_tag(outsider, :group, group.id, "x", :private)
      assert {:ok, _tag} = Tags.add_tag(outsider, :profile, owner.id, "x", :private)

      assert {:error, :not_found} =
               Tags.add_tag(member, :group, Social.get_root_group!().id, "x", :private)
    end

    test "at most ten on an item per profile", %{member: member, group: group} do
      value = value!(member, group)

      for n <- 1..10, do: {:ok, _} = Tags.add_tag(member, :value, value.id, "t#{n}", :private)

      assert {:error, :too_many_tags} = Tags.add_tag(member, :value, value.id, "t11", :private)
      # A tag already on the item is still fine.
      assert {:ok, _tag} = Tags.add_tag(member, :value, value.id, "t1", :private)
    end

    test "are taken off, renamed and deleted only by their owner", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)
      {:ok, tag} = Tags.add_tag(member, :value, value.id, "draft", :private)

      assert {:error, :not_found} = Tags.remove_tag(owner, :value, value.id, tag.id)
      assert {:error, :not_found} = Tags.rename_private_tag(owner, tag.id, "x")
      assert {:error, :not_found} = Tags.delete_private_tag(owner, tag.id)

      assert {:ok, renamed} = Tags.rename_private_tag(member, tag.id, "final")
      assert renamed.name == "final"

      assert {:ok, _tag} = Tags.remove_tag(member, :value, value.id, tag.id)
      assert Tags.tags_for(member, :value, [value.id]) == %{}
      # Private tags stay until deleted.
      assert [%Tag{name: "final"}] = Tags.list_directory(member).mine

      assert {:ok, _deleted} = Tags.delete_private_tag(member, tag.id)
      assert Tags.list_directory(member).mine == []
    end
  end

  describe "public tags" do
    test "need manage_tags in the item's group and are seen by its members", ctx do
      %{owner: owner, member: member, outsider: outsider, group: group} = ctx
      value = value!(member, group)

      assert {:error, :not_permitted} = Tags.add_tag(member, :value, value.id, "news", :public)

      assert {:ok, %Tag{owner_id: nil} = tag} =
               Tags.add_tag(owner, :value, value.id, "news", :public)

      assert names(Tags.tags_for(member, :value, [value.id]), value.id) == ["news"]
      assert names(Tags.tags_for(owner, :value, [value.id]), value.id) == ["news"]
      assert {:error, :not_found} = Tags.get_taggable(outsider, :value, value.id)

      assert {:error, :not_permitted} = Tags.remove_tag(member, :value, value.id, tag.id)
      assert {:ok, _tag} = Tags.remove_tag(owner, :value, value.id, tag.id)
    end

    test "a role with manage_tags may put them", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      {:ok, role} = Social.create_group_role(owner, group, %{"name" => "taggers"})

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, role.key, :manage_tags, :allow)

      {:ok, _member_role} = Social.assign_group_member_role(owner, group, member.id, role.key)

      assert {:ok, %{can_public?: true}} = Tags.get_taggable(member, :value, value.id)
      assert {:ok, _tag} = Tags.add_tag(member, :value, value.id, "news", :public)
    end

    test "public and private tags of the same name are different tags", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)

      {:ok, public} = Tags.add_tag(owner, :value, value.id, "topic", :public)
      {:ok, private} = Tags.add_tag(member, :value, value.id, "Topic", :private)

      refute public.id == private.id
      # Public tags first.
      assert Enum.map(Tags.tags_for(member, :value, [value.id])[value.id], & &1.id) ==
               [public.id, private.id]
    end

    test "a group takes them from its own or its parent's taggers", ctx do
      %{owner: owner, member: member, group: group} = ctx
      # The member creates a public sub-group and is its admin.
      child = group_with_members!(member, [], %{"is_public" => true, parent: group})

      assert {:ok, %{can_public?: true}} = Tags.get_taggable(member, :group, child.id)
      assert {:ok, %{can_public?: true}} = Tags.get_taggable(owner, :group, child.id)
      assert {:ok, %{can_public?: false}} = Tags.get_taggable(member, :group, group.id)
      assert {:ok, _tag} = Tags.add_tag(owner, :group, child.id, "team", :public)
    end

    test "a profile puts them on itself only", %{owner: owner, member: member} do
      assert {:ok, %{can_public?: true}} = Tags.get_taggable(member, :profile, member.id)
      assert {:ok, _tag} = Tags.add_tag(member, :profile, member.id, "designer", :public)
      assert {:error, :not_permitted} = Tags.add_tag(owner, :profile, member.id, "x", :public)
      assert names(Tags.tags_for(owner, :profile, [member.id]), member.id) == ["designer"]
    end

    test "changes are broadcast to the group, private ones are not", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)
      Social.subscribe_group(group)
      Events.subscribe(group.id)

      {:ok, _tag} = Tags.add_tag(member, :value, value.id, "mine", :private)
      refute_receive {:tags_changed, _kind, _id}

      {:ok, tag} = Tags.add_tag(owner, :value, value.id, "news", :public)
      value_id = value.id
      assert_receive {:tags_changed, :value, ^value_id}

      {:ok, _tag} = Tags.remove_tag(owner, :value, value.id, tag.id)
      assert_receive {:tags_changed, :value, ^value_id}

      event = create_event!(owner, group, event_attrs(today()))
      group_id = group.id
      # The event's creation broadcasts too.
      assert_receive {:calendar, {:events_changed, ^group_id}}
      {:ok, _tag} = Tags.add_tag(owner, :event, event.id, "match", :public)
      assert_receive {:calendar, {:events_changed, ^group_id}}
    end
  end

  describe "suggestions and the directory" do
    test "show own private tags and public tags still in use", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)
      {:ok, _} = Tags.add_tag(member, :value, value.id, "design ideas", :private)
      {:ok, public} = Tags.add_tag(owner, :value, value.id, "Webdesign", :public)
      {:ok, _} = Tags.add_tag(owner, :value, value.id, "secret", :private)

      assert Enum.map(Tags.suggest_tags(member, "des"), & &1.name) == [
               "design ideas",
               "Webdesign"
             ]

      assert Enum.map(Tags.suggest_tags(member, "%"), & &1.name) == []

      directory = Tags.list_directory(member)
      assert Enum.map(directory.mine, & &1.name) == ["design ideas"]
      assert Enum.map(directory.public, & &1.name) == ["Webdesign"]

      {:ok, _} = Tags.remove_tag(owner, :value, value.id, public.id)
      assert Enum.map(Tags.suggest_tags(member, "des"), & &1.name) == ["design ideas"]
      assert Tags.list_directory(member).public == []
    end

    test "get_visible_tags drops other profiles' private tags", ctx do
      %{owner: owner, member: member, group: group} = ctx
      value = value!(owner, group)
      {:ok, mine} = Tags.add_tag(member, :value, value.id, "mine", :private)
      {:ok, theirs} = Tags.add_tag(owner, :value, value.id, "theirs", :private)
      {:ok, public} = Tags.add_tag(owner, :value, value.id, "public", :public)

      assert Tags.get_visible_tags(member, [public.id, theirs.id, mine.id]) == [public, mine]
    end
  end

  describe "list_tagged/4" do
    test "finds items carrying every tag, newest first", ctx do
      %{owner: owner, member: member, outsider: outsider, group: group} = ctx
      first = value!(owner, group, "first")
      second = value!(owner, group, "second")
      {:ok, news} = Tags.add_tag(owner, :value, first.id, "news", :public)
      {:ok, ^news} = Tags.add_tag(owner, :value, second.id, "news", :public)
      {:ok, mine} = Tags.add_tag(member, :value, first.id, "mine", :private)

      assert {[%{id: id2}, %{id: id1}], false} = Tags.list_tagged(member, :value, [news])
      assert {id2, id1} == {second.id, first.id}

      assert {[found], false} = Tags.list_tagged(member, :value, [news, mine])
      assert found.id == first.id
      assert Enum.map(found.tags, & &1.name) == ["news", "mine"]
      assert Tags.count_tagged(member, :value, [news, mine]) == 1

      # Another profile's private tag never matches for the viewer.
      assert {[], false} = Tags.list_tagged(owner, :value, [news, mine])
      # Outsiders do not see the group's values.
      assert {[], false} = Tags.list_tagged(outsider, :value, [news])

      assert {[_newest], true} = Tags.list_tagged(member, :value, [news], limit: 1)
      assert {[older], false} = Tags.list_tagged(member, :value, [news], before_id: second.id)
      assert older.id == first.id
    end

    test "limits items to a group and its sub-groups", ctx do
      %{owner: owner, member: member, group: group} = ctx
      child = group_with_members!(owner, [member], %{parent: group})
      sibling = group_with_members!(owner, [member])
      in_child = value!(owner, child)
      in_sibling = value!(owner, sibling)
      {:ok, tag} = Tags.add_tag(member, :value, in_child.id, "x", :private)
      {:ok, ^tag} = Tags.add_tag(member, :value, in_sibling.id, "x", :private)
      {:ok, ^tag} = Tags.add_tag(member, :group, child.id, "x", :private)
      {:ok, ^tag} = Tags.add_tag(member, :profile, owner.id, "x", :private)

      assert {[found], false} = Tags.list_tagged(member, :value, [tag], group: group)
      assert found.id == in_child.id
      assert {[_, _], false} = Tags.list_tagged(member, :value, [tag])
      assert {[%{id: child_id}], false} = Tags.list_tagged(member, :group, [tag], group: group)
      assert child_id == child.id

      # Profiles are narrowed to the group's members.
      assert {[%{id: owner_id}], false} = Tags.list_tagged(member, :profile, [tag], group: group)
      assert owner_id == owner.id
      {_account, stranger} = account_with_profile!("tag-stranger")
      {:ok, ^tag} = Tags.add_tag(member, :profile, stranger.id, "x", :private)
      assert Tags.count_tagged(member, :profile, [tag], group: group) == 1
      assert Tags.count_tagged(member, :profile, [tag]) == 2
    end

    test "groups show when public or joined, files and events to members", ctx do
      %{owner: owner, member: member, outsider: outsider, group: group} = ctx
      public = group_with_members!(owner, [], %{"is_public" => true})
      attachment = attachment!(owner, group)
      event = create_event!(owner, group, event_attrs(today()))

      {:ok, tag} = Tags.add_tag(owner, :group, public.id, "open", :public)
      {:ok, ^tag} = Tags.add_tag(owner, :group, group.id, "open", :public)
      {:ok, ^tag} = Tags.add_tag(owner, :attachment, attachment.id, "open", :public)
      {:ok, ^tag} = Tags.add_tag(owner, :event, event.id, "open", :public)

      assert Tags.count_tagged(outsider, :group, [tag]) == 1
      assert Tags.count_tagged(member, :group, [tag]) == 2
      assert Tags.count_tagged(outsider, :attachment, [tag]) == 0
      assert {[found], false} = Tags.list_tagged(member, :attachment, [tag])
      assert found.id == attachment.id
      assert found.group.id == group.id
      assert Tags.count_tagged(outsider, :event, [tag]) == 0
      assert Tags.count_tagged(member, :event, [tag]) == 1

      {:ok, _cancelled} = Events.cancel_event(owner, event)
      assert Tags.count_tagged(member, :event, [tag]) == 0
    end
  end
end
