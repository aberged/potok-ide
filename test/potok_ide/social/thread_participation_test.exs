defmodule PotokIde.Social.ThreadParticipationTest do
  @moduledoc """
  Who takes part in a thread, and so counts it and gets its pushes: whoever
  opened it, the author of the value it was opened on, and a member of its
  group who opens it, writes in it or is mentioned in it, by name or through
  a role.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {_account, owner} = account_with_profile!("tp-owner")
    {_account, ana} = account_with_profile!("tp-ana")
    {_account, bob} = account_with_profile!("tp-bob")
    group = group_with_members!(owner, [ana, bob])
    {:ok, start} = Social.create_value(owner, group, %{"content" => "start"})
    {:ok, thread} = Social.get_or_create_value_thread(owner, group, start, %{"name" => "nit"})
    %{owner: owner, ana: ana, bob: bob, group: group, thread: thread}
  end

  defp unread_in(profile, thread) do
    case Social.unread_overview(profile).groups[thread.id] do
      nil -> 0
      entry -> entry.own
    end
  end

  test "a member of the group is not in a thread before taking part", ctx do
    refute Social.member_of_group?(ctx.ana, ctx.thread)

    {:ok, _value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "hello"})
    assert unread_in(ctx.ana, ctx.thread) == 0
  end

  test "a mention takes the member in, and the message counts as unread for them", ctx do
    {:ok, _value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "before"})
    {:ok, value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "@tp-ana look"})

    assert value.mentioned_profile_ids == [ctx.ana.id]
    assert Social.member_of_group?(ctx.ana, ctx.thread)
    assert unread_in(ctx.ana, ctx.thread) == 1
    refute Social.member_of_group?(ctx.bob, ctx.thread)

    {:ok, _value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "after"})
    assert unread_in(ctx.ana, ctx.thread) == 2
  end

  test "a role mentioned takes its holders in", ctx do
    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "savet"})
    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.bob.id, role.key)

    {:ok, _value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "@savet please"})

    assert Social.member_of_group?(ctx.bob, ctx.thread)
    refute Social.member_of_group?(ctx.ana, ctx.thread)
    assert unread_in(ctx.bob, ctx.thread) == 1
  end

  test "a mention of someone outside the group takes nobody in", ctx do
    {_account, outsider} = account_with_profile!("tp-out")

    {:ok, value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "@tp-out hi"})

    assert value.mentioned_profile_ids == []
    refute Social.member_of_group?(outsider, ctx.thread)
  end

  test "an edit that adds a mention takes the member in", ctx do
    {:ok, value} = Social.create_value(ctx.owner, ctx.thread, %{"content" => "plain"})
    {:ok, _edited} = Social.update_value(ctx.owner, value, %{"content" => "plain @tp-bob"})

    assert Social.member_of_group?(ctx.bob, ctx.thread)
  end

  test "mention suggestions in a thread offer the members of its group", ctx do
    names =
      ctx.owner
      |> Social.list_mention_candidates(ctx.thread, "tp-")
      |> Enum.map(& &1.name)

    assert "tp-ana" in names
    assert "tp-bob" in names
  end
end
