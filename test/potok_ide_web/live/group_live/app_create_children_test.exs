defmodule PotokIdeWeb.GroupLive.AppCreateChildrenTest do
  @moduledoc """
  `create_children`: an app brings in many sub-groups at once, such as the rows
  of an open dataset, each with a place, a pin and its own key, all or none,
  for one write. A key that is there already makes no second group, so a call
  that timed out can be sent again.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group

  setup do
    {owner_account, owner} = account_with_profile!("app-batch-owner")
    {member_account, member} = account_with_profile!("app-batch-member")

    {:ok, parent} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "app-batch-parent",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    {:ok, app} =
      Social.create_group(owner, parent, %{
        "name" => "Nezgode 2025",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "uses_api" => true
      })

    add_member!(owner, app, member)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      app: app
    }
  end

  defp open_app(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp call(view, method, params) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  defp accident(id, extra \\ %{}) do
    Map.merge(
      %{
        "key" => "mup:#{id}",
        "name" => "Povređeni · Barajevo · 05.01.2025. 18:50",
        "description" => "## Saobraćajna nezgoda\n\nID nezgode: #{id}",
        "description_format" => "markdown",
        "lat" => 44.6192154,
        "lng" => 20.366175,
        "pin" => "warning",
        "is_public" => true,
        "inherits_members" => false
      },
      extra
    )
  end

  defp children_of(app) do
    from(g in Group, where: g.parent_id == ^app.id, order_by: g.id) |> Repo.all()
  end

  test "makes the children in order, with their places, pins and keys", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    call(view, "create_children", %{
      "children" => [
        accident(1),
        accident(2, %{"pin" => "problem"}),
        accident(3, %{"key" => nil})
      ]
    })

    assert_reply(view, %{ok: true, groups: [first, second, third]})
    assert %{key: "mup:1", created: true} = first
    assert %{key: "mup:2", created: true} = second
    assert %{key: nil, created: true} = third

    [one, two, three] = children_of(ctx.app)
    assert Enum.map([one, two, three], & &1.id) == [first.id, second.id, third.id]

    assert one.external_key == "mup:1"
    assert one.latitude == 44.619215
    assert one.longitude == 20.366175
    assert one.pin_icon == "warning"
    assert one.is_public
    refute one.inherits_members
    assert one.description =~ "ID nezgode: 1"
    assert one.creator_id == ctx.owner.id
    assert two.pin_icon == "problem"
    assert three.external_key == nil

    assert Social.member_of_group?(ctx.owner, one)
  end

  test "a key that is there already makes no second group", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    call(view, "create_children", %{"children" => [accident(1), accident(2)]})
    assert_reply(view, %{ok: true, groups: [%{id: one}, %{id: two}]})

    call(view, "create_children", %{"children" => [accident(2), accident(3), accident(1)]})

    assert_reply(view, %{
      ok: true,
      groups: [
        %{id: ^two, key: "mup:2", created: false},
        %{id: three, key: "mup:3", created: true},
        %{id: ^one, key: "mup:1", created: false}
      ]
    })

    assert length(children_of(ctx.app)) == 3
    assert three not in [one, two]
  end

  test "the same key under another group is another group", ctx do
    {:ok, other} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "Nezgode 2024",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "uses_api" => true
      })

    view = open_app(build_conn(), ctx.owner_account, ctx.app)
    call(view, "create_children", %{"children" => [accident(1)]})
    assert_reply(view, %{ok: true, groups: [%{created: true}]})

    view = open_app(build_conn(), ctx.owner_account, other)
    call(view, "create_children", %{"children" => [accident(1)]})
    assert_reply(view, %{ok: true, groups: [%{created: true}]})
  end

  test "a child that cannot be saved saves none, and says which", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    for bad <- [
          %{"lat" => 91.0},
          %{"lat" => nil},
          %{"lng" => "20.3"},
          %{"name" => nil},
          %{"name" => ""},
          %{"name" => String.duplicate("x", 121)},
          %{"pin" => "rocket"},
          %{"picture" => "data:image/png;base64,iVBORw0KGgo="},
          %{"key" => ""},
          %{"key" => String.duplicate("k", 65)},
          %{"key" => "mup:\n1"},
          %{"key" => 17},
          %{"key" => "mup:1"}
        ] do
      call(view, "create_children", %{
        "children" => [accident(1), accident(2), accident(3, bad)]
      })

      assert_reply(view, %{ok: false, error: "invalid_group", index: 2, message: message})
      assert is_binary(message)
    end

    call(view, "create_children", %{"children" => ["not a child"]})
    assert_reply(view, %{ok: false, error: "invalid_group", index: 0})

    assert children_of(ctx.app) == []
  end

  test "from 1 to 100 at a time", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    call(view, "create_children", %{"children" => []})
    assert_reply(view, %{ok: false, error: "too_large"})

    call(view, "create_children", %{"children" => Enum.map(1..101, &accident/1)})
    assert_reply(view, %{ok: false, error: "too_large"})

    call(view, "create_children", %{"children" => "many"})
    assert_reply(view, %{ok: false, error: "invalid_group"})

    call(view, "create_children", %{
      "children" => [accident(1)],
      "on_existing" => "update"
    })

    assert_reply(view, %{ok: false, error: "invalid_group"})

    call(view, "create_children", %{"children" => Enum.map(1..100, &accident/1)})
    assert_reply(view, %{ok: true, groups: groups})
    assert length(groups) == 100
  end

  test "only for a viewer who may edit the app's group and make sub-groups", ctx do
    view = open_app(build_conn(), ctx.member_account, ctx.app)
    call(view, "create_children", %{"children" => [accident(1)]})
    assert_reply(view, %{ok: false, error: "forbidden"})

    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.app)
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.app, %{"name" => "urednik"})

    {:ok, _role} =
      Social.set_group_role_permission(ctx.owner, ctx.app, role.key, :edit_group, :allow)

    {:ok, _role} =
      Social.set_group_role_permission(
        ctx.owner,
        ctx.app,
        "everyone",
        :create_subgroups,
        :neutral
      )

    {:ok, _assignment} =
      Social.assign_group_member_role(ctx.owner, ctx.app, ctx.member.id, role.key)

    view = open_app(build_conn(), ctx.member_account, ctx.app)
    call(view, "create_children", %{"children" => [accident(1)]})
    assert_reply(view, %{ok: false, error: "forbidden"})

    assert children_of(ctx.app) == []
  end

  test "one call is one write of the app's limit", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    replies =
      for batch <- 1..60 do
        call(view, "create_children", %{
          "children" => [accident(batch * 10), accident(batch * 10 + 1)]
        })

        assert_reply(view, reply)
        reply
      end

    made = Enum.count(replies, &match?(%{ok: true}, &1))
    assert Enum.any?(replies, &match?(%{ok: false, error: "rate_limited"}, &1))
    # Each call that got through made both of its children, on one write.
    assert made >= 30
    assert length(children_of(ctx.app)) == 2 * made
  end

  test "the parent's pages hear of the call once, the creator of no records", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)

    Phoenix.PubSub.subscribe(PotokIde.PubSub, "groups:#{ctx.app.id}")
    Phoenix.PubSub.subscribe(PotokIde.PubSub, "profiles:#{ctx.owner.id}")

    call(view, "create_children", %{"children" => Enum.map(1..5, &accident/1)})
    assert_reply(view, %{ok: true, groups: [%{id: first} | _rest]})

    app_id = ctx.app.id

    assert_received {:child_group_changed, ^app_id,
                     %{id: ^first, change: :created, public?: true}}

    refute_received {:child_group_changed, _group_id, _child}
    refute_received {:group_membership_changed, _profile_id, _group_id, _change}

    # A group without a key is an ordinary one, followed as any other.
    call(view, "create_children", %{"children" => [accident(6, %{"key" => nil})]})
    assert_reply(view, %{ok: true, groups: [%{id: plain}]})
    owner_id = ctx.owner.id
    assert_received {:group_membership_changed, ^owner_id, ^plain, :added}
  end

  test "records are not followed for unread, and keep their key", ctx do
    view = open_app(build_conn(), ctx.owner_account, ctx.app)
    call(view, "create_children", %{"children" => [accident(1), accident(2, %{"key" => nil})]})
    assert_reply(view, %{ok: true, groups: [%{id: record}, %{id: plain}]})

    followed = Social.member_group_ids(ctx.owner)
    refute record in followed
    assert plain in followed
    refute record in Social.nav_counts(ctx.owner).member_group_ids

    call(view, "update_child", %{"id" => record, "name" => "renamed", "external_key" => "other"})
    assert_reply(view, %{ok: true, group: %{key: "mup:1", name: "renamed"}})

    {:ok, _group} =
      Social.update_group(ctx.owner, Repo.get!(Group, record), %{"external_key" => "x"})

    assert Repo.get!(Group, record).external_key == "mup:1"
  end
end
