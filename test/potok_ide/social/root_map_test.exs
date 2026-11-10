defmodule PotokIde.Social.RootMapTest do
  @moduledoc """
  The root's map (`Social.list_map_cells/4` and its company): every group with
  a place the profile sees, at any depth, narrowed like the root's sub-groups
  and by time, and gathered into clusters by the server.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group

  # Belgrade and Novi Sad, some 70 km apart.
  @bg {44.8125, 20.4612}
  @ns {45.2671, 19.8335}
  @serbia [18.8, 41.8, 23.1, 46.2]
  @world [-180, -85, 180, 85]

  setup do
    {_account, owner} = account_with_profile!("rootmap-owner")
    {_account, viewer} = account_with_profile!("rootmap-viewer")
    root = Social.get_root_group!()

    %{owner: owner, viewer: viewer, root: root}
  end

  defp group!(owner, parent, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => "rootmap-#{System.unique_integer([:positive])}",
            "description" => "",
            "description_format" => :markdown
          },
          attrs
        )
      )

    group
  end

  defp placed!(owner, parent, {lat, lng}, attrs \\ %{}),
    do: group!(owner, parent, Map.merge(%{"latitude" => lat, "longitude" => lng}, attrs))

  # Everything up close, where no two of these places share a cell.
  defp ids(profile, filters \\ %{}) do
    {:ok, cells} = Social.list_map_cells(profile, filters, @serbia, 18)
    [] = cells.clusters

    cells.places |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp set_times!(group, fields) do
    {1, _} = Repo.update_all(from(g in Group, where: g.id == ^group.id), set: fields)
  end

  describe "which groups" do
    test "are the profile's memberships at any depth, and public groups by the switch", ctx do
      %{owner: owner, viewer: viewer, root: root} = ctx

      mine = group_with_members!(owner, [viewer], %{"latitude" => 44.1, "longitude" => 20.1})
      deep = group_with_members!(owner, [viewer], %{parent: mine})
      {:ok, deep} = Social.update_group(owner, deep, %{"latitude" => 44.2, "longitude" => 20.2})

      # Public and the viewer is not in it, but in a group below it.
      way = placed!(owner, root, {44.3, 20.3}, %{"is_public" => true})
      _below = group_with_members!(owner, [viewer], %{parent: way})

      open = placed!(owner, root, {44.4, 20.4}, %{"is_public" => true})
      closed = placed!(owner, root, {44.5, 20.5})
      open_under_closed = placed!(owner, closed, {44.6, 20.6}, %{"is_public" => true})

      assert ids(viewer) == Enum.sort([mine.id, deep.id, way.id])

      assert ids(viewer, %{public?: true}) ==
               Enum.sort([mine.id, deep.id, way.id, open.id, open_under_closed.id])

      refute closed.id in ids(viewer, %{public?: true})
      assert closed.id in ids(owner)
    end

    test "leave out threads, direct conversations and groups without a place", ctx do
      %{owner: owner, viewer: viewer, root: root} = ctx

      chat = group_with_members!(owner, [viewer], %{"latitude" => 44.1, "longitude" => 20.1})
      _unplaced = group_with_members!(owner, [viewer])

      {:ok, value} =
        Social.create_value(owner, chat, %{"content" => "hi"})

      _thread =
        group!(owner, chat, %{
          "parent_value_id" => to_string(value.id),
          "latitude" => 44.2,
          "longitude" => 20.2
        })

      {:ok, direct} = Social.get_or_create_direct_group(owner, viewer)
      set_times!(direct, latitude: 44.3, longitude: 20.3)

      assert ids(viewer) == [chat.id]
      assert root.latitude == nil
    end
  end

  describe "the filters" do
    setup ctx do
      %{owner: owner, viewer: viewer} = ctx

      chat =
        group_with_members!(owner, [viewer], %{
          "name" => "Pekara Kod Mike",
          "latitude" => 44.1,
          "longitude" => 20.1
        })

      {:ok, %{group: poll}} =
        Social.create_group_from_preset(owner, ctx.root, "polls", %{
          "name" => "Glasanje",
          "is_public" => true
        })

      {:ok, poll} = Social.update_group(owner, poll, %{"latitude" => 44.2, "longitude" => 20.2})

      {:ok, %{group: own}} =
        Social.create_group_from_preset(viewer, ctx.root, "chat", %{"name" => "Moja grupa"})

      {:ok, own} = Social.update_group(viewer, own, %{"latitude" => 44.3, "longitude" => 20.3})

      %{chat: chat, poll: poll, own: own}
    end

    test "narrow by name, kind and relation", ctx do
      all = %{public?: true}

      assert ids(ctx.viewer, Map.put(all, :search, "pekara")) == [ctx.chat.id]
      assert ids(ctx.viewer, Map.put(all, :preset, "polls")) == [ctx.poll.id]
      assert ids(ctx.viewer, Map.put(all, :preset, "chat")) == [ctx.own.id]
      # The chat made by hand shows no kind.
      assert ids(ctx.viewer, Map.put(all, :preset, "none")) == [ctx.chat.id]
      assert ids(ctx.viewer, Map.put(all, :relation, "creator")) == [ctx.own.id]

      assert ids(ctx.viewer, Map.put(all, :relation, "member")) ==
               Enum.sort([ctx.chat.id, ctx.own.id])

      # Unknown keys narrow nothing.
      assert ids(ctx.viewer, Map.put(all, :preset, "bogus")) == ids(ctx.viewer, all)
    end

    test "narrow by the pins they show, any of those picked", ctx do
      all = %{public?: true}
      {:ok, chat} = Social.update_group(ctx.owner, ctx.chat, %{"pin_icon" => "food"})
      {:ok, poll} = Social.update_group(ctx.owner, ctx.poll, %{"pin_icon" => "event"})

      assert ids(ctx.viewer, Map.put(all, :pins, ["food"])) == [chat.id]

      assert ids(ctx.viewer, Map.put(all, :pins, ["food", "event"])) ==
               Enum.sort([chat.id, poll.id])

      # A group that shows its kind has no pin of these.
      assert ids(ctx.viewer, Map.put(all, :pins, ["shop"])) == []
      assert ids(ctx.viewer, Map.put(all, :pins, [])) == ids(ctx.viewer, all)

      assert {:ok, %{count: 1}} = Social.map_extent(ctx.viewer, Map.put(all, :pins, ["event"]))

      # Its kind's pin, and the group's picture.
      {:ok, own} = Social.update_group(ctx.viewer, ctx.own, %{"pin_icon" => "picture"})
      assert ids(ctx.viewer, Map.put(all, :pins, ["picture"])) == [own.id]
      assert ids(ctx.viewer, Map.put(all, :pins, ["kind"])) == []
      assert ids(ctx.viewer, Map.put(all, :pins, ["kind", "food"])) == [chat.id]
      {:ok, _} = Social.update_group(ctx.owner, poll, %{"pin_icon" => ""})
      assert ids(ctx.viewer, Map.put(all, :pins, ["kind"])) == [poll.id]
    end

    test "an app that fits no preset is a kind of its own", ctx do
      all = %{public?: true}

      {1, _} =
        Repo.update_all(from(g in Group, where: g.id == ^ctx.chat.id), set: [uses_api: true])

      assert ids(ctx.viewer, Map.put(all, :preset, "app")) == [ctx.chat.id]
      assert ids(ctx.viewer, Map.put(all, :preset, "none")) == []
    end

    test "narrow by when a group was made, or last written in", ctx do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      long_ago = DateTime.add(now, -90, :day)

      set_times!(ctx.chat, inserted_at: long_ago, last_value_at: DateTime.add(now, -1, :day))
      set_times!(ctx.poll, inserted_at: long_ago, published_at: DateTime.add(now, -2, :day))
      set_times!(ctx.own, inserted_at: DateTime.add(now, -3, :day), last_value_at: nil)

      week = %{public?: true, from: DateTime.add(now, -7, :day)}

      # Made, or opened up, this week.
      assert ids(ctx.viewer, week) == Enum.sort([ctx.poll.id, ctx.own.id])
      # Written in this week; a group never written in stays out.
      assert ids(ctx.viewer, Map.put(week, :time, :active)) == [ctx.chat.id]

      # `to` does not count in.
      between = %{public?: true, from: long_ago, to: DateTime.add(now, -3, :day)}
      assert ids(ctx.viewer, between) == [ctx.chat.id]
    end
  end

  describe "the cells" do
    test "gather groups that stand close at a low zoom and part them up close", ctx do
      %{owner: owner, viewer: viewer} = ctx

      [a, b, c] =
        for offset <- [0.0, 0.001, 0.002] do
          {lat, lng} = @bg
          group_with_members!(owner, [viewer], %{"latitude" => lat + offset, "longitude" => lng})
        end

      far =
        group_with_members!(owner, [viewer], %{
          "latitude" => elem(@ns, 0),
          "longitude" => elem(@ns, 1)
        })

      {:ok, wide} = Social.list_map_cells(viewer, %{}, @serbia, 7)

      assert wide.total == 4
      assert [%{count: 3, bounds: [[south, west], [north, east]]} = cluster] = wide.clusters
      assert_in_delta south, 44.8125, 0.0001
      assert_in_delta north, 44.8145, 0.0001
      assert west == east
      assert_in_delta cluster.lat, 44.8135, 0.0001
      assert Enum.map(wide.places, & &1.id) == [far.id]

      {:ok, close} = Social.list_map_cells(viewer, %{}, @serbia, 18)
      assert close.clusters == []

      assert close.places |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id, far.id])

      # Only what pins need is loaded.
      assert %Group{name: name, latitude: _, pin_icon: nil} = hd(close.places)
      assert is_binary(name)
    end

    test "keep to the box, across the antimeridian too", ctx do
      %{owner: owner, viewer: viewer} = ctx

      serbia = group_with_members!(owner, [viewer], %{"latitude" => 44.8, "longitude" => 20.4})
      fiji = group_with_members!(owner, [viewer], %{"latitude" => -17.7, "longitude" => 178.0})
      samoa = group_with_members!(owner, [viewer], %{"latitude" => -13.8, "longitude" => -171.8})

      in_box = fn bbox ->
        {:ok, cells} = Social.list_map_cells(viewer, %{}, bbox, 18)
        cells.places |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert in_box.(@serbia) == [serbia.id]
      # A view across the antimeridian has longitudes past 180.
      assert in_box.([170, -25, 195, -5]) == Enum.sort([fiji.id, samoa.id])
      assert in_box.([-190, -25, -165, -5]) == Enum.sort([fiji.id, samoa.id])
      # Wider than the world is the world.
      assert in_box.([-400, -85, 400, 85]) == Enum.sort([serbia.id, fiji.id, samoa.id])
      assert in_box.(@world) == Enum.sort([serbia.id, fiji.id, samoa.id])
    end
  end

  test "the extent counts every group the filters keep and the box around them", ctx do
    %{owner: owner, viewer: viewer} = ctx

    assert {:ok, %{count: 0, bounds: nil}} = Social.map_extent(viewer, %{})

    group_with_members!(owner, [viewer], %{"latitude" => 44.8, "longitude" => 20.4})
    group_with_members!(owner, [viewer], %{"latitude" => 45.2, "longitude" => 19.8})

    assert {:ok, %{count: 2, bounds: [[44.8, 19.8], [45.2, 20.4]]}} =
             Social.map_extent(viewer, %{})

    assert {:ok, %{count: 0}} = Social.map_extent(viewer, %{search: "nothing like it"})
  end

  test "a spot lists its groups by name, up to the limit", ctx do
    %{owner: owner, viewer: viewer} = ctx
    {lat, lng} = @bg

    for name <- ["Cvećara", "Apoteka", "Banka"] do
      group_with_members!(owner, [viewer], %{
        "name" => name,
        "latitude" => lat,
        "longitude" => lng
      })
    end

    group_with_members!(owner, [viewer], %{
      "name" => "Elsewhere",
      "latitude" => 45.0,
      "longitude" => 20.0
    })

    bounds = [[lat, lng], [lat, lng]]

    assert {:ok, {groups, false}} = Social.list_map_spot(viewer, %{}, bounds, 10)
    assert Enum.map(groups, & &1.name) == ["Apoteka", "Banka", "Cvećara"]

    assert {:ok, {[_, _], true}} = Social.list_map_spot(viewer, %{}, bounds, 2)
  end

  describe "the group a sheet opens" do
    test "is any group the profile sees under the root, a direct child elsewhere", ctx do
      %{owner: owner, viewer: viewer, root: root} = ctx

      parent = group_with_members!(owner, [viewer])
      child = group_with_members!(owner, [viewer], %{parent: parent})
      grandchild = group_with_members!(owner, [viewer], %{parent: child})
      closed = group!(owner, parent, %{})

      assert %Group{id: id} = Social.get_visible_group_below(root, viewer, grandchild.id)
      assert id == grandchild.id
      assert Social.get_visible_group_below(root, viewer, closed.id) == nil
      assert Social.get_visible_group_below(root, viewer, root.id) == nil

      assert %Group{} = Social.get_visible_group_below(parent, viewer, child.id)
      assert Social.get_visible_group_below(parent, viewer, grandchild.id) == nil
    end
  end
end
