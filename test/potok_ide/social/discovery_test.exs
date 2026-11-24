defmodule PotokIde.Social.DiscoveryTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.Social.{Discovery, Profile, ProfileFacts}

  defp facts(attrs), do: struct(ProfileFacts, attrs)
  defp target(discovery), do: %Profile{id: 1, kind: :person, discovery: discovery}

  describe "may_find?/3" do
    test "a stranger finds by name, in a list or by an id as the profile allows" do
      stranger = facts([])

      expected = %{
        everyone: %{username: true, list: true, id: true},
        by_username: %{username: true, list: false, id: false},
        shared_groups: %{username: false, list: false, id: false}
      }

      for {discovery, by_via} <- expected, {via, found?} <- by_via do
        assert Discovery.may_find?(stranger, target(discovery), via) == found?,
               "#{discovery} via #{via}"
      end
    end

    test "a shared group, a relation or the profile's own account finds it any way" do
      for facts <- [
            facts(shared_group_ids: MapSet.new([5])),
            facts(relation_group_ids: MapSet.new([5])),
            facts(holder?: true)
          ],
          via <- [:username, :list, :id] do
        assert Discovery.may_find?(facts, target(:shared_groups), via)
      end
    end

    test "a direct conversation lets an id through, not a name or a list" do
      talking = facts(direct?: true)

      assert Discovery.may_find?(talking, target(:shared_groups), :id)
      refute Discovery.may_find?(talking, target(:shared_groups), :username)
      refute Discovery.may_find?(talking, target(:by_username), :list)
    end

    test "a process or a deleted profile is never found" do
      for kind <- [:process, :deleted] do
        refute Discovery.may_find?(facts(holder?: true), %Profile{kind: kind}, :username)
      end
    end
  end

  describe "may_message?/2" do
    test "someone it may find by name, or one it talks to, never its own" do
      assert Discovery.may_message?(facts([]), target(:by_username))
      refute Discovery.may_message?(facts([]), target(:shared_groups))
      assert Discovery.may_message?(facts(direct?: true), target(:shared_groups))
      refute Discovery.may_message?(facts(holder?: true), target(:everyone))
    end
  end
end
