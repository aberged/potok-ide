defmodule PotokIde.Social.ProfileFactsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures, only: [share_profile!: 2]

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, ProfileDetails, ProfileFacts}

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  setup do
    {account, ana} = account_with_profile!(unique("ana"))
    {_account, marko} = account_with_profile!(unique("marko"))
    %{account: account, ana: ana, marko: marko}
  end

  test "strangers share nothing, though both are in the root", %{ana: ana, marko: marko} do
    facts = ProfileFacts.load(nil, ana, marko)

    refute facts.holder?
    assert MapSet.size(facts.shared_group_ids) == 0
    refute facts.direct?
  end

  test "a group both are in is shared, and so is one inherited", %{ana: ana, marko: marko} do
    group = group_with_members!(ana, [marko])
    sub = group_with_members!(ana, [], %{"inherits_members" => true, parent: group})

    facts = ProfileFacts.load(nil, ana, marko)

    assert MapSet.member?(facts.shared_group_ids, group.id)
    assert MapSet.member?(facts.shared_group_ids, sub.id)
  end

  test "a direct conversation, a thread or a record is no shared group", %{ana: ana, marko: marko} do
    {:ok, direct} = Social.get_or_create_direct_group(ana, marko)

    group = group_with_members!(ana, [marko])

    {:ok, value} =
      Social.create_value(ana, group, %{"content" => "zdravo", "content_format" => "markdown"})

    {:ok, thread} = Social.get_or_create_value_thread(marko, group, value, %{"name" => "nit"})

    record = group_with_members!(ana, [marko], %{parent: group})
    Repo.update_all(from(g in Group, where: g.id == ^record.id), set: [external_key: "zapis-1"])

    facts = ProfileFacts.load(nil, ana, marko)

    assert facts.direct?
    assert MapSet.equal?(facts.shared_group_ids, MapSet.new([group.id]))
    refute MapSet.member?(facts.shared_group_ids, direct.id)
    refute MapSet.member?(facts.shared_group_ids, thread.id)
    assert ProfileDetails.allowed_group_ids(marko) == [group.id]
  end

  test "every account of a shared profile holds it", %{account: account, ana: ana} do
    {other_account, _other} = account_with_profile!(unique("vesna"))
    {:ok, shared} = Social.update_profile_for_account(account, ana.id, %{sharing: :shared})
    share_profile!(shared, other_account)

    assert ProfileFacts.load(Accounts.get_account!(other_account.id), nil, shared).holder?
    assert ProfileFacts.load(account, shared, shared).holder?
  end

  test "a guest knows only the kind", %{marko: marko} do
    assert %ProfileFacts{kind: :person, holder?: false} = ProfileFacts.load(nil, nil, marko)
  end
end
