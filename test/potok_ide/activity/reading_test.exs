defmodule PotokIde.Activity.ReadingTest do
  @moduledoc """
  Who reads what of a profile's timeline: the profile alone, and of what it
  did only what is in groups it reads now.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.ActivityFixtures
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{Repo, Social}
  alias PotokIde.Social.{Access, Group}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {me_account, me} = account_with_profile!("ak#{unique()}")
    {owner_account, owner} = account_with_profile!("ak#{unique()}")
    {other_account, other} = account_with_profile!("ak#{unique()}")

    %{
      me: me,
      me_account: me_account,
      owner: owner,
      owner_account: owner_account,
      other: other,
      other_account: other_account
    }
  end

  defp group!(ctx, members, attrs \\ %{}), do: group_with_members!(ctx.owner, members, attrs)
  defp update!(group, changes), do: group |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp sees?(ctx, key, filter \\ :all),
    do: key in keys(ctx.me, ctx.me_account, filter: filter, limit: 200)

  defp thread!(ctx, group, opener \\ nil) do
    root = message!(ctx.owner, group, at(0))

    {:ok, thread} =
      Social.get_or_create_value_thread(opener || ctx.owner, group, root, %{"name" => "nit"})

    thread
  end

  describe "chats" do
    test "as the chat itself is read, in every kind of group", ctx do
      private = group!(ctx, [])
      mine = group!(ctx, [ctx.me])
      closed = group!(ctx, [], %{"is_public" => true, "has_public_chat" => false})
      open = group!(ctx, [], %{"is_public" => true, "has_public_chat" => true})
      blocked = group!(ctx, [], %{"is_public" => true, "has_public_chat" => true})
      {:ok, _} = Social.block_from_group(ctx.owner, blocked, ctx.me)
      {:ok, direct} = Social.get_or_create_direct_group(ctx.me, ctx.other)
      {:ok, foreign} = Social.get_or_create_direct_group(ctx.owner, ctx.other)
      in_mine = thread!(ctx, mine)
      deeper = thread!(ctx, in_mine)
      in_open = thread!(ctx, open)
      in_private = thread!(ctx, private)

      root = Social.get_root_group!()

      groups = [
        root,
        private,
        mine,
        closed,
        open,
        blocked,
        direct,
        foreign,
        in_mine,
        deeper,
        in_open,
        in_private
      ]

      written =
        for {group, n} <- Enum.with_index(groups) do
          own = message!(ctx.me, group, at(10 + n))
          reaction!(ctx.owner, own, at(100 + n))
          theirs = message!(ctx.owner, group, at(50 + n))
          reaction!(ctx.me, theirs, at(150 + n))
          file!(own)
          {group, own, theirs}
        end

      seen = keys(ctx.me, ctx.me_account, limit: 200)
      files = keys(ctx.me, ctx.me_account, filter: :files, limit: 200)

      for {group, own, theirs} <- written do
        # Whoever may open a thread is taken in when they do.
        :ok = Social.join_thread(ctx.me, group)
        group = Repo.get!(Group, group.id)
        reads? = Access.can_read_chat?(Access.for_profile(ctx.me, group), group)

        assert "message-#{own.id}" in seen == reads?, "message in #{inspect(group)}"
        assert "message-#{own.id}" in files == reads?
        assert "received-#{own.id}" in seen == reads?
        assert "given-#{theirs.id}" in seen == reads?
      end

      readable = [root, mine, open, blocked, direct, in_mine, deeper]
      assert Enum.count(seen, &String.starts_with?(&1, "message-")) == length(readable)
    end

    test "what is in a group one left is gone, and there again on coming back", ctx do
      group = group!(ctx, [ctx.me])
      thread = thread!(ctx, group)
      message = message!(ctx.me, group, at(1))
      in_thread = message!(ctx.me, thread, at(2))
      :ok = Social.join_thread(ctx.me, thread)

      assert sees?(ctx, "message-#{message.id}")
      assert sees?(ctx, "message-#{in_thread.id}")

      {:ok, _} = Social.leave_group(ctx.me, group)
      refute sees?(ctx, "message-#{message.id}")
      refute sees?(ctx, "message-#{in_thread.id}")

      # The place in the thread went with the one in the group, and comes
      # back only when the thread is opened.
      add_member!(ctx.owner, group, ctx.me)
      refute Access.for_profile(ctx.me, thread).member?
      assert sees?(ctx, "message-#{message.id}")
      assert sees?(ctx, "message-#{in_thread.id}")
    end

    test "a group that closes takes what outsiders wrote in it along", ctx do
      group = group!(ctx, [], %{"is_public" => true, "has_public_chat" => true})
      message = message!(ctx.me, group, at(1))
      assert sees?(ctx, "message-#{message.id}")

      update!(group, is_public: false)
      refute sees?(ctx, "message-#{message.id}")
    end

    test "the announcement of an event that is not public stays with the members", ctx do
      group = group!(ctx, [ctx.me], %{"is_public" => true, "has_public_chat" => true})

      create_event!(ctx.owner, group, event_attrs(Date.add(today(), 7)), announce: true)
      [announcement] = Social.list_group_values(group)
      reaction!(ctx.me, announcement, at(5))

      assert [entry] = entries(ctx.me, ctx.me_account, filter: :given)
      assert entry.value.announces == :event

      {:ok, _} = Social.leave_group(ctx.me, group)
      assert entries(ctx.me, ctx.me_account, filter: :given) == []
    end

    test "nobody else's, and all of a shared profile's for each of its holders", ctx do
      group = group!(ctx, [ctx.me, ctx.other])
      message = message!(ctx.me, group, at(1))
      reaction!(ctx.other, message, at(2))

      assert keys(ctx.me, ctx.me_account, filter: :messages) == ["message-#{message.id}"]
      assert keys(ctx.other, ctx.other_account, filter: :messages) == []
      assert keys(ctx.other, ctx.other_account, filter: :received) == []
      assert keys(ctx.other, ctx.other_account, filter: :given) == ["given-#{message.id}"]

      share_profile!(ctx.me, ctx.other_account)

      assert keys(ctx.me, ctx.other_account, filter: :all) ==
               keys(ctx.me, ctx.me_account, filter: :all)
    end

    test "a deleted message leaves nothing", ctx do
      group = group!(ctx, [ctx.me])
      message = message!(ctx.me, group, at(1))
      reaction!(ctx.owner, message, at(2))
      reaction!(ctx.me, message, at(3))
      assert length(entries(ctx.me, ctx.me_account, filter: :received)) == 1

      {:ok, _} = Social.delete_value(ctx.me, message)

      for filter <- [:messages, :received, :given] do
        assert entries(ctx.me, ctx.me_account, filter: filter) == []
      end
    end

    test "the parent of a thread is named only to whoever sees it", ctx do
      group = group!(ctx, [ctx.me])
      thread = thread!(ctx, group, ctx.me)
      message!(ctx.me, thread, at(1))

      assert [%{parent: %Group{id: id}}] = entries(ctx.me, ctx.me_account, filter: :messages)
      assert id == group.id

      # Who opened the thread is in it by themselves, and stays.
      {:ok, _} = Social.leave_group(ctx.me, group)
      assert [%{parent: nil}] = entries(ctx.me, ctx.me_account, filter: :messages)
    end
  end
end
