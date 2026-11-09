defmodule PotokIde.Social.GroupLocationTest do
  @moduledoc """
  A group's place on a map (`Group.latitude`, `longitude`, `pin_icon`): both
  coordinates or neither, set by whoever may edit the group, and the placed
  children a map reads.
  """
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupPresets}

  setup do
    {_account, owner} = account_with_profile!("place-owner")
    {_account, member} = account_with_profile!("place-member")
    {_account, outsider} = account_with_profile!("place-outsider")

    map = group_with_members!(owner, [member], %{"is_public" => true})

    %{owner: owner, member: member, outsider: outsider, map: map}
  end

  defp child!(owner, parent, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => "place-#{System.unique_integer([:positive])}",
            "description" => "",
            "description_format" => :markdown
          },
          attrs
        )
      )

    group
  end

  describe "the changeset" do
    test "takes both coordinates, rounded to six decimals" do
      changeset =
        Group.update_changeset(%Group{name: "x"}, %{
          "latitude" => "44.8125449123",
          "longitude" => "20.4612299876"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :latitude) == 44.812545
      assert Ecto.Changeset.get_change(changeset, :longitude) == 20.46123
    end

    test "refuses one coordinate without the other" do
      changeset = Group.update_changeset(%Group{name: "x"}, %{"latitude" => "44.8"})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:longitude]
    end

    test "refuses coordinates out of range" do
      changeset =
        Group.update_changeset(%Group{name: "x"}, %{"latitude" => "91", "longitude" => "-181"})

      refute changeset.valid?
      assert changeset.errors[:latitude]
      assert changeset.errors[:longitude]
    end

    test "takes a pin of the catalogue, and an empty one is the kind's" do
      assert Group.update_changeset(%Group{name: "x"}, %{"pin_icon" => "shop"}).valid?
      assert Group.update_changeset(%Group{name: "x"}, %{"pin_icon" => "picture"}).valid?

      changeset = Group.update_changeset(%Group{name: "x", pin_icon: "shop"}, %{"pin_icon" => ""})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :pin_icon) == nil

      refute Group.update_changeset(%Group{name: "x"}, %{"pin_icon" => "unicorn"}).valid?
    end

    test "clears both coordinates at once" do
      changeset =
        Group.update_changeset(%Group{name: "x", latitude: 44.0, longitude: 20.0}, %{
          "latitude" => "",
          "longitude" => ""
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :latitude) == nil
    end
  end

  test "the database holds both coordinates or neither", ctx do
    group = child!(ctx.owner, ctx.map, %{})

    assert_raise Postgrex.Error, ~r/groups_location_check/, fn ->
      Repo.update_all(from(g in Group, where: g.id == ^group.id), set: [latitude: 44.0])
    end
  end

  test "only whoever may edit the group puts it on a map", ctx do
    group = child!(ctx.owner, ctx.map, %{"inherits_members" => true})
    attrs = %{"latitude" => 44.8, "longitude" => 20.46, "pin_icon" => "school"}

    assert {:error, :not_permitted} = Social.update_group(ctx.member, group, attrs)

    assert {:ok, group} = Social.update_group(ctx.owner, group, attrs)
    assert {group.latitude, group.longitude, group.pin_icon} == {44.8, 20.46, "school"}
  end

  test "a preset can put the new group on a map", ctx do
    choices = Map.put(GroupPresets.defaults("page", ctx.map), "name", "Kafana")
    place = %{"latitude" => 45.25, "longitude" => 19.84, "pin_icon" => "food"}

    assert {:ok, %{group: group}} =
             Social.create_group_from_preset(ctx.member, ctx.map, "page", choices, place)

    assert {group.latitude, group.longitude, group.pin_icon} == {45.25, 19.84, "food"}
    assert group.preset == :page
    assert group.creator_id == ctx.member.id
  end

  test "a preset refuses whoever may not make a sub-group", ctx do
    choices = Map.put(GroupPresets.defaults("chat", ctx.map), "name", "Uljez")
    place = %{"latitude" => 45.0, "longitude" => 19.0}

    assert {:error, _} =
             Social.create_group_from_preset(ctx.outsider, ctx.map, "chat", choices, place)
  end

  describe "the placed children" do
    test "are the direct sub-groups with a place that the profile sees", ctx do
      placed =
        child!(ctx.owner, ctx.map, %{"latitude" => 44.0, "longitude" => 20.0, "is_public" => true})

      _unplaced = child!(ctx.owner, ctx.map, %{"is_public" => true})

      closed =
        child!(ctx.owner, ctx.map, %{
          "latitude" => 45.0,
          "longitude" => 21.0,
          "is_public" => false
        })

      grandchild = child!(ctx.owner, placed, %{"latitude" => 43.0, "longitude" => 21.0})

      {owner_rows, false} = Social.list_visible_placed_children(ctx.map, ctx.owner, 10)
      assert Enum.map(owner_rows, & &1.id) == [placed.id, closed.id]
      refute grandchild.id in Enum.map(owner_rows, & &1.id)

      {outsider_rows, false} = Social.list_visible_placed_children(ctx.map, ctx.outsider, 10)
      assert Enum.map(outsider_rows, & &1.id) == [placed.id]
    end

    test "say when there are more than asked for", ctx do
      for lat <- [41.0, 42.0, 43.0] do
        child!(ctx.owner, ctx.map, %{"latitude" => lat, "longitude" => 20.0, "is_public" => true})
      end

      assert {[_, _], true} = Social.list_visible_placed_children(ctx.map, ctx.owner, 2)
      assert {[_, _, _], false} = Social.list_visible_placed_children(ctx.map, ctx.owner, 3)
    end
  end
end
