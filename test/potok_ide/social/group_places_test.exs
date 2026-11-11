defmodule PotokIde.Social.GroupPlacesTest do
  @moduledoc """
  Groups with a place as something to pick or to point at (`GroupPlaces`):
  only those the profile sees, any shape, the nearest first, by name.
  """
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{GroupAreas, GroupPlaces}

  setup do
    {_owner_account, owner} = account_with_profile!("gplaces-owner")
    {_viewer_account, viewer} = account_with_profile!("gplaces-viewer")

    # Novi Sad's middle, a bakery a kilometre east, a public square in Čačak,
    # a closed group the viewer is not in and one with no place.
    center = group_with_members!(owner, [viewer], %{"latitude" => 45.25, "longitude" => 19.85})

    bakery =
      group_with_members!(owner, [viewer], %{
        "name" => "Pekara",
        "latitude" => 45.25,
        "longitude" => 19.8628
      })

    square =
      group_with_members!(owner, [], %{
        "name" => "Čačak trg",
        "is_public" => true,
        "latitude" => 43.891,
        "longitude" => 20.35
      })

    closed =
      group_with_members!(owner, [], %{
        "name" => "Zatvorena",
        "latitude" => 45.251,
        "longitude" => 19.851
      })

    plain = group_with_members!(owner, [viewer], %{"name" => "Bez mesta"})

    %{
      owner: owner,
      viewer: viewer,
      center: center,
      bakery: bakery,
      square: square,
      closed: closed,
      plain: plain
    }
  end

  defp ids(results), do: Enum.map(results, fn {group, _meters} -> group.id end)

  test "a group is found when the profile sees it and it has a place", ctx do
    assert GroupPlaces.get_visible(ctx.viewer, ctx.bakery.id).name == "Pekara"
    assert GroupPlaces.get_visible(ctx.viewer, ctx.square.id).is_public
    assert GroupPlaces.get_visible(ctx.viewer, ctx.closed.id) == nil
    assert GroupPlaces.get_visible(ctx.viewer, ctx.plain.id) == nil
    assert GroupPlaces.get_visible(ctx.viewer, Social.get_root_group!().id) == nil
    assert GroupPlaces.get_visible(ctx.viewer, nil) == nil
  end

  test "the nearest come first, with how far they are", ctx do
    results = GroupPlaces.search(ctx.viewer, "", {45.25, 19.85}, 10)

    assert ids(results) == [ctx.center.id, ctx.bakery.id, ctx.square.id]
    assert [{_center, center_m}, {_bakery, bakery_m}, {_square, square_m}] = results
    assert center_m < 1
    assert_in_delta bakery_m, 1000, 30
    assert square_m > 150_000

    assert ids(GroupPlaces.search(ctx.viewer, "", {45.25, 19.85}, 1)) == [ctx.center.id]
  end

  test "a name finds a group without diacritics; without a point, own groups first", ctx do
    assert ids(GroupPlaces.search(ctx.viewer, "cacak", nil, 10)) == [ctx.square.id]
    assert ids(GroupPlaces.search(ctx.viewer, "pek", {45.25, 19.85}, 10)) == [ctx.bakery.id]

    results = GroupPlaces.search(ctx.viewer, "", nil, 10)
    assert List.last(ids(results)) == ctx.square.id
    assert Enum.all?(results, fn {_group, meters} -> meters == nil end)
  end

  test "a place's shape and the box a map fits to", ctx do
    {:ok, area} =
      GroupAreas.decode(%{
        "type" => "Polygon",
        "coordinates" => [[[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.3], [19.8, 45.2]]]
      })

    {:ok, _quarter} = Social.update_group(ctx.owner, ctx.center, %{"area" => area})

    quarter = GroupPlaces.get_visible(ctx.viewer, ctx.center.id)
    assert GroupPlaces.shape(quarter) == :area
    assert GroupPlaces.bounds(quarter) == [[45.2, 19.8], [45.3, 19.9]]

    bakery = GroupPlaces.get_visible(ctx.viewer, ctx.bakery.id)
    assert GroupPlaces.shape(bakery) == :point
    assert GroupPlaces.bounds(bakery) == [[45.25, 19.8628], [45.25, 19.8628]]
  end
end
