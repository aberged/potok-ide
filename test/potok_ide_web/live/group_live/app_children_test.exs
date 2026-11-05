defmodule PotokIdeWeb.GroupLive.AppChildrenTest do
  @moduledoc """
  What an app does with the groups right under its own, the way FeedCreator
  keeps `.feed`: it works in the viewer's name, so only for a viewer who may
  edit the app's group.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group}

  @picture "data:image/png;base64,iVBORw0KGgo="

  setup do
    {owner_account, owner} = account_with_profile!("app-kids-owner")
    {member_account, member} = account_with_profile!("app-kids-member")
    {visitor_account, visitor} = account_with_profile!("app-kids-visitor")

    {:ok, parent} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "app-kids-parent",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    add_member!(owner, parent, member)

    feed =
      child!(owner, parent, ".feed", %{
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "inherits_members" => true,
        "uses_api" => true
      })

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      visitor: visitor,
      parent: parent,
      feed: feed
    }
  end

  defp child!(owner, parent, name, attrs \\ %{}) do
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

  defp open_app(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp call(view, method, params \\ %{}) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  defp names(view) do
    assert_reply(view, %{ok: true, groups: groups})
    Enum.map(groups, & &1.name)
  end

  defp editor!(ctx, permissions) do
    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.feed)
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.feed, %{"name" => "urednik"})

    for permission <- permissions do
      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.feed, role.key, permission, :allow)
    end

    {:ok, _assignment} =
      Social.assign_group_member_role(ctx.owner, ctx.feed, ctx.member.id, role.key)

    role
  end

  # What the guide asks of `.feed`: creating sub-groups goes through a role.
  defp take_creating_from_everyone!(ctx) do
    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.feed)

    {:ok, _role} =
      Social.set_group_role_permission(
        ctx.owner,
        ctx.feed,
        "everyone",
        :create_subgroups,
        :neutral
      )
  end

  defp age!(group, days) do
    time = DateTime.utc_now(:second) |> DateTime.add(-days, :day)
    from(g in Group, where: g.id == ^group.id) |> Repo.update_all(set: [inserted_at: time])
  end

  describe "get_group" do
    test "says where the app stands and what the viewer may do", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "get_group")

      assert_reply(view, %{ok: true, group: group})
      assert group.id == ctx.feed.id
      assert group.name == ".feed"
      assert group.is_public
      assert group.inherits_members
      assert group.can_manage_children
      assert group.can_create_children

      assert group.parent == %{
               id: ctx.parent.id,
               name: "app-kids-parent",
               is_public: true,
               uses_api: false
             }
    end

    test "a member who may not edit the group manages nothing", ctx do
      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "get_group")

      assert_reply(view, %{ok: true, group: group})
      refute group.can_manage_children
      refute group.can_create_children
    end

    test "editing the group without creating sub-groups manages what is there", ctx do
      take_creating_from_everyone!(ctx)

      {:ok, role} = Social.create_group_role(ctx.owner, ctx.feed, %{"name" => "urednik"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.feed, role.key, :edit_group, :allow)

      {:ok, _assignment} =
        Social.assign_group_member_role(ctx.owner, ctx.feed, ctx.member.id, role.key)

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "get_group")

      assert_reply(view, %{ok: true, group: group})
      assert group.can_manage_children
      refute group.can_create_children
    end

    test "tells whether every member can add a group by hand", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)
      call(view, "get_group")
      assert_reply(view, %{ok: true, group: %{everyone_creates_subgroups: true}})

      take_creating_from_everyone!(ctx)

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)
      call(view, "get_group")
      assert_reply(view, %{ok: true, group: %{everyone_creates_subgroups: false}})
    end

    test "does not name a parent the viewer cannot see", ctx do
      {:ok, _parent} = Social.update_group(ctx.owner, ctx.parent, %{"is_public" => "false"})

      view = open_app(ctx.conn, ctx.visitor_account, ctx.feed)

      call(view, "get_group")

      assert_reply(view, %{ok: true, group: %{parent: nil}})
    end
  end

  describe "the app works in the viewer's name" do
    setup ctx do
      %{story: child!(ctx.owner, ctx.feed, "story", %{"is_public" => true})}
    end

    test "only for a viewer who may edit the app's group", ctx do
      calls = [
        {"list_children", %{}},
        {"get_child", %{"id" => ctx.story.id}},
        {"create_child", %{"name" => "written by the app"}},
        {"update_child", %{"id" => ctx.story.id, "name" => "renamed by the app"}},
        {"withdraw_child", %{"id" => ctx.story.id}},
        {"preview_description", %{"description" => "text"}}
      ]

      for account <- [ctx.member_account, ctx.visitor_account],
          {method, params} <- calls do
        view = open_app(ctx.conn, account, ctx.feed)

        call(view, method, params)

        assert_reply(view, %{ok: false, error: "forbidden"})
      end

      story = Repo.get!(Group, ctx.story.id)
      assert story.name == "story"
      assert story.is_public
      assert [%{name: "story"}] = Social.list_child_groups(ctx.feed)
    end

    test "not for a member whose own sub-group the app could reach", ctx do
      own = child!(ctx.member, ctx.feed, "the member's own", %{"description" => "private text"})

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "update_child", %{"id" => own.id, "is_public" => true})
      assert_reply(view, %{ok: false, error: "forbidden"})

      call(view, "get_child", %{"id" => own.id})
      assert_reply(view, %{ok: false, error: "forbidden"})

      refute Repo.get!(Group, own.id).is_public
    end

    test "a role that may edit the group passes", ctx do
      editor!(ctx, [:edit_group, :create_subgroups])

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)
      call(view, "create_child", %{"name" => "from an editor"})

      assert_reply(view, %{ok: true, group: %{name: "from an editor"}})
    end

    test "a call from an app no longer on screen is refused", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      render_hook(view, "app_api", %{
        "method" => "create_child",
        "params" => %{"name" => "stale"},
        "app_id" => "12345"
      })

      assert_reply(view, %{ok: false, error: "stale_app"})
      refute Enum.any?(Social.list_child_groups(ctx.feed), &(&1.name == "stale"))
    end

    test "writes share the app's limit", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      replies =
        for _call <- 1..60 do
          call(view, "preview_description", %{"description" => "text"})
          assert_reply(view, reply)
          reply
        end

      assert Enum.any?(replies, &match?(%{ok: false, error: "rate_limited"}, &1))
    end
  end

  describe "list_children" do
    test "lists the group's own sub-groups, newest first, page by page", ctx do
      for name <- ~w(first second third) do
        child!(ctx.owner, ctx.feed, name, %{"is_public" => true})
      end

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children", %{"limit" => 2})
      assert_reply(view, %{ok: true, groups: [_third, second], has_more: true})

      call(view, "list_children", %{"limit" => 2, "before_id" => second.id})
      assert names(view) == ~w(first)
    end

    test "says what a list of posts needs", ctx do
      story =
        child!(ctx.owner, ctx.feed, "story", %{
          "description" => "**bold**",
          "is_public" => true,
          "inherits_members" => true
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children")

      assert_reply(view, %{ok: true, groups: [card]})
      assert card.id == story.id
      assert card.description_html =~ "<strong>bold</strong>"
      assert card.is_public
      assert card.inherits_members
      assert card.creator_id == ctx.owner.id
      assert card.published_at == nil
    end

    test "leaves out threads, what the viewer cannot see and what is further down", ctx do
      shown = child!(ctx.owner, ctx.feed, "shown", %{"is_public" => true})
      child!(ctx.owner, shown, "below a story", %{"is_public" => true})
      child!(ctx.member, ctx.feed, "closed, of someone else")

      {:ok, value} = Social.create_value(ctx.owner, ctx.feed, %{"content" => "hello"})

      {:ok, _thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.feed, value, %{"name" => "t"})

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children")

      assert names(view) == ~w(shown)
    end
  end

  describe "get_child" do
    test "gives the source to who may change it", ctx do
      source = "<!--potok-post {}--><p style=\"color: #111827;\">text</p>"

      story =
        child!(ctx.owner, ctx.feed, "story", %{
          "description" => source,
          "description_format" => :html
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "get_child", %{"id" => story.id})

      assert_reply(view, %{ok: true, group: child})
      assert child.description == source
      assert child.description_format == "html"
      assert child.can_edit
      assert child.member_count == 1
      assert child.updated_at
      refute child.description_html =~ "potok-post"
    end

    test "keeps the source of a group the viewer may not change", ctx do
      editor!(ctx, [:edit_group])
      story = child!(ctx.owner, ctx.feed, "someone else's", %{"is_public" => true})

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "get_child", %{"id" => story.id})

      assert_reply(view, %{ok: true, group: %{description: nil, can_edit: false}})
    end

    test "never gives the code of a group that is an app", ctx do
      story =
        child!(ctx.owner, ctx.feed, "an app", %{
          "description" => "<script>secret()</script>",
          "description_format" => :html,
          "uses_api" => true
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "get_child", %{"id" => story.id})

      assert_reply(view, %{ok: true, group: %{description: nil, can_edit: false, uses_api: true}})
    end

    test "reaches only the group's own sub-groups", ctx do
      story = child!(ctx.owner, ctx.feed, "story", %{"is_public" => true})
      deep = child!(ctx.owner, story, "below a story", %{"is_public" => true})
      sibling = child!(ctx.owner, ctx.parent, "next to the app", %{"is_public" => true})

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      for id <- [deep.id, sibling.id, ctx.parent.id, ctx.feed.id, "nope", nil] do
        call(view, "get_child", %{"id" => id})
        assert_reply(view, %{ok: false, error: "not_found"})
      end
    end
  end

  describe "create_child" do
    test "makes a closed group under the app's, with the viewer as its admin", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "create_child", %{
        "name" => "story",
        "description" => "<p>text</p>",
        "description_format" => "html"
      })

      assert_reply(view, %{ok: true, group: created})

      group = Repo.get!(Group, created.id)
      assert group.parent_id == ctx.feed.id
      assert group.creator_id == ctx.owner.id
      assert group.description == "<p>text</p>"
      assert group.description_format == :html
      assert Group.closed?(group)
      assert Access.for_profile(ctx.owner, group).admin?
      assert created.can_edit
      assert created.description == "<p>text</p>"
      assert created.member_count == 1
    end

    test "an inheriting group holds the members of the app's group at once", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "create_child", %{"name" => "story", "inherits_members" => true})

      assert_reply(view, %{ok: true, group: %{member_count: 2} = created})
      assert Social.member_of_group?(ctx.member, Repo.get!(Group, created.id))
    end

    test "keeps a picture", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "create_child", %{"name" => "story", "picture" => @picture})

      assert_reply(view, %{ok: true, group: %{id: id, picture_url: url}})
      assert url =~ "/avatar/group/#{id}"
      assert Social.get_group_avatar_source(id).picture_url == @picture
    end

    test "sets nothing outside its fields", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.feed, %{"content" => "hello"})
      outside = child!(ctx.owner, ctx.parent, "elsewhere")

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "create_child", %{
        "name" => "story",
        "uses_api" => true,
        "is_root" => true,
        "is_direct" => true,
        "is_root_public" => true,
        "parent_id" => outside.id,
        "creator_id" => ctx.member.id,
        "parent_value_id" => value.id,
        "published_at" => "2020-01-01T00:00:00Z"
      })

      assert_reply(view, %{ok: true, group: %{id: id}})

      group = Repo.get!(Group, id)
      refute group.uses_api
      refute group.is_root
      refute group.is_direct
      refute group.is_root_public
      refute group.is_public
      assert group.parent_id == ctx.feed.id
      assert group.creator_id == ctx.owner.id
      assert group.parent_value_id == nil
      assert group.published_at == nil
    end

    test "refuses a name it cannot keep", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      for name <- ["", String.duplicate("x", 121), nil] do
        call(view, "create_child", %{"name" => name})
        assert_reply(view, %{ok: false, error: "invalid_group", message: message})
        assert is_binary(message)
      end
    end

    test "needs the permission to create sub-groups as well", ctx do
      take_creating_from_everyone!(ctx)

      {:ok, role} = Social.create_group_role(ctx.owner, ctx.feed, %{"name" => "urednik"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.feed, role.key, :edit_group, :allow)

      {:ok, _assignment} =
        Social.assign_group_member_role(ctx.owner, ctx.feed, ctx.member.id, role.key)

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "create_child", %{"name" => "story"})

      assert_reply(view, %{ok: false, error: "forbidden"})
    end
  end

  describe "update_child" do
    setup ctx do
      %{story: child!(ctx.owner, ctx.feed, "story")}
    end

    test "changes what it is given and leaves the rest", ctx do
      {:ok, story} =
        Social.update_group(ctx.owner, ctx.story, %{
          "description" => "kept",
          "group_picture_url" => @picture
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => story.id, "name" => "renamed", "is_public" => true})

      assert_reply(view, %{ok: true, group: %{name: "renamed", description: "kept"}})

      updated = Repo.get!(Group, story.id)
      assert updated.is_public
      assert Social.get_group_avatar_source(story.id).picture_url == @picture
    end

    test "an empty picture takes the group's picture away", ctx do
      {:ok, story} = Social.update_group(ctx.owner, ctx.story, %{"group_picture_url" => @picture})

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => story.id, "picture" => ""})

      assert_reply(view, %{ok: true})
      assert Social.get_group_avatar_source(story.id).picture_url == nil
    end

    test "turning inheritance on brings the members in", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => ctx.story.id, "inherits_members" => true})

      assert_reply(view, %{ok: true, group: %{inherits_members: true, member_count: 2}})
    end

    test "an admin of the app's group edits what inherits that role", ctx do
      story =
        child!(ctx.member, ctx.feed, "by a member", %{
          "is_public" => true,
          "inherits_members" => true
        })

      assert Access.for_profile(ctx.owner, story).admin?

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => story.id, "name" => "corrected"})

      assert_reply(view, %{ok: true, group: %{name: "corrected"}})
    end

    test "an editor cannot change someone else's closed or plain group", ctx do
      editor!(ctx, [:edit_group])
      public = child!(ctx.owner, ctx.feed, "public, no inheritance", %{"is_public" => true})

      view = open_app(ctx.conn, ctx.member_account, ctx.feed)

      call(view, "update_child", %{"id" => public.id, "name" => "taken"})
      assert_reply(view, %{ok: false, error: "forbidden"})

      call(view, "update_child", %{"id" => ctx.story.id, "name" => "taken"})
      assert_reply(view, %{ok: false, error: "not_found"})
    end

    test "never touches a group that is an app", ctx do
      app =
        child!(ctx.owner, ctx.feed, "an app", %{
          "description" => "<p>code</p>",
          "description_format" => :html,
          "uses_api" => true
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => app.id, "description" => "<p>new code</p>"})
      assert_reply(view, %{ok: false, error: "forbidden"})

      call(view, "withdraw_child", %{"id" => app.id})
      assert_reply(view, %{ok: false, error: "forbidden"})

      assert Repo.get!(Group, app.id).description == "<p>code</p>"
    end

    test "cannot turn a group into an app", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{
        "id" => ctx.story.id,
        "uses_api" => true,
        "description" => "<script>run()</script>",
        "description_format" => "html"
      })

      assert_reply(view, %{ok: true})
      refute Repo.get!(Group, ctx.story.id).uses_api
    end

    test "refuses what it cannot keep", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => ctx.story.id, "name" => ""})

      assert_reply(view, %{ok: false, error: "invalid_group"})
    end

    test "reaches only the group's own sub-groups", ctx do
      outside = child!(ctx.owner, ctx.parent, "next to the app")
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "update_child", %{"id" => outside.id, "name" => "taken"})

      assert_reply(view, %{ok: false, error: "not_found"})
      assert Repo.get!(Group, outside.id).name == "next to the app"
    end
  end

  describe "withdraw_child" do
    test "takes the group back from its readers", ctx do
      story =
        child!(ctx.owner, ctx.feed, "story", %{"is_public" => true, "inherits_members" => true})

      assert Social.member_of_group?(ctx.member, story)

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "withdraw_child", %{"id" => story.id})

      assert_reply(view, %{
        ok: true,
        group: %{is_public: false, inherits_members: false, member_count: 1}
      })

      assert Group.closed?(Repo.get!(Group, story.id))
      refute Social.member_of_group?(ctx.member, story)

      assert {[], false} =
               Social.list_visible_child_groups_newest_first(ctx.feed, ctx.member, limit: 5)
    end

    test "list_children takes a period like list_subgroups, and refuses a bad one", ctx do
      child!(ctx.owner, ctx.feed, "story")
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children", %{"to" => "2020-01-01T00:00:00Z"})
      assert_reply(view, %{ok: true, groups: []})

      call(view, "list_children", %{"from" => "2020-01-01T00:00:00Z"})
      assert_reply(view, %{ok: true, groups: [%{name: "story"}]})

      call(view, "list_children", %{"from" => "yesterday"})
      assert_reply(view, %{ok: false, error: "invalid_date"})
    end

    test "publishing again lets them back in", ctx do
      story = child!(ctx.owner, ctx.feed, "story", %{"inherits_members" => true})
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "withdraw_child", %{"id" => story.id})
      assert_reply(view, %{ok: true})

      call(view, "update_child", %{"id" => story.id, "inherits_members" => true})
      assert_reply(view, %{ok: true, group: %{member_count: 2}})
    end
  end

  describe "preview_description" do
    test "shows what a feed will get", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "preview_description", %{
        "description" =>
          ~s|<!--potok-post {"v":1}--><h1 class="x" style="color: #1e3a8a; position: fixed;">Naslov</h1><script>alert(1)</script>|,
        "description_format" => "html"
      })

      assert_reply(view, %{ok: true, html: html})
      assert html =~ "Naslov"
      assert html =~ "color: #1e3a8a"
      refute html =~ "potok-post"
      refute html =~ "position"
      refute html =~ "class"
      refute html =~ "script"
    end

    test "renders markdown, the default format", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "preview_description", %{"description" => "**bold**"})

      assert_reply(view, %{ok: true, html: html})
      assert html =~ "<strong>bold</strong>"
    end

    test "gives nothing for an empty description", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "preview_description", %{"description" => "  "})

      assert_reply(view, %{ok: true, html: nil})
    end

    test "refuses a format it does not know", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "preview_description", %{"description" => "x", "description_format" => "pdf"})

      assert_reply(view, %{ok: false, error: "invalid_description"})
    end
  end

  describe "the order of a feed" do
    test "a draft comes first from the moment it opens up", ctx do
      draft = child!(ctx.owner, ctx.feed, "written on monday")
      age!(draft, 4)

      newer = child!(ctx.owner, ctx.feed, "published on tuesday", %{"inherits_members" => true})
      age!(newer, 3)

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children")
      assert names(view) == ["published on tuesday", "written on monday"]

      call(view, "update_child", %{"id" => draft.id, "inherits_members" => true})
      assert_reply(view, %{ok: true, group: %{published_at: published_at}})
      assert published_at

      call(view, "list_children")
      assert names(view) == ["written on monday", "published on tuesday"]
    end

    test "the app that reads a feed sees the same order", ctx do
      {:ok, _feed} =
        Social.update_group(ctx.owner, ctx.parent, %{
          "description" => "<p>app</p>",
          "uses_api" => "true"
        })

      draft = child!(ctx.owner, ctx.feed, "old draft")
      age!(draft, 4)

      newer = child!(ctx.owner, ctx.feed, "newer", %{"is_public" => true})
      age!(newer, 3)

      {:ok, _draft} = Social.update_group(ctx.owner, draft, %{"is_public" => "true"})

      view = open_app(ctx.conn, ctx.visitor_account, ctx.parent)

      call(view, "list_subgroups", %{"name" => ".feed"})

      assert names(view) == ["old draft", "newer"]
    end

    test "paging goes along the same order", ctx do
      draft = child!(ctx.owner, ctx.feed, "draft")
      age!(draft, 9)

      for {name, days} <- [{"a", 1}, {"b", 2}, {"c", 3}] do
        ctx.owner |> child!(ctx.feed, name, %{"is_public" => true}) |> age!(days)
      end

      {:ok, _draft} = Social.update_group(ctx.owner, draft, %{"is_public" => "true"})

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children", %{"limit" => 2})

      assert_reply(view, %{
        ok: true,
        groups: [%{name: "draft"}, %{name: "a"} = last],
        has_more: true
      })

      call(view, "list_children", %{"limit" => 2, "before_id" => last.id})
      assert_reply(view, %{ok: true, groups: [%{name: "b"}, %{name: "c"}], has_more: false})
    end

    test "a page goes on after the group it started from is gone", ctx do
      first = child!(ctx.owner, ctx.feed, "first", %{"is_public" => true})
      gone = child!(ctx.owner, ctx.feed, "gone", %{"is_public" => true})
      {:ok, _gone} = Social.delete_group(ctx.owner, gone)

      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "list_children", %{"before_id" => gone.id})

      assert_reply(view, %{ok: true, groups: [listed]})
      assert listed.id == first.id
    end
  end

  describe "open_group" do
    test "goes to a sub-group of the app's group", ctx do
      story = child!(ctx.owner, ctx.feed, "story", %{"is_public" => true})
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "open_group", %{"id" => story.id})

      assert_redirect(view, ~p"/groups/#{story.id}/values")
    end

    test "goes to a group's settings", ctx do
      story = child!(ctx.owner, ctx.feed, "story", %{"is_public" => true})
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "open_group", %{"id" => story.id, "tab" => "settings"})

      assert_redirect(view, ~p"/groups/#{story.id}/edit_group")
    end

    test "goes back up to the parent", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "open_group", %{"id" => ctx.parent.id, "tab" => "description"})

      assert_redirect(view, ~p"/groups/#{ctx.parent.id}/group_home")
    end

    test "not to a parent the viewer cannot see", ctx do
      {:ok, _parent} = Social.update_group(ctx.owner, ctx.parent, %{"is_public" => "false"})

      view = open_app(ctx.conn, ctx.visitor_account, ctx.feed)

      call(view, "open_group", %{"id" => ctx.parent.id})

      assert_reply(view, %{ok: false, error: "not_found"})
    end

    test "not to a closed sub-group of someone else", ctx do
      closed = child!(ctx.member, ctx.feed, "closed")
      view = open_app(ctx.conn, ctx.owner_account, ctx.feed)

      call(view, "open_group", %{"id" => closed.id})

      assert_reply(view, %{ok: false, error: "not_found"})
    end
  end
end
