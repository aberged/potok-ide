defmodule PotokIde.Social.OpenChatTest do
  @moduledoc """
  A public group whose admin opened its chat: who reads and writes there, the
  limits on those outside the group, whom it pushes to, and blocks.
  """

  # Push requests are captured through the global push configuration.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupBlock, Value, ValueAttachment}
  alias PotokIde.Storage

  setup do
    {owner_account, owner} = account_with_profile!("open-owner")
    {member_account, member} = account_with_profile!("open-member")
    {visitor_account, visitor} = account_with_profile!("open-visitor")

    group = group!(owner, "open-group", %{"is_public" => true, "has_public_chat" => true})
    add_member!(owner, group, member)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      visitor: visitor,
      group: group
    }
  end

  defp group!(owner, name, attrs, parent \\ nil) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent || Social.get_root_group!(),
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp access(profile, group), do: Access.for_profile(profile, group)
  defp reads?(profile, group), do: Access.can_read_chat?(access(profile, group), group)

  defp posts?(profile, group),
    do: Access.can_post_in_chat?(profile, access(profile, group), group)

  defp reacts?(profile, group),
    do: Access.can_react_in_chat?(profile, access(profile, group), group)

  defp without_everyone!(owner, group, permission) do
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    {:ok, _role} =
      Social.set_group_role_permission(owner, group, "everyone", permission, :neutral)
  end

  defp seconds_ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds, :second)

  # As it stood `seconds` ago; `updated_seconds` when it was edited since.
  defp age_value!(%Value{id: id}, seconds, updated_seconds \\ nil) do
    from(v in Value, where: v.id == ^id)
    |> Repo.update_all(
      set: [
        inserted_at: seconds_ago(seconds),
        updated_at: seconds_ago(updated_seconds || seconds)
      ]
    )
  end

  defp stored_file!(group, name) do
    key = Storage.new_key(group.id)
    path = Path.join(System.tmp_dir!(), "potok-upload-#{System.unique_integer([:positive])}")
    File.write!(path, "hello")
    :ok = Storage.put_file(key, path)
    File.rm!(path)

    %{storage_key: key, filename: name, content_type: "text/plain", byte_size: 5}
  end

  describe "a group's chat" do
    test "opens with public and the switch together, and only so", ctx do
      assert Group.open_chat?(ctx.group)
      refute Group.open_chat?(%{ctx.group | is_public: false})
      refute Group.open_chat?(%{ctx.group | has_public_chat: false})
    end

    test "never opens on the root, a direct conversation or a thread", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      # A direct conversation has always held the field, and is never public.
      assert direct.has_public_chat
      refute Group.open_chat?(direct)
      refute Group.open_chat?(%{direct | is_public: true})
      refute Group.open_chat?(%{Social.get_root_group!() | has_public_chat: true})
      refute Group.open_chat?(%{thread | has_public_chat: true})
    end

    test "stays chosen while the group is private", ctx do
      {:ok, private} = Social.update_group(ctx.owner, ctx.group, %{"is_public" => false})
      assert private.has_public_chat
      refute reads?(ctx.visitor, private)

      {:ok, public} = Social.update_group(ctx.owner, private, %{"is_public" => true})
      assert reads?(ctx.visitor, public)
    end
  end

  describe "those outside the group" do
    test "read, write and react in an open chat", ctx do
      assert reads?(ctx.visitor, ctx.group)
      assert posts?(ctx.visitor, ctx.group)
      assert reacts?(ctx.visitor, ctx.group)
    end

    test "do nothing in a chat that is not open", ctx do
      closed = group!(ctx.owner, "open-closed", %{"is_public" => true})
      private = group!(ctx.owner, "open-private", %{"has_public_chat" => true})

      for group <- [closed, private] do
        refute reads?(ctx.visitor, group)
        refute posts?(ctx.visitor, group)
        refute reacts?(ctx.visitor, group)
      end
    end

    test "do nothing without a profile", ctx do
      refute posts?(nil, ctx.group)
      refute reacts?(nil, ctx.group)
    end

    test "only read where \"everyone\" may not write", ctx do
      {:ok, %{group: group}} =
        Social.create_group_from_preset(
          ctx.owner,
          Social.get_root_group!(),
          "chat",
          %{"name" => "open-news", "is_public" => true}
        )

      without_everyone!(ctx.owner, group, :post_values)
      {:ok, group} = Social.update_group(ctx.owner, group, %{"has_public_chat" => true})

      assert reads?(ctx.visitor, group)
      refute posts?(ctx.visitor, group)
      refute posts?(ctx.member, group)
      assert posts?(ctx.owner, group)
    end

    test "react only while \"everyone\" may", ctx do
      without_everyone!(ctx.owner, ctx.group, :react)

      assert posts?(ctx.visitor, ctx.group)
      refute reacts?(ctx.visitor, ctx.group)
    end
  end

  describe "members" do
    test "answer to their roles, with a role that denies posting binding them", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, muted} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "muted"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, muted.key, :post_values, :deny)

      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, muted.key)

      refute posts?(ctx.member, ctx.group)

      assert {:error, :not_permitted} =
               Social.create_value(ctx.member, ctx.group, %{"content" => "no"})
    end

    test "keep html and a long text", ctx do
      long = String.duplicate("a", 5_000)

      assert {:ok, %Value{content_format: :html}} =
               Social.create_value(ctx.member, ctx.group, %{
                 "content" => long,
                 "content_format" => "html"
               })
    end
  end

  describe "create_value/4 from outside the group" do
    test "posts without making the author a member", ctx do
      assert {:ok, %Value{} = value} =
               Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})

      assert value.creator_id == ctx.visitor.id
      refute Social.member_of_group?(ctx.visitor, ctx.group)
    end

    test "answers a member's value", ctx do
      {:ok, parent} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})

      assert {:ok, %Value{parent_id: parent_id}} =
               Social.create_value(ctx.visitor, ctx.group, %{
                 "content" => "hello",
                 "parent_id" => parent.id
               })

      assert parent_id == parent.id
    end

    test "is refused in a closed chat", ctx do
      closed = group!(ctx.owner, "open-closed", %{"is_public" => true})

      assert {:error, :not_a_member_of_group} =
               Social.create_value(ctx.visitor, closed, %{"content" => "hello"})
    end

    test "is always markdown, which keeps html off the page of an app group", ctx do
      assert {:ok, %Value{content_format: :markdown}} =
               Social.create_value(ctx.visitor, ctx.group, %{
                 "content" => "<div class=\"modal\">fake</div>",
                 "content_format" => "html"
               })
    end

    test "has a limit on its length", ctx do
      assert {:ok, %Value{}} =
               Social.create_value(ctx.visitor, ctx.group, %{
                 "content" => String.duplicate("a", 4_000)
               })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_value(ctx.visitor, ctx.group, %{
                 "content" => String.duplicate("a", 4_001)
               })

      assert %{content: [_too_long]} = errors_on(changeset)
    end

    test "carries no files", ctx do
      file = stored_file!(ctx.group, "a.txt")

      assert {:error, :not_permitted} =
               Social.create_value(ctx.visitor, ctx.group, %{"content" => "hi"}, [file])
    end

    test "stops at ten values a minute, per group", ctx do
      other = group!(ctx.owner, "open-other", %{"is_public" => true, "has_public_chat" => true})

      for n <- 1..10 do
        assert {:ok, _value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "#{n}"})
      end

      assert {:error, :too_many_values} =
               Social.create_value(ctx.visitor, ctx.group, %{"content" => "one more"})

      assert {:ok, _value} = Social.create_value(ctx.visitor, other, %{"content" => "elsewhere"})
    end

    test "goes on after the minute", ctx do
      for n <- 1..10 do
        {:ok, value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "#{n}"})
        age_value!(value, 61)
      end

      assert {:ok, _value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "more"})
    end

    test "does not hold members back", ctx do
      for n <- 1..11 do
        assert {:ok, _value} = Social.create_value(ctx.member, ctx.group, %{"content" => "#{n}"})
      end
    end
  end

  describe "update_value/3 from outside the group" do
    setup ctx do
      {:ok, value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "first"})
      %{value: value}
    end

    test "corrects a value that was just posted", ctx do
      assert {:ok, %Value{content: "second"}} =
               Social.update_value(ctx.visitor, ctx.value, %{"content" => "second"})
    end

    test "waits a moment after an edit", ctx do
      age_value!(ctx.value, 60, 2)

      assert {:error, :too_many_values} =
               Social.update_value(ctx.visitor, ctx.value, %{"content" => "again"})

      age_value!(ctx.value, 60, 30)

      assert {:ok, _value} = Social.update_value(ctx.visitor, ctx.value, %{"content" => "again"})
    end

    test "stops when the chat closes", ctx do
      {:ok, closed} = Social.update_group(ctx.owner, ctx.group, %{"has_public_chat" => false})

      assert closed.id == ctx.value.group_id

      assert {:error, :not_permitted} =
               Social.update_value(ctx.visitor, ctx.value, %{"content" => "late"})
    end

    test "stops with a block", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert {:error, :not_permitted} =
               Social.update_value(ctx.visitor, ctx.value, %{"content" => "late"})
    end

    test "holds to the same limits as a new value", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Social.update_value(ctx.visitor, ctx.value, %{
                 "content" => String.duplicate("a", 4_001)
               })

      assert {:ok, %Value{content_format: :markdown}} =
               Social.update_value(ctx.visitor, ctx.value, %{
                 "content" => "<b>x</b>",
                 "content_format" => "html"
               })
    end

    test "turns html from the time of a membership into markdown", ctx do
      {:ok, value} =
        Social.create_value(ctx.member, ctx.group, %{
          "content" => "<b>x</b>",
          "content_format" => "html"
        })

      {:ok, _member} = Social.remove_group_member(ctx.owner, ctx.group, ctx.member)

      assert {:ok, %Value{content_format: :markdown}} =
               Social.update_value(ctx.member, value, %{"content" => "<b>y</b>"})
    end

    test "leaves a member's edits alone", ctx do
      {:ok, value} = Social.create_value(ctx.member, ctx.group, %{"content" => "first"})

      for n <- 1..3 do
        assert {:ok, _value} = Social.update_value(ctx.member, value, %{"content" => "#{n}"})
      end
    end
  end

  describe "reactions to a value" do
    setup ctx do
      {:ok, value} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})
      %{value: value}
    end

    test "come from outside the group, and tell nobody", ctx do
      capture_push_requests!()
      push_device!(ctx.member_account)

      assert {:ok, %Value{reactions: [reaction]}} =
               Social.toggle_value_reaction(ctx.visitor, ctx.group, ctx.value, "👍")

      assert reaction.profile_id == ctx.visitor.id
      assert pushed_endpoints() == []
    end

    test "still tell the author when a member reacts", ctx do
      capture_push_requests!()
      member_device = push_device!(ctx.member_account)

      assert {:ok, _value} = Social.toggle_value_reaction(ctx.owner, ctx.group, ctx.value, "👍")
      assert pushed_endpoints() == [member_device]
    end

    test "are refused in a closed chat", ctx do
      closed = group!(ctx.owner, "open-closed", %{"is_public" => true})
      {:ok, value} = Social.create_value(ctx.owner, closed, %{"content" => "hi"})

      assert {:error, :not_a_member_of_group} =
               Social.toggle_value_reaction(ctx.visitor, closed, value, "👍")
    end

    test "are refused with a block", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert {:error, :not_permitted} =
               Social.toggle_value_reaction(ctx.visitor, ctx.group, ctx.value, "👍")
    end
  end

  describe "mention suggestions" do
    test "reach someone who may write, without its roles", ctx do
      assert [%{kind: :profile, id: member_id}] =
               Social.list_mention_candidates(ctx.visitor, ctx.group, "open-mem")

      assert member_id == ctx.member.id
      assert Social.list_mention_candidates(ctx.visitor, ctx.group, "every") == []
    end

    test "are empty in a closed chat", ctx do
      closed = group!(ctx.owner, "open-closed", %{"is_public" => true})
      add_member!(ctx.owner, closed, ctx.member)

      assert Social.list_mention_candidates(ctx.visitor, closed, "open-mem") == []
    end
  end

  describe "get_attachment_for_download/2" do
    test "opens a file of an open chat to anyone signed in", ctx do
      {:ok, %Value{attachments: [attachment]}} =
        Social.create_value(ctx.owner, ctx.group, %{}, [stored_file!(ctx.group, "a.txt")])

      assert %ValueAttachment{} = Social.get_attachment_for_download(ctx.visitor, attachment.id)
    end

    test "keeps a file of a closed chat to the members", ctx do
      closed = group!(ctx.owner, "open-closed", %{"is_public" => true})

      {:ok, %Value{attachments: [attachment]}} =
        Social.create_value(ctx.owner, closed, %{}, [stored_file!(closed, "a.txt")])

      assert %ValueAttachment{} = Social.get_attachment_for_download(ctx.owner, attachment.id)
      assert Social.get_attachment_for_download(ctx.visitor, attachment.id) == nil
    end

    test "keeps a file of a thread to the members", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      {:ok, %Value{attachments: [attachment]}} =
        Social.create_value(ctx.owner, thread, %{}, [stored_file!(thread, "a.txt")])

      assert Social.get_attachment_for_download(ctx.visitor, attachment.id) == nil
    end

    test "finds nothing under an unknown id", ctx do
      assert Social.get_attachment_for_download(ctx.owner, -1) == nil
    end
  end

  describe "pushes" do
    setup ctx do
      capture_push_requests!()

      %{
        owner_device: push_device!(ctx.owner_account),
        member_device: push_device!(ctx.member_account),
        visitor_device: push_device!(ctx.visitor_account)
      }
    end

    test "a value from outside goes to no member by itself", ctx do
      {:ok, _value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})

      assert pushed_endpoints() == []
    end

    test "a value from outside still counts as unread", ctx do
      {:ok, _value} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})

      assert Social.unread_counts_for(Social.unread_overview(ctx.member), [ctx.group.id]) == %{
               ctx.group.id => 1
             }
    end

    test "a mention from outside goes to the one mentioned", ctx do
      {:ok, _value} =
        Social.create_value(ctx.visitor, ctx.group, %{"content" => "hi @open-member"})

      assert pushed_endpoints() == [ctx.member_device]
    end

    test "mentions from outside push to five at most", ctx do
      names =
        for n <- 1..6 do
          {account, profile} = account_with_profile!("open-many-#{n}")
          add_member!(ctx.owner, ctx.group, profile)
          push_device!(account)
          "@#{profile.username}"
        end

      _before = pushed_endpoints()

      {:ok, value} =
        Social.create_value(ctx.visitor, ctx.group, %{"content" => Enum.join(names, " ")})

      assert length(value.mentioned_profile_ids) == 6
      assert length(pushed_endpoints()) == 5
    end

    test "a reply from outside goes to the author it answers", ctx do
      {:ok, parent} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})
      _before = pushed_endpoints()

      {:ok, _value} =
        Social.create_value(ctx.visitor, ctx.group, %{
          "content" => "hello",
          "parent_id" => parent.id
        })

      assert pushed_endpoints() == [ctx.member_device]
    end

    test "a mention and a reply to one person push once", ctx do
      {:ok, parent} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})
      _before = pushed_endpoints()

      {:ok, _value} =
        Social.create_value(ctx.visitor, ctx.group, %{
          "content" => "hello @open-member",
          "parent_id" => parent.id
        })

      assert pushed_endpoints() == [ctx.member_device]
    end

    test "a member's reply reaches an author outside the group, with the members", ctx do
      {:ok, parent} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})

      {:ok, _value} =
        Social.create_value(ctx.member, ctx.group, %{
          "content" => "hi there",
          "parent_id" => parent.id
        })

      assert pushed_endpoints() == Enum.sort([ctx.owner_device, ctx.visitor_device])
    end

    test "replying to yourself from outside pushes nobody", ctx do
      {:ok, parent} = Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})

      {:ok, _value} =
        Social.create_value(ctx.visitor, ctx.group, %{
          "content" => "and more",
          "parent_id" => parent.id
        })

      assert pushed_endpoints() == []
    end

    test "a member's value goes to the members as before", ctx do
      {:ok, _value} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})

      assert pushed_endpoints() == [ctx.owner_device]
    end

    test "a member's reply to a member goes to the members as before", ctx do
      {:ok, parent} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})
      _before = pushed_endpoints()

      {:ok, _value} =
        Social.create_value(ctx.owner, ctx.group, %{
          "content" => "hi there",
          "parent_id" => parent.id
        })

      assert pushed_endpoints() == [ctx.member_device]
    end
  end

  describe "block_from_group/3" do
    test "stops someone outside the group from writing and reacting, not from reading", ctx do
      assert {:ok, %GroupBlock{} = block} =
               Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert block.blocked_by_id == ctx.owner.id
      assert access(ctx.visitor, ctx.group).blocked?
      assert reads?(ctx.visitor, ctx.group)
      refute posts?(ctx.visitor, ctx.group)
      refute reacts?(ctx.visitor, ctx.group)

      assert {:error, :not_permitted} =
               Social.create_value(ctx.visitor, ctx.group, %{"content" => "hello"})
    end

    test "stops reactions to the group too", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      refute Access.can_react_to_group?(ctx.visitor, access(ctx.visitor, ctx.group), ctx.group)
      assert {:error, :not_permitted} = Social.toggle_group_reaction(ctx.visitor, ctx.group, "👍")
    end

    test "says so in a batch of groups", ctx do
      other = group!(ctx.owner, "open-other", %{"is_public" => true})
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      accesses = Access.for_profile_in_groups(ctx.visitor, [ctx.group, other])

      assert accesses[ctx.group.id].blocked?
      refute accesses[other.id].blocked?
    end

    test "removes a member and keeps their values", ctx do
      {:ok, value} = Social.create_value(ctx.member, ctx.group, %{"content" => "hi"})

      assert {:ok, %GroupBlock{}} = Social.block_from_group(ctx.owner, ctx.group, ctx.member)

      refute Social.member_of_group?(ctx.member, ctx.group)
      assert Repo.get(Value, value.id)
      refute posts?(ctx.member, ctx.group)
    end

    test "cannot reach a member held through the parent", ctx do
      child =
        group!(
          ctx.owner,
          "open-child",
          %{"is_public" => true, "has_public_chat" => true, "inherits_members" => true},
          ctx.group
        )

      assert {:error, :inherited_member} = Social.block_from_group(ctx.owner, child, ctx.member)
      refute Repo.get_by(GroupBlock, group_id: child.id, profile_id: ctx.member.id)
    end

    test "takes the right to remove members", ctx do
      assert {:error, :not_permitted} =
               Social.block_from_group(ctx.member, ctx.group, ctx.visitor)

      refute Repo.get_by(GroupBlock, group_id: ctx.group.id, profile_id: ctx.visitor.id)
    end

    test "is for others", ctx do
      assert {:error, :cannot_block_self} =
               Social.block_from_group(ctx.owner, ctx.group, ctx.owner)
    end

    test "has no use in a direct conversation", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

      assert {:error, :not_permitted} = Social.block_from_group(ctx.owner, direct, ctx.visitor)
    end

    test "changes nothing the second time", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert {:ok, %GroupBlock{}} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)
      assert [%GroupBlock{}] = Social.list_group_blocks(ctx.group)
    end

    test "takes back a request to join and an invitation", ctx do
      {_account, invited} = account_with_profile!("open-invited")

      {:ok, _request} = Social.request_group_access(ctx.visitor, ctx.group)
      {:ok, _invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, invited)

      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, invited)

      assert Social.get_pending_group_join_request(ctx.visitor, ctx.group) == nil
      assert Social.list_pending_invitations(invited) == []
    end

    test "refuses a request to join and an invitation", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert {:error, :blocked} = Social.request_group_access(ctx.visitor, ctx.group)

      assert {:error, :blocked} =
               Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.visitor)
    end

    test "gives way to a membership", ctx do
      Repo.insert!(%GroupBlock{group_id: ctx.group.id, profile_id: ctx.member.id})

      refute access(ctx.member, ctx.group).blocked?
      assert posts?(ctx.member, ctx.group)
    end
  end

  describe "unblock_from_group/3" do
    setup ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)
      :ok
    end

    test "gives writing back", ctx do
      assert :ok = Social.unblock_from_group(ctx.owner, ctx.group, ctx.visitor.id)

      assert posts?(ctx.visitor, ctx.group)
      assert Social.list_group_blocks(ctx.group) == []
    end

    test "takes the right to remove members", ctx do
      assert {:error, :not_permitted} =
               Social.unblock_from_group(ctx.member, ctx.group, ctx.visitor.id)

      assert [%GroupBlock{}] = Social.list_group_blocks(ctx.group)
    end
  end

  describe "list_group_blocks/1" do
    test "gives the profiles to show", ctx do
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, ctx.visitor)

      assert [%GroupBlock{profile: profile}] = Social.list_group_blocks(ctx.group)
      assert profile.id == ctx.visitor.id
    end
  end
end
