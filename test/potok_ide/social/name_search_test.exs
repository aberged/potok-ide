defmodule PotokIde.Social.NameSearchTest do
  @moduledoc """
  One search by name (`NameSearch`): any case, with or without diacritics,
  Latin or Cyrillic, and `%` and `_` as themselves.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, NameSearch}

  setup do
    {_account, owner} = account_with_profile!("nsearch-owner")

    names = [
      "Čačak",
      "Београд",
      "Љубљана",
      "Ђурђево",
      "Džep",
      "Šabac",
      "Ниш",
      "100% domaće",
      "a_b",
      "Novi Sad"
    ]

    groups = Map.new(names, &{&1, group_with_members!(owner, [], %{"name" => &1})})
    %{owner: owner, groups: groups}
  end

  defp found(term, groups) do
    ids = Map.new(groups, fn {name, group} -> {group.id, name} end)

    from(g in Group, where: g.id in ^Map.keys(ids), order_by: g.name)
    |> NameSearch.where_matches(NameSearch.term(term))
    |> select([g], g.id)
    |> Repo.all()
    |> Enum.map(&ids[&1])
    |> Enum.sort()
  end

  test "a name is found without diacritics, in either script and any case", %{groups: groups} do
    assert found("cacak", groups) == ["Čačak"]
    assert found("ČAČAK", groups) == ["Čačak"]
    assert found("beograd", groups) == ["Београд"]
    assert found("Београд", groups) == ["Београд"]
    assert found("ljubljana", groups) == ["Љубљана"]
    assert found("djurdj", groups) == ["Ђурђево"]
    assert found("đurđ", groups) == ["Ђурђево"]
    assert found("dzep", groups) == ["Džep"]
    assert found("џеп", groups) == ["Džep"]
    assert found("sabac", groups) == ["Šabac"]
    assert found("nis", groups) == ["Ниш"]
    assert found("сад", groups) == ["Novi Sad"]
  end

  test "letters written as two marks are found too", %{groups: groups} do
    # "Čačak" as C + combining caron, the way some keyboards send it.
    decomposed = "C" <> <<0x030C::utf8>> <> "ac" <> <<0x030C::utf8>> <> "ak"
    assert found(decomposed, groups) == ["Čačak"]
  end

  test "% and _ mean themselves", %{groups: groups} do
    assert found("100%", groups) == ["100% domaće"]
    assert found("_", groups) == ["a_b"]
    assert found("%", groups) == ["100% domaće"]
  end

  test "a blank term finds everything", %{groups: groups} do
    assert NameSearch.term("   ") == nil
    assert length(found("", groups)) == map_size(groups)
  end

  test "the sub-groups list searches the same way", %{owner: owner, groups: groups} do
    root = Social.get_root_group!()
    children = Social.list_child_groups_for_profile(root, owner, search: "cacak")
    assert Enum.map(children, & &1.id) == [groups["Čačak"].id]
  end

  test "a search across a whole table waits for three characters" do
    assert NameSearch.wide_term("ča") == nil
    assert NameSearch.wide_term("  ab  ") == nil
    assert NameSearch.wide_term("čač") == "čač"
    assert NameSearch.wide_term("10%") == "10\\%"
    refute NameSearch.wide?(nil)
    assert NameSearch.wide?("Ниш")
  end

  test "people to invite: none below three characters, % as itself", %{owner: owner} do
    # Open to everyone: the suggestions reach no other stranger.
    {_account, ana} = account_with_profile!("wide-ana")
    {_account, percent} = account_with_profile!("wide-100pct")

    for profile <- [ana, percent],
        do: Repo.update!(Ecto.Changeset.change(profile, discovery: :everyone))

    group = group_with_members!(owner, [], %{"name" => "wide-group"})

    assert Social.list_invitable_profiles_for_group(owner, group, "wi") == []

    assert owner
           |> Social.list_invitable_profiles_for_group(group, "wide-a")
           |> Enum.map(& &1.username) == ["wide-ana"]

    assert Social.list_invitable_profiles_for_group(owner, group, "wide%") == []
  end

  test "invitations are searched by the group's folded name, % as itself", %{
    owner: owner,
    groups: groups
  } do
    {_account, invitee} = account_with_profile!("nsearch-invitee")

    for name <- ["Čačak", "100% domaće", "Novi Sad"],
        do: {:ok, _} = Social.invite_profile_to_group(owner, groups[name], invitee)

    names = fn search ->
      invitee
      |> Social.list_pending_invitations(search: search)
      |> Enum.map(& &1.group.name)
      |> Enum.sort()
    end

    assert names.("cacak") == ["Čačak"]
    assert names.("%") == ["100% domaće"]
    assert names.("") == Enum.sort(["Čačak", "100% domaće", "Novi Sad"])
  end
end
