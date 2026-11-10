defmodule PotokIde.Social.GroupAreasTest do
  @moduledoc """
  A group's place as an area (`Group.area`, `GroupAreas`): the border as it is
  kept, the pin inside it, and which areas a profile sees around a point, in a
  map's box, by name.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas}

  # Novi Sad's middle; a "city" of 0.2° around it and a "quarter" inside.
  @ns {45.25, 19.85}

  setup do
    {_account, owner} = account_with_profile!("area-owner")
    {_account, member} = account_with_profile!("area-member")
    {_account, outsider} = account_with_profile!("area-outsider")

    %{owner: owner, member: member, outsider: outsider}
  end

  # A square `half` degrees around the centre, as GeoJSON.
  defp square({lat, lng}, half) do
    [
      [lng - half, lat - half],
      [lng + half, lat - half],
      [lng + half, lat + half],
      [lng - half, lat + half],
      [lng - half, lat - half]
    ]
  end

  defp polygon(rings), do: %{"type" => "Polygon", "coordinates" => rings}

  defp area!(geojson) do
    {:ok, area} = GroupAreas.decode(geojson)
    area
  end

  defp area_group!(owner, members, geojson, attrs \\ %{}) do
    group = group_with_members!(owner, members, attrs)
    {:ok, group} = Social.update_group(owner, group, %{"area" => area!(geojson)})
    group
  end

  defp point_group!(owner, members, {lat, lng}, attrs) do
    group_with_members!(
      owner,
      members,
      Map.merge(%{"latitude" => lat, "longitude" => lng}, attrs)
    )
  end

  describe "a border" do
    test "a polygon becomes a multipolygon in WGS 84, closed and rounded" do
      assert {:ok, %Geo.MultiPolygon{srid: 4326, coordinates: [[ring]]}} =
               GroupAreas.decode(
                 polygon([[[19.1234567, 45.0], [19.2, 45.0], [19.2, 45.1], [19.1, 45.1]]])
               )

      assert hd(ring) == {19.123457, 45.0}
      assert List.last(ring) == hd(ring)
      assert length(ring) == 5
    end

    test "keeps holes and several parts" do
      geojson = %{
        "type" => "MultiPolygon",
        "coordinates" => [
          [square(@ns, 0.1), square(@ns, 0.02)],
          [square({45.6, 19.85}, 0.05)]
        ]
      }

      assert {:ok, %Geo.MultiPolygon{coordinates: [[_shell, _hole], [_other]]}} =
               GroupAreas.decode(geojson)
    end

    test "refuses what is not a border" do
      assert {:error, :invalid} = GroupAreas.decode(%{"type" => "Point", "coordinates" => [1, 2]})
      assert {:error, :invalid} = GroupAreas.decode(polygon([[[19.1, 45.0], [19.2, 45.0]]]))
      assert {:error, :invalid} = GroupAreas.decode(polygon([[["a", 45.0], [19.2, 45.0]]]))
      assert {:error, :invalid} = GroupAreas.decode(polygon(["x"]))

      assert {:error, :invalid} =
               GroupAreas.decode(polygon([[[19.1, 89.0], [19.2, 89.0], [19.2, 89.5]]]))
    end

    test "refuses one wider than half the world or with too many points" do
      assert {:error, :too_wide} =
               GroupAreas.decode(polygon([[[-100, 10], [100, 10], [100, 20], [-100, 20]]]))

      many =
        for i <- 0..10_000 do
          angle = i * 2 * :math.pi() / 10_001
          [19.85 + 0.1 * :math.cos(angle), 45.25 + 0.1 * :math.sin(angle)]
        end

      assert {:error, :too_many_points} = GroupAreas.decode(polygon([many]))
    end

    test "the changeset keeps the border and names what is wrong" do
      changeset =
        Group.update_changeset(%Group{name: "x"}, %{"area" => area!(polygon([square(@ns, 0.1)]))})

      assert changeset.valid?

      changeset =
        Group.update_changeset(%Group{name: "x"}, %{
          "area" => %Geo.Polygon{coordinates: [[{-100.0, 10.0}, {100.0, 10.0}, {100.0, 20.0}]]}
        })

      assert {"The border is wider than half the world.", _} = changeset.errors[:area]
    end

    test "goes to a browser as GeoJSON" do
      area = area!(polygon([square(@ns, 0.1)]))

      assert %{"type" => "MultiPolygon", "coordinates" => [[[[19.75, 45.15] | _]]]} =
               GroupAreas.to_geojson(area)
    end
  end

  describe "the pin" do
    test "an area's pin stands inside it, whatever the form sent", %{owner: owner} do
      # An L shape, whose middle lies outside it.
      l_shape =
        polygon([
          [[19.0, 45.0], [19.4, 45.0], [19.4, 45.1], [19.1, 45.1], [19.1, 45.4], [19.0, 45.4]]
        ])

      group = group_with_members!(owner, [])

      {:ok, group} =
        Social.update_group(owner, group, %{
          "area" => area!(l_shape),
          "latitude" => "10",
          "longitude" => "10"
        })

      assert group.latitude > 45.0 and group.latitude < 45.4
      assert group.longitude > 19.0 and group.longitude < 19.4

      assert [%{id: id}] =
               GroupAreas.areas_at(owner, group.latitude, group.longitude)

      assert id == group.id
      assert Social.load_area(Repo.get!(Group, group.id)).area.coordinates != []
    end

    test "a border that crosses itself is refused", %{owner: owner} do
      group = group_with_members!(owner, [])
      bowtie = polygon([[[19.0, 45.0], [19.2, 45.2], [19.2, 45.0], [19.0, 45.2]]])

      assert {:error, changeset} = Social.update_group(owner, group, %{"area" => area!(bowtie)})
      assert {"The border crosses itself.", _} = changeset.errors[:area]
    end

    test "removing the area keeps the pin where it stood", %{owner: owner} do
      group = area_group!(owner, [], polygon([square(@ns, 0.1)]))
      {:ok, cleared} = Social.update_group(owner, group, %{"area" => nil})

      assert Social.load_area(cleared).area == nil
      assert {cleared.latitude, cleared.longitude} == {group.latitude, group.longitude}
    end

    test "only whoever may edit the group sets one", %{owner: owner, member: member} do
      group = group_with_members!(owner, [member])

      assert {:error, :not_permitted} =
               Social.update_group(member, group, %{"area" => area!(polygon([square(@ns, 0.1)]))})
    end

    test "the database refuses an area without its pin", %{owner: owner} do
      group = group_with_members!(owner, [])

      assert {:error, changeset} =
               group
               |> Ecto.Changeset.change(area: area!(polygon([square(@ns, 0.1)])))
               |> Group.update_changeset(%{})
               |> Repo.update()

      assert changeset.errors[:area]
    end
  end

  describe "which areas" do
    setup %{owner: owner, member: member} do
      city = area_group!(owner, [], polygon([square(@ns, 0.2)]), %{"is_public" => true})
      # The quarter has a hole around a park in its middle.
      quarter =
        area_group!(owner, [], polygon([square(@ns, 0.05), square(@ns, 0.01)]), %{
          "is_public" => true
        })

      closed = area_group!(owner, [member], polygon([square(@ns, 0.03)]))

      %{city: city, quarter: quarter, closed: closed}
    end

    test "the areas around a point, smallest first, and only those one sees", ctx do
      %{city: city, quarter: quarter, closed: closed} = ctx
      {lat, lng} = @ns
      at = fn profile -> GroupAreas.areas_at(profile, lat + 0.02, lng) |> Enum.map(& &1.id) end

      assert at.(ctx.outsider) == [quarter.id, city.id]
      assert at.(ctx.member) == [closed.id, quarter.id, city.id]

      # The hole in the quarter: only the city holds the park.
      assert GroupAreas.areas_at(ctx.outsider, lat, lng) |> Enum.map(& &1.id) == [city.id]
    end

    test "where a group is: the areas that hold its pin, not itself", ctx do
      %{city: city, quarter: quarter} = ctx
      {lat, lng} = @ns
      shop = point_group!(ctx.owner, [], {lat + 0.02, lng + 0.02}, %{"is_public" => true})

      assert GroupAreas.containing(ctx.outsider, shop) |> Enum.map(& &1.id) == [
               quarter.id,
               city.id
             ]

      assert GroupAreas.containing(ctx.outsider, quarter) |> Enum.map(& &1.id) == [city.id]
      # The city's pin falls inside the quarter, which does not hold the city.
      assert GroupAreas.containing(ctx.outsider, city) == []
      assert GroupAreas.containing(ctx.outsider, group_with_members!(ctx.owner, [])) == []
    end

    test "a thread or a direct conversation is never an area someone sees", ctx do
      {1, _} =
        Repo.update_all(
          from(g in Group, where: g.id == ^ctx.city.id),
          set: [is_direct: true]
        )

      {lat, lng} = @ns
      refute ctx.city.id in Enum.map(GroupAreas.areas_at(ctx.outsider, lat + 0.15, lng), & &1.id)
    end

    test "a map draws the areas wide enough at its zoom, biggest first", ctx do
      %{city: city, quarter: quarter} = ctx
      box = Social.map_bbox_params([19.0, 44.5, 20.7, 46.0])

      drawn = fn zoom ->
        GroupAreas.list_drawable(ctx.outsider, box, zoom, 300) |> Enum.map(& &1.group.id)
      end

      # 0.4° wide is ~36 px at zoom 7; the 0.1° quarter needs zoom 9.
      assert drawn.(5) == []
      assert drawn.(7) == [city.id]
      assert drawn.(10) == [city.id, quarter.id]

      far = Social.map_bbox_params([21.0, 43.0, 22.0, 44.0])
      assert GroupAreas.list_drawable(ctx.outsider, far, 10, 300) == []

      [%{bbox: [west, south, east, north]} | _] =
        GroupAreas.list_drawable(ctx.outsider, box, 10, 300)

      assert_in_delta west, 19.65, 1.0e-6
      assert_in_delta south, 45.05, 1.0e-6
      assert_in_delta east, 20.05, 1.0e-6
      assert_in_delta north, 45.45, 1.0e-6
    end

    test "borders come simplified for the zoom, to whoever sees them", ctx do
      %{city: city, closed: closed} = ctx

      assert [%{id: id, version: version, geojson: geojson}] =
               GroupAreas.shapes(ctx.outsider, [city.id, closed.id], 12)

      assert id == city.id
      assert version == DateTime.to_unix(city.updated_at)
      assert %{"type" => "MultiPolygon", "coordinates" => [[ring]]} = Jason.decode!(geojson)
      assert length(ring) == 5
    end

    test "a filter finds areas by name and knows which ones a profile sees", ctx do
      %{city: city, quarter: quarter, closed: closed} = ctx
      {:ok, city} = Social.update_group(ctx.owner, city, %{"name" => "Grad 100%"})

      assert GroupAreas.search(ctx.outsider, "100%", 10) |> Enum.map(& &1.id) == [city.id]

      assert GroupAreas.search(ctx.outsider, "", 10) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([city.id, quarter.id])

      assert GroupAreas.get_visible(ctx.outsider, [closed.id, quarter.id]) |> Enum.map(& &1.id) ==
               [quarter.id]

      assert [[south, west], [north, east]] = GroupAreas.extent(ctx.outsider, [quarter.id])
      assert_in_delta south, 45.2, 1.0e-6
      assert_in_delta west, 19.8, 1.0e-6
      assert_in_delta north, 45.3, 1.0e-6
      assert_in_delta east, 19.9, 1.0e-6
      assert GroupAreas.extent(ctx.outsider, [closed.id]) == nil
    end
  end

  describe "the root's map" do
    setup %{owner: owner} do
      {lat, lng} = @ns
      quarter = area_group!(owner, [], polygon([square(@ns, 0.05)]), %{"is_public" => true})
      inside = point_group!(owner, [], {lat + 0.01, lng + 0.01}, %{"is_public" => true})
      outside = point_group!(owner, [], {lat + 0.3, lng}, %{"is_public" => true})

      %{quarter: quarter, inside: inside, outside: outside}
    end

    defp pins(profile, filters, zoom) do
      {:ok, cells} =
        Social.list_map_cells(
          profile,
          Map.merge(%{public?: true}, filters),
          [19.0, 44.5, 20.7, 46.0],
          zoom
        )

      cells.places |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "an area's pin leaves the clusters where the area is drawn", ctx do
      %{quarter: quarter, inside: inside, outside: outside} = ctx
      all = Enum.sort([quarter.id, inside.id, outside.id])

      assert pins(ctx.outsider, %{}, 18) == all
      assert pins(ctx.outsider, %{shapes?: true}, 18) == Enum.sort([inside.id, outside.id])
    end

    test "an area too small to draw is a pin whatever the filters, and alone without places",
         ctx do
      %{quarter: quarter, inside: inside} = ctx
      # Nothing passes this time frame, and the quarter is ~9 px wide at zoom 7.
      gone = %{from: DateTime.add(DateTime.utc_now(), 1, :day)}

      assert pins(ctx.outsider, gone, 7) == []
      assert pins(ctx.outsider, Map.put(gone, :shapes?, true), 7) == [quarter.id]

      assert pins(ctx.outsider, %{shapes?: true, places?: false}, 7) == [quarter.id]
      refute inside.id in pins(ctx.outsider, %{shapes?: true, places?: false}, 7)
    end

    test "the area filter keeps the pins inside, not the area itself", ctx do
      assert pins(ctx.outsider, %{areas: [ctx.quarter.id]}, 18) == [ctx.inside.id]

      assert {:ok, %{count: 1}} =
               Social.map_extent(ctx.outsider, %{public?: true, areas: [ctx.quarter.id]})
    end

    test "an area one does not see filters nothing in", ctx do
      closed = area_group!(ctx.owner, [], polygon([square(@ns, 0.05)]))
      assert pins(ctx.outsider, %{areas: [closed.id]}, 18) == []
      assert pins(ctx.owner, %{areas: [closed.id]}, 18) |> Enum.member?(ctx.inside.id)
    end
  end
end
