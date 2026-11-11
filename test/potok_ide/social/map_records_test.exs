defmodule PotokIde.Social.MapRecordsTest do
  @moduledoc """
  Records, the groups an app brought in with a key (`Social.create_children/3`),
  stand on their own map only: the root's map and the place picker of events
  leave them out, even with every public group shown.
  """
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.GroupPlaces

  @serbia [18.8, 41.8, 23.1, 46.2]

  setup do
    {_account, owner} = account_with_profile!("records-owner")
    {_account, viewer} = account_with_profile!("records-viewer")

    {:ok, map} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "Nezgode 2025",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    {:ok, ordinary} =
      Social.create_group(owner, map, %{
        "name" => "Prodavnica Barajevo",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true,
        "latitude" => 44.70,
        "longitude" => 20.30
      })

    {:ok, [%{id: record}]} =
      Social.create_children(owner, map, [
        %{
          "name" => "Povređeni Barajevo",
          "description" => "",
          "is_public" => true,
          "latitude" => 44.62,
          "longitude" => 20.37,
          "pin_icon" => "warning",
          "external_key" => "mup:1510533"
        }
      ])

    %{owner: owner, viewer: viewer, map: map, ordinary: ordinary, record: record}
  end

  test "the root's map leaves records out, even with every public group", ctx do
    {:ok, cells} = Social.list_map_cells(ctx.viewer, %{public?: true}, @serbia, 18)
    ids = Enum.map(cells.places, & &1.id)

    assert ctx.ordinary.id in ids
    refute ctx.record in ids

    {:ok, extent} = Social.map_extent(ctx.viewer, %{public?: true, search: "barajevo"})
    assert extent.count == 1

    {:ok, {spot, false}} =
      Social.list_map_spot(ctx.viewer, %{public?: true}, [[44.0, 20.0], [45.0, 21.0]], 50)

    assert Enum.map(spot, & &1.id) == [ctx.ordinary.id]
  end

  test "their own map shows them", ctx do
    {:ok, cells} = Social.list_map_cells(ctx.viewer, %{parent_id: ctx.map.id}, @serbia, 18)

    assert cells.places |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort([ctx.ordinary.id, ctx.record])

    {:ok, [{"kind", 1}, {"warning", 1}]} = Social.count_child_places_by_pin(ctx.map, ctx.viewer)
  end

  test "the place picker of events does not offer them", ctx do
    found = GroupPlaces.search(ctx.viewer, "barajevo", nil, 20) |> Enum.map(&elem(&1, 0).id)
    assert found == [ctx.ordinary.id]

    near = GroupPlaces.search(ctx.viewer, "", {44.62, 20.37}, 20) |> Enum.map(&elem(&1, 0).id)
    refute ctx.record in near

    assert GroupPlaces.get_visible(ctx.viewer, ctx.record) == nil
    assert GroupPlaces.get_visible(ctx.viewer, ctx.ordinary.id).id == ctx.ordinary.id
  end

  test "a trial import is taken away, and only the records", ctx do
    assert {:ok, 1, 0} = PotokIde.Social.RecordImport.remove(ctx.map.id, ctx.owner.id)

    assert PotokIde.Repo.get(PotokIde.Social.Group, ctx.record) == nil
    assert PotokIde.Repo.get(PotokIde.Social.Group, ctx.ordinary.id)
    assert {:ok, 0, 0} = PotokIde.Social.RecordImport.remove(ctx.map.id, ctx.viewer.id)
  end
end
