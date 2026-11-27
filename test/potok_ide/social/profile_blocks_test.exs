defmodule PotokIde.Social.ProfileBlocksTest do
  @moduledoc """
  A profile blocking another closes their direct conversation for both
  (`Access` holds nothing there), opens no new one, and lifts only by the one
  who blocked.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Accounts.Deletion
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, ProfileBlock, ProfileBlocks, ProfileDetails}

  setup do
    {ana_account, ana} = account_with_profile!("pb-ana")
    {_account, bor} = account_with_profile!("pb-bor")
    %{ana: ana, ana_account: ana_account, bor: bor}
  end

  defp say(profile, group, text),
    do: Social.create_value(profile, group, %{"content" => text, "content_format" => "markdown"})

  test "a block closes the direct conversation for both, and its writing too", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.ana, ctx.bor)
    {:ok, value} = say(ctx.bor, direct, "zdravo")

    # Asked once before the block, so the cache holds the open access.
    assert Access.can?(ctx.ana, direct, :post_values)

    assert :ok = ProfileBlocks.block(ctx.ana, ctx.bor)

    for profile <- [ctx.ana, ctx.bor] do
      access = Access.for_profile(profile, direct)
      assert access.member?
      assert access.closed?
      refute Access.can_post_in_chat?(profile, access, direct)
      refute Access.can_react_in_chat?(profile, access, direct)
      assert Access.can_read_chat?(access, direct)
      assert {:error, :not_permitted} = say(profile, direct, "još nešto")
    end

    assert {:error, :not_permitted} = Social.update_value(ctx.bor, value, %{"content" => "x"})

    # The conversation itself still opens, to read it.
    assert {:ok, %{id: id}} = Social.get_or_create_direct_group(ctx.bor, ctx.ana)
    assert id == direct.id
    assert ProfileBlocks.direct_group_closed?(direct.id)
  end

  test "the access of several groups at once sees the closed conversation", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.ana, ctx.bor)
    :ok = ProfileBlocks.block(ctx.bor, ctx.ana)

    access = ctx.ana |> Access.for_profile_in_groups([direct]) |> Map.fetch!(direct.id)

    assert access.closed?
    assert MapSet.size(access.permissions) == 0
  end

  test "no new direct conversation opens while either has blocked the other", ctx do
    :ok = ProfileBlocks.block(ctx.bor, ctx.ana)

    assert {:error, :blocked} = Social.get_or_create_direct_group(ctx.ana, ctx.bor)
    assert {:error, :blocked} = Social.get_or_create_direct_group(ctx.bor, ctx.ana)
  end

  test "only the one who blocked lifts the block", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.ana, ctx.bor)
    :ok = ProfileBlocks.block(ctx.ana, ctx.bor)

    # The other one has nothing to lift.
    :ok = ProfileBlocks.unblock(ctx.bor, ctx.ana.id)
    assert Access.for_profile(ctx.bor, direct).closed?

    :ok = ProfileBlocks.unblock(ctx.ana, ctx.bor.id)
    refute Access.for_profile(ctx.bor, direct).closed?
    assert {:ok, _value} = say(ctx.bor, direct, "opet")
  end

  test "a block made by each stays until both lift theirs", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.ana, ctx.bor)
    :ok = ProfileBlocks.block(ctx.ana, ctx.bor)
    :ok = ProfileBlocks.block(ctx.bor, ctx.ana)

    :ok = ProfileBlocks.unblock(ctx.ana, ctx.bor.id)
    assert Access.for_profile(ctx.ana, direct).closed?

    :ok = ProfileBlocks.unblock(ctx.bor, ctx.ana.id)
    refute Access.for_profile(ctx.ana, direct).closed?
  end

  test "blocking twice changes nothing, blocking oneself or a process is refused", ctx do
    assert :ok = ProfileBlocks.block(ctx.ana, ctx.bor)
    assert :ok = ProfileBlocks.block(ctx.ana, ctx.bor)
    assert Repo.aggregate(ProfileBlock, :count) == 1

    assert {:error, :same_profile} = ProfileBlocks.block(ctx.ana, ctx.ana)
    assert {:error, :not_a_person} = ProfileBlocks.block(ctx.ana, %{ctx.bor | kind: :process})
  end

  test "a block touches no other group the two share", ctx do
    group = group_with_members!(ctx.ana, [ctx.bor])
    :ok = ProfileBlocks.block(ctx.ana, ctx.bor)

    refute Access.for_profile(ctx.bor, group).closed?
    assert {:ok, _value} = say(ctx.bor, group, "u grupi")
  end

  test "the card offers the block, and to write only while the conversation exists", ctx do
    card = ProfileDetails.card(ctx.ana_account, ctx.ana, ctx.bor)
    assert card.can_block?
    refute card.blocked?
    assert card.can_message?

    :ok = ProfileBlocks.block(ctx.ana, ctx.bor)
    card = ProfileDetails.card(ctx.ana_account, ctx.ana, ctx.bor)
    assert card.blocked?
    refute card.can_message?

    # Its own profile is never blocked from its card.
    refute ProfileDetails.card(ctx.ana_account, ctx.ana, ctx.ana).can_block?
  end

  test "a deleted account takes its blocks along, both ways", ctx do
    {carl_account, carl} = account_with_profile!("pb-carl")
    :ok = ProfileBlocks.block(ctx.ana, carl)
    :ok = ProfileBlocks.block(carl, ctx.bor)

    {:ok, _deleted} = Deletion.delete(carl_account)

    assert Repo.aggregate(ProfileBlock, :count) == 0
  end
end
