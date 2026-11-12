defmodule PotokIde.Social.GuestVisibilityTest do
  @moduledoc """
  What a guest sees through an app of a group that opened its description to
  guests: nil in place of the viewer, and only the public plain groups.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.Visibility

  @serbia [18.8, 41.8, 23.1, 46.2]

  setup do
    {_account, owner} = account_with_profile!("gv-owner")

    parent = group!(owner, Social.get_root_group!(), "gv-parent", %{"is_public" => true})

    open =
      group!(owner, parent, "gv-open", %{
        "is_public" => true,
        "latitude" => 44.8,
        "longitude" => 20.4
      })

    closed =
      group!(owner, parent, "gv-closed", %{
        "is_public" => false,
        "latitude" => 44.81,
        "longitude" => 20.41
      })

    below_closed = group!(owner, closed, "gv-below-closed", %{"is_public" => true})

    {:ok, value} = Social.create_value(owner, parent, %{"content" => "start"})

    {:ok, thread} =
      Social.get_or_create_value_thread(owner, parent, value, %{"name" => "gv-thread"})

    %{
      owner: owner,
      parent: parent,
      open: open,
      closed: closed,
      below_closed: below_closed,
      thread: thread
    }
  end

  defp group!(owner, parent, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  test "the plain groups of a guest are the public ones", ctx do
    ids = Visibility.plain_groups(nil) |> select([g], g.id) |> Repo.all() |> MapSet.new()

    assert ctx.parent.id in ids
    assert ctx.open.id in ids
    assert ctx.below_closed.id in ids
    refute ctx.closed.id in ids
    refute ctx.thread.id in ids
    refute Social.root_group_id() in ids
  end

  test "a guest sees a public group and nothing else", ctx do
    assert Social.get_visible_group(nil, ctx.open.id).id == ctx.open.id
    assert Social.get_visible_group(nil, ctx.closed.id) == nil
    assert Social.get_visible_group(nil, ctx.thread.id) == nil
    assert Social.get_visible_group(nil, Social.root_group_id()) == nil
  end

  test "the sub-groups a guest finds are public, one level or two", ctx do
    assert Social.get_visible_child_group(ctx.parent, nil, ctx.open.id).id == ctx.open.id
    assert Social.get_visible_child_group(ctx.parent, nil, ctx.closed.id) == nil
    assert Social.get_visible_child_group_by_name(ctx.parent, nil, "gv-open").id == ctx.open.id
    assert Social.get_visible_child_group_by_name(ctx.parent, nil, "gv-closed") == nil

    # Public, but under a group the guest cannot see.
    assert Social.get_visible_grandchild_group(ctx.parent, nil, ctx.below_closed.id) == nil

    {groups, false} = Social.list_visible_child_groups_newest_first(ctx.parent, nil, limit: 10)
    assert Enum.map(groups, & &1.id) == [ctx.open.id]
  end

  test "a map app shows a guest its public places only", ctx do
    {places, false} = Social.list_visible_placed_children(ctx.parent, nil, 10)
    assert Enum.map(places, & &1.id) == [ctx.open.id]

    assert Social.placed_children_more_than?(ctx.parent, nil, 0)
    refute Social.placed_children_more_than?(ctx.parent, nil, 1)
    assert {:ok, [{_pin, 1}]} = Social.count_child_places_by_pin(ctx.parent, nil)

    filters = %{parent_id: ctx.parent.id}

    {:ok, view} = Social.list_map_cells(nil, filters, @serbia, 6)
    assert view.total == 1

    {:ok, %{extent: %{count: 1}}} = Social.load_map(nil, filters, nil)

    {:ok, {spot, false}} = Social.list_map_spot(nil, filters, [[44.0, 20.0], [45.0, 21.0]], 10)
    assert Enum.map(spot, & &1.id) == [ctx.open.id]
  end

  test "a guest never reads the root's map", _ctx do
    assert_raise FunctionClauseError, fn -> Social.list_map_cells(nil, %{}, @serbia, 6) end
    assert_raise FunctionClauseError, fn -> Social.load_map(nil, %{}, nil) end
  end
end
