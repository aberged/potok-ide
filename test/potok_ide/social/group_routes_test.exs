defmodule PotokIde.Social.GroupRoutesTest do
  @moduledoc """
  A group's place as a route (`Group.route`, `GroupRoutes`): the line as it is
  kept, the pin at its start, what Postgres keeps of it, a place that is an
  area or a route but never both, and the areas a route passes through.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas, GroupRoutes}

  # Novi Sad's middle.
  @ns {45.25, 19.85}

  setup do
    {_account, owner} = account_with_profile!("route-owner")
    {_account, member} = account_with_profile!("route-member")
    {_account, outsider} = account_with_profile!("route-outsider")

    %{owner: owner, member: member, outsider: outsider}
  end

  defp line(points), do: %{"type" => "LineString", "coordinates" => points}

  defp route!(geojson) do
    {:ok, route} = GroupRoutes.decode(geojson)
    route
  end

  # West to east along the parallel of `lat`, from `from` to `to`.
  defp across(lat, from, to), do: line([[from, lat], [(from + to) / 2, lat + 0.01], [to, lat]])

  defp square({lat, lng}, half) do
    [
      [lng - half, lat - half],
      [lng + half, lat - half],
      [lng + half, lat + half],
      [lng - half, lat + half],
      [lng - half, lat - half]
    ]
  end

  defp area!(ring) do
    {:ok, area} = GroupAreas.decode(%{"type" => "Polygon", "coordinates" => [ring]})
    area
  end

  defp route_group!(owner, geojson, attrs \\ %{}) do
    group = group_with_members!(owner, [], attrs)
    {:ok, group} = Social.update_group(owner, group, %{"route" => route!(geojson)})
    group
  end

  defp area_group!(owner, ring, attrs) do
    group = group_with_members!(owner, [], attrs)
    {:ok, group} = Social.update_group(owner, group, %{"area" => area!(ring)})
    group
  end

  describe "a line" do
    test "a line string becomes a multi line string in WGS 84, rounded, without repeats" do
      assert {:ok, %Geo.MultiLineString{srid: 4326, coordinates: [points]}} =
               GroupRoutes.decode(
                 line([[19.1234567, 45.0], [19.1234567, 45.0], [19.2, 45.1, 120.5]])
               )

      assert points == [{19.123457, 45.0}, {19.2, 45.1}]
    end

    test "keeps several parts, and a loop that ends where it starts" do
      geojson = %{
        "type" => "MultiLineString",
        "coordinates" => [
          [[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.2]],
          [[20.0, 45.0], [20.1, 45.0]]
        ]
      }

      assert {:ok, %Geo.MultiLineString{coordinates: [loop, _other]}} =
               GroupRoutes.decode(geojson)

      assert hd(loop) == List.last(loop)
    end

    test "refuses what is not a line" do
      for geojson <- [
            line([[19.8, 45.2]]),
            line([[19.8, 45.2], [19.8, 45.2]]),
            line([[19.8, 89.0], [19.9, 89.0]]),
            line([[19.8, 45.2], ["east", 45.2]]),
            %{"type" => "Polygon", "coordinates" => [square(@ns, 0.1)]},
            %{"type" => "MultiLineString", "coordinates" => []},
            %{"type" => "LineString"},
            nil
          ] do
        assert {:error, :invalid} = GroupRoutes.decode(geojson)
      end
    end

    test "refuses one wider than half the world, with too many parts or points" do
      assert {:error, :too_wide} = GroupRoutes.decode(line([[-100.0, 0.0], [100.0, 0.0]]))

      parts = for n <- 1..101, do: [[19.0 + n / 1000, 45.0], [19.0 + n / 1000, 45.1]]

      assert {:error, :too_many_parts} =
               GroupRoutes.decode(%{"type" => "MultiLineString", "coordinates" => parts})

      points = for n <- 1..10_001, do: [19.0 + n / 100_000, 45.0]
      assert {:error, :too_many_points} = GroupRoutes.decode(line(points))
    end

    test "the changeset keeps the line and names what is wrong" do
      changeset =
        Group.update_changeset(%Group{name: "a"}, %{
          "route" => %Geo.MultiLineString{coordinates: [[{19.8, 45.2}]]}
        })

      assert {"The route is not a line on a map.", _} = changeset.errors[:route]
    end

    test "goes to a browser as GeoJSON" do
      route = route!(line([[19.8, 45.2], [19.9, 45.3]]))

      assert GroupRoutes.to_geojson(route) == %{
               "type" => "MultiLineString",
               "coordinates" => [[[19.8, 45.2], [19.9, 45.3]]]
             }

      assert GroupRoutes.to_geojson(nil) == nil
    end
  end

  describe "the pin" do
    test "a route's pin stands at its start, whatever the form sent", %{owner: owner} do
      group = group_with_members!(owner, [])

      {:ok, group} =
        Social.update_group(owner, group, %{
          "route" => route!(across(45.25, 19.8, 19.9)),
          "latitude" => "10",
          "longitude" => "10"
        })

      assert {group.latitude, group.longitude} == {45.25, 19.8}

      assert %Geo.MultiLineString{} = Social.load_area(Repo.get!(Group, group.id)).route
    end

    test "Postgres keeps its length in metres, its box and its width", %{owner: owner} do
      route = route!(line([[19.8, 45.25], [19.9, 45.25]]))
      group = route_group!(owner, line([[19.8, 45.25], [19.9, 45.25]]))

      kept =
        Repo.one!(
          from g in Group,
            where: g.id == ^group.id,
            select: [g.route_length, g.route_west, g.route_east, g.route_span]
        )

      [meters, west, east, span] = kept
      # A tenth of a degree of longitude at 45° north: about 7.9 km.
      assert_in_delta meters, 7_880, 60
      assert_in_delta GroupRoutes.meters(route), meters, 0.01
      assert {west, east} == {19.8, 19.9}
      assert_in_delta span, 0.1, 1.0e-9
    end

    test "turning the line around moves the pin to the other end", %{owner: owner} do
      group = route_group!(owner, across(45.25, 19.8, 19.9))

      {:ok, turned} =
        Social.update_group(owner, group, %{"route" => route!(across(45.25, 19.9, 19.8))})

      assert {turned.latitude, turned.longitude} == {45.25, 19.9}
    end

    test "removing the route keeps the pin where it stood", %{owner: owner} do
      group = route_group!(owner, across(45.25, 19.8, 19.9))
      {:ok, cleared} = Social.update_group(owner, group, %{"route" => nil})

      assert Social.load_area(cleared).route == nil
      assert {cleared.latitude, cleared.longitude} == {45.25, 19.8}
    end

    test "only whoever may edit the group sets one", %{owner: owner, member: member} do
      group = group_with_members!(owner, [member])

      assert {:error, :not_permitted} =
               Social.update_group(member, group, %{"route" => route!(across(45.25, 19.8, 19.9))})
    end
  end

  describe "an area or a route" do
    test "a route takes the area's place, and an area the route's", %{owner: owner} do
      group = area_group!(owner, square(@ns, 0.1), %{})

      {:ok, route_group} =
        Social.update_group(owner, group, %{"route" => route!(across(45.4, 19.8, 19.9))})

      loaded = Social.load_area(route_group)
      assert loaded.area == nil
      assert %Geo.MultiLineString{} = loaded.route
      assert {route_group.latitude, route_group.longitude} == {45.4, 19.8}

      {:ok, area_group} =
        Social.update_group(owner, route_group, %{"area" => area!(square(@ns, 0.1))})

      loaded = Social.load_area(area_group)
      assert loaded.route == nil
      assert %Geo.MultiPolygon{} = loaded.area
      # The pin is back inside the area.
      assert_in_delta area_group.latitude, 45.25, 0.01
    end

    test "both at once is refused", %{owner: owner} do
      group = group_with_members!(owner, [])

      assert {:error, changeset} =
               Social.update_group(owner, group, %{
                 "area" => area!(square(@ns, 0.1)),
                 "route" => route!(across(45.25, 19.8, 19.9))
               })

      assert {"A place is either an area or a route.", _} = changeset.errors[:route]
    end

    test "the database refuses a route without its pin, or next to an area", %{owner: owner} do
      group = group_with_members!(owner, [])
      route = route!(across(45.25, 19.8, 19.9))

      assert {:error, changeset} =
               group
               |> Ecto.Changeset.change(route: route)
               |> Ecto.Changeset.check_constraint(:route, name: :groups_route_check)
               |> Repo.update()

      assert changeset.errors[:route]

      assert {:error, changeset} =
               group
               |> Ecto.Changeset.change(
                 route: route,
                 area: area!(square(@ns, 0.1)),
                 latitude: 45.25,
                 longitude: 19.85
               )
               |> Ecto.Changeset.check_constraint(:route, name: :groups_route_check)
               |> Repo.update()

      assert changeset.errors[:route]
    end
  end

  describe "where a route is" do
    setup %{owner: owner} do
      public = %{"is_public" => true}
      city = area_group!(owner, square(@ns, 0.2), public)
      # A quarter in the city's east, and one in its north the route misses.
      east = area_group!(owner, square({45.25, 19.97}, 0.02), public)
      north = area_group!(owner, square({45.4, 19.85}, 0.02), public)
      closed = area_group!(owner, square({45.25, 19.85}, 0.05), %{})
      # From west of the city, through it and the eastern quarter.
      route = route_group!(owner, across(45.25, 19.5, 19.98), public)

      %{city: city, east: east, north: north, closed: closed, route: route}
    end

    test "a route lies in the areas it passes through, smallest first, though it starts outside",
         ctx do
      assert GroupAreas.containing(ctx.outsider, ctx.route) |> Enum.map(& &1.id) ==
               [ctx.east.id, ctx.city.id]

      # Its pin alone lies in none of them.
      assert GroupAreas.areas_at(ctx.outsider, ctx.route.latitude, ctx.route.longitude) == []

      # A member of the closed area sees it too.
      assert ctx.closed.id in Enum.map(GroupAreas.containing(ctx.owner, ctx.route), & &1.id)
    end

    test "a route not yet saved finds the same areas", ctx do
      draft = route!(across(45.25, 19.5, 19.98))

      assert GroupAreas.areas_along(ctx.outsider, draft) |> Enum.map(& &1.id) ==
               [ctx.east.id, ctx.city.id]

      assert GroupAreas.areas_along(ctx.outsider, draft, except: ctx.east.id, limit: 1)
             |> Enum.map(& &1.id) == [ctx.city.id]
    end

    test "each group knows what kind of place it has", ctx do
      assert GroupAreas.place_kind(ctx.route) |> elem(0) == :route
      assert GroupAreas.place_kind(ctx.city) |> elem(0) == :area

      point = group_with_members!(ctx.owner, [], %{"latitude" => 45.25, "longitude" => 19.85})
      assert GroupAreas.place_kind(point) == :point
      assert GroupAreas.place_kind(group_with_members!(ctx.owner, [])) == :none
    end

    test "a map gets the line of a route, simplified, and a short loop stays", ctx do
      loop =
        route_group!(
          ctx.owner,
          line([[19.85, 45.25], [19.852, 45.25], [19.852, 45.252], [19.85, 45.25]]),
          %{"is_public" => true}
        )

      shapes = GroupAreas.shapes(ctx.outsider, [ctx.route.id, loop.id, ctx.city.id], 6)

      by_id = Map.new(shapes, &{&1.id, Jason.decode!(&1.geojson)})
      assert %{"type" => "MultiLineString", "coordinates" => [[_ | _] | _]} = by_id[ctx.route.id]
      assert %{"type" => "MultiLineString", "coordinates" => [[_, _ | _]]} = by_id[loop.id]
      assert %{"type" => "MultiPolygon"} = by_id[ctx.city.id]

      # The start stays where the pin is.
      [[[lng, lat] | _]] = by_id[ctx.route.id]["coordinates"]
      assert {lat, lng} == {45.25, 19.5}
    end
  end
end
