defmodule PotokIde.Social.AppProfileStoreTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppProfileEntry, AppProfileStore, Group, GroupAltDescription}

  setup do
    {account, reader} = account_with_profile!("reader")
    {_other_account, other} = account_with_profile!("other")
    group = group_with_members!(reader, [other])
    %{account: account, reader: reader, other: other, group: group}
  end

  defp alt!(group, name) do
    Repo.insert!(%GroupAltDescription{
      group_id: group.id,
      name: name,
      description: "",
      description_format: :html,
      uses_api: true
    })
  end

  test "keeps a value for the profile alone, per app", %{
    reader: reader,
    other: other,
    group: group
  } do
    alt = alt!(group, "Priručnik")

    assert {:ok, :ok} = AppProfileStore.put(reader, group, nil, "page", "/poglavlja/03.html")
    assert {:ok, :ok} = AppProfileStore.put(reader, group, alt, "page", %{"chapter" => 7})

    assert {:ok, "/poglavlja/03.html"} = AppProfileStore.get(reader, group, nil, "page")
    assert {:ok, %{"chapter" => 7}} = AppProfileStore.get(reader, group, alt, "page")
    assert {:ok, nil} = AppProfileStore.get(other, group, nil, "page")
    assert AppProfileStore.list(other, group, nil) == []

    assert [%{key: "page", value: "/poglavlja/03.html"}] =
             AppProfileStore.list(reader, group, nil)
  end

  test "a value is anything JSON holds, and a new one replaces the old", %{
    reader: reader,
    group: group
  } do
    for value <- [1, 2.5, true, nil, "text", [1, "two"], %{"a" => [1]}] do
      assert {:ok, :ok} = AppProfileStore.put(reader, group, nil, "v", value)
      assert {:ok, ^value} = AppProfileStore.get(reader, group, nil, "v")
    end

    assert Repo.aggregate(AppProfileEntry, :count) == 1
  end

  test "keeps to its limits", %{reader: reader, group: group} do
    assert {:error, :invalid_key} = AppProfileStore.put(reader, group, nil, "no spaces", 1)

    assert {:error, :invalid_key} =
             AppProfileStore.put(reader, group, nil, String.duplicate("k", 65), 1)

    big = String.duplicate("x", AppProfileStore.max_value_bytes())
    assert {:error, :too_big} = AppProfileStore.put(reader, group, nil, "big", big)

    for i <- 1..AppProfileStore.max_keys() do
      assert {:ok, :ok} = AppProfileStore.put(reader, group, nil, "k#{i}", i)
    end

    assert {:error, :too_many_keys} = AppProfileStore.put(reader, group, nil, "one-more", 1)
    # An old key still changes.
    assert {:ok, :ok} = AppProfileStore.put(reader, group, nil, "k1", "changed")
  end

  test "forgets a key, an app or everything", %{reader: reader, group: group} do
    alt = alt!(group, "Druga")
    {:ok, :ok} = AppProfileStore.put(reader, group, nil, "a", 1)
    {:ok, :ok} = AppProfileStore.put(reader, group, nil, "b", 2)
    {:ok, :ok} = AppProfileStore.put(reader, group, alt, "a", 3)

    assert :ok = AppProfileStore.delete(reader, group, nil, "a")
    assert :ok = AppProfileStore.delete(reader, group, nil, "missing")
    assert [%{key: "b"}] = AppProfileStore.list(reader, group, nil)

    assert [_, _] = AppProfileStore.summary(reader)
    assert :ok = AppProfileStore.clear_app(reader, group.id, alt.id)

    assert [%{group_id: group_id, alt_description_id: nil, keys: 1}] =
             AppProfileStore.summary(reader)

    assert group_id == group.id

    assert :ok = AppProfileStore.clear_all(reader)
    assert AppProfileStore.summary(reader) == []
  end

  test "goes with the alternative description and with the group", %{reader: reader, group: group} do
    alt = alt!(group, "Prolazna")
    {:ok, :ok} = AppProfileStore.put(reader, group, alt, "a", 1)
    {:ok, :ok} = AppProfileStore.put(reader, group, nil, "b", 2)

    Repo.delete!(alt)
    assert AppProfileStore.list(reader, group, alt) == []
    assert [_] = AppProfileStore.list(reader, group, nil)

    {:ok, _} = Social.remove_group(Repo.get!(Group, group.id), off: true)
    assert Repo.aggregate(AppProfileEntry, :count) == 0
  end

  test "goes with a deleted account", %{account: account, reader: reader, group: group} do
    alone = group_with_members!(reader, [])
    {:ok, :ok} = AppProfileStore.put(reader, alone, nil, "a", 1)
    # The reader runs `group` with `other` in it: hand it over first.
    {:ok, _} =
      Social.assign_group_member_role(reader, group, group_member(group, "other"), "admin")

    assert {:ok, _} = Accounts.delete_account(account)
    assert Repo.aggregate(AppProfileEntry, :count) == 0
  end

  defp group_member(group, username) do
    Repo.one!(
      from(p in PotokIde.Social.Profile,
        join: m in PotokIde.Social.GroupMembership,
        on: m.profile_id == p.id and m.group_id == ^group.id,
        where: p.username == ^username,
        select: p.id
      )
    )
  end
end
