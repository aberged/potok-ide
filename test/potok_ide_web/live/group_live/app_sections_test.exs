defmodule PotokIdeWeb.GroupLive.AppSectionsTest do
  @moduledoc """
  What a site keeps the way a feed keeps `.feed`, one level deeper: sections
  right under the app's group, made so that only editors add to them, and
  articles under those (`under`). Lists of them come short (`brief`), an
  address opens one wherever it stands (`get_subgroup`), drafts are shared
  by the editors' roles, and the site's settings are for whoever opens it.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, Group}

  setup do
    {owner_account, owner} = account_with_profile!("site-owner")
    {editor_account, editor} = account_with_profile!("site-editor")
    {second_account, second} = account_with_profile!("site-second")
    {member_account, member} = account_with_profile!("site-member")
    {outsider_account, outsider} = account_with_profile!("site-outsider")

    site =
      group!(owner, Social.get_root_group!(), "site-app", %{
        "description" => "<p>site</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true,
        "home_page" => :description
      })

    for profile <- [editor, second, member], do: add_member!(owner, site, profile)

    {:ok, _manifest} = Social.create_own_group_manifest(owner, site)
    {:ok, role} = Social.create_group_role(owner, site, %{"name" => "urednik"})
    {:ok, _role} = Social.set_group_role_permission(owner, site, role.key, :edit_group, :allow)

    for profile <- [editor, second] do
      {:ok, _assignment} = Social.assign_group_member_role(owner, site, profile.id, role.key)
    end

    %{
      owner_account: owner_account,
      owner: owner,
      editor_account: editor_account,
      editor: editor,
      second_account: second_account,
      second: second,
      member_account: member_account,
      member: member,
      outsider_account: outsider_account,
      outsider: outsider,
      site: site,
      role: role
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

  defp open_app(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp call(view, method, params \\ %{}) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
    assert_reply(view, reply)
    reply
  end

  defp section!(view, name) do
    assert %{ok: true, group: section} =
             call(view, "create_child", %{
               "name" => name,
               "is_public" => true,
               "inherits_members" => true,
               "editors_only" => true
             })

    section
  end

  describe "sections only editors add to" do
    test "an editor who is no admin writes an article into one; a member cannot add a group",
         ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.site)
      section = section!(view, "Vesti")

      editor_view = open_app(build_conn(), ctx.editor_account, ctx.site)

      assert %{ok: true, group: article} =
               call(editor_view, "create_child", %{
                 "under" => section.id,
                 "name" => "Prvi članak",
                 "description" => "<p>Tekst.</p>",
                 "description_format" => "html",
                 "is_public" => true,
                 "inherits_members" => true
               })

      assert article.parent_id == section.id

      section_group = Social.get_group!(section.id)
      refute Access.can?(ctx.member, section_group, :create_subgroups)
      assert Access.can?(ctx.editor, section_group, :create_subgroups)

      assert {:error, :not_permitted} =
               Social.create_group(ctx.member, section_group, %{
                 "name" => "Moja grupa",
                 "description" => "",
                 "description_format" => :markdown
               })
    end

    test "only who may edit the site writes there, whatever `under` says", ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.site)
      section = section!(view, "Vesti")

      member_view = open_app(build_conn(), ctx.member_account, ctx.site)

      assert %{ok: false, error: "forbidden"} =
               call(member_view, "create_child", %{"under" => section.id, "name" => "Nije moje"})

      assert %{ok: false, error: "forbidden"} =
               call(member_view, "list_children", %{"under" => section.id})
    end

    test "`under` never reaches a sub-group that is an app or holds the app's files", ctx do
      app_child =
        group!(ctx.owner, ctx.site, "Druga aplikacija", %{
          "description" => "<p>app</p>",
          "description_format" => :html,
          "uses_api" => true
        })

      view = open_app(ctx.conn, ctx.owner_account, ctx.site)

      assert %{ok: false, error: "not_found"} =
               call(view, "create_child", %{"under" => app_child.id, "name" => "Ne"})

      assert %{ok: true} = call(view, "save_config", %{"data" => %{}, "revision" => 0})
      assert %{ok: true} = call(view, "ensure_file_groups")
      [files_id | _] = Social.app_file_group_ids(ctx.site)

      assert %{ok: false, error: "not_found"} =
               call(view, "list_children", %{"under" => files_id})

      assert %{ok: false, error: "not_found"} =
               call(view, "create_child", %{"under" => 999_999_999, "name" => "Ne"})
    end
  end

  describe "articles under a section" do
    setup ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.site)
      section = section!(view, "Vesti")

      assert %{ok: true, group: article} =
               call(view, "create_child", %{
                 "under" => section.id,
                 "name" => "Članak",
                 "description" => "<!--potok-site {}-->\n<p>Dugačak tekst članka.</p>",
                 "description_format" => "html",
                 "is_public" => true,
                 "inherits_members" => true
               })

      %{view: view, section: section, article: article}
    end

    test "are read, changed and withdrawn through `under`, and only there", ctx do
      assert %{ok: true, groups: [listed]} =
               call(ctx.view, "list_children", %{"under" => ctx.section.id})

      assert listed.id == ctx.article.id

      assert %{ok: true, group: got} =
               call(ctx.view, "get_child", %{"id" => ctx.article.id, "under" => ctx.section.id})

      assert got.description =~ "Dugačak tekst"

      assert %{ok: false, error: "not_found"} =
               call(ctx.view, "get_child", %{"id" => ctx.article.id})

      assert %{ok: true, group: %{name: "Novo ime"}} =
               call(ctx.view, "update_child", %{
                 "id" => ctx.article.id,
                 "under" => ctx.section.id,
                 "name" => "Novo ime"
               })

      assert %{ok: true, group: withdrawn} =
               call(ctx.view, "withdraw_child", %{
                 "id" => ctx.article.id,
                 "under" => ctx.section.id
               })

      refute withdrawn.is_public
    end

    test "a save that started before someone else's is refused, with the group as it is now",
         ctx do
      assert %{ok: true, group: got} =
               call(ctx.view, "get_child", %{"id" => ctx.article.id, "under" => ctx.section.id})

      read_at = DateTime.to_iso8601(got.updated_at)

      later =
        ctx.article.id
        |> Social.get_group!()
        |> Ecto.Changeset.change(updated_at: DateTime.add(got.updated_at, 5))
        |> Repo.update!()

      assert %{ok: false, error: "conflict", group: current} =
               call(ctx.view, "update_child", %{
                 "id" => ctx.article.id,
                 "under" => ctx.section.id,
                 "name" => "Staro",
                 "updated_at" => read_at
               })

      assert current.updated_at == later.updated_at
      assert Social.get_group!(ctx.article.id).name == "Članak"

      assert %{ok: true, group: %{name: "Novo"}} =
               call(ctx.view, "update_child", %{
                 "id" => ctx.article.id,
                 "under" => ctx.section.id,
                 "name" => "Novo",
                 "updated_at" => DateTime.to_iso8601(later.updated_at)
               })
    end

    test "a list by the section's id comes brief: the card's text, not the page", ctx do
      assert %{ok: true, groups: [full]} =
               call(ctx.view, "list_subgroups", %{"id" => ctx.section.id})

      assert full.description_html =~ "Dugačak tekst"
      assert full.summary == nil

      assert %{ok: true, groups: [brief]} =
               call(ctx.view, "list_subgroups", %{"id" => ctx.section.id, "brief" => true})

      assert brief.description_html == nil
      assert brief.summary =~ "Dugačak tekst"
      refute brief.summary =~ "potok-site"
    end

    test "an address opens an article wherever it stands, and tells where", ctx do
      assert %{ok: true, group: got} = call(ctx.view, "get_subgroup", %{"id" => ctx.article.id})

      assert got.parent_id == ctx.section.id
      assert got.description_html =~ "Dugačak tekst"

      assert %{ok: true, group: %{parent_id: parent_id}} =
               call(ctx.view, "get_subgroup", %{"id" => ctx.section.id})

      assert parent_id == ctx.site.id

      assert %{ok: false, error: "not_found"} =
               call(ctx.view, "get_subgroup", %{"id" => ctx.site.id})
    end

    test "a card knows a picture of its own from initials, and the app the site's access", ctx do
      assert %{ok: true, groups: [plain]} =
               call(ctx.view, "list_subgroups", %{"id" => ctx.section.id})

      refute plain.has_picture

      assert %{ok: true} =
               call(ctx.view, "update_child", %{
                 "id" => ctx.article.id,
                 "under" => ctx.section.id,
                 "picture" => "data:image/png;base64,iVBORw0KGgo="
               })

      assert %{ok: true, groups: [pictured]} =
               call(ctx.view, "list_subgroups", %{"id" => ctx.section.id, "brief" => true})

      assert pictured.has_picture

      assert %{ok: true, group: %{for_guests: false, public_chat: false}} =
               call(ctx.view, "get_group")
    end

    test "turning guests on afterwards reaches what is there already, at one call", ctx do
      refute ctx.article.for_guests

      {:ok, _site} =
        Social.update_group(ctx.owner, ctx.site, %{"description_for_guests" => true})

      view = open_app(build_conn(), ctx.owner_account, ctx.site)

      assert %{ok: true, updated: 2, skipped: 0} = call(view, "apply_access_to_children")
      assert Social.get_group!(ctx.section.id).description_for_guests
      assert Social.get_group!(ctx.article.id).description_for_guests

      assert %{ok: true, updated: 0} = call(view, "apply_access_to_children")
    end
  end

  describe "drafts the editors share" do
    test "inheriting only the editors' role, a draft is seen by every editor and has no date",
         ctx do
      view = open_app(ctx.conn, ctx.owner_account, ctx.site)
      section = section!(view, "Vesti")

      editor_view = open_app(build_conn(), ctx.editor_account, ctx.site)

      assert %{ok: true, group: draft} =
               call(editor_view, "create_child", %{
                 "under" => section.id,
                 "name" => "Nacrt",
                 "is_public" => false,
                 "inherits_members" => true,
                 "inherit_role_keys" => [ctx.role.key]
               })

      assert draft.published_at == nil

      second_view = open_app(build_conn(), ctx.second_account, ctx.site)
      assert %{ok: true, group: _seen} = call(second_view, "get_subgroup", %{"id" => draft.id})

      assert %{ok: true, group: _changed} =
               call(second_view, "update_child", %{
                 "id" => draft.id,
                 "under" => section.id,
                 "name" => "Nacrt, dopunjen"
               })

      member_view = open_app(build_conn(), ctx.member_account, ctx.site)

      assert %{ok: false, error: "not_found"} =
               call(member_view, "get_subgroup", %{"id" => draft.id})

      assert %{ok: true, group: published} =
               call(editor_view, "update_child", %{
                 "id" => draft.id,
                 "under" => section.id,
                 "is_public" => true,
                 "inherit_role_keys" => []
               })

      assert published.published_at

      assert %{ok: true, group: again} =
               call(editor_view, "update_child", %{
                 "id" => draft.id,
                 "under" => section.id,
                 "is_public" => false,
                 "inherit_role_keys" => [ctx.role.key]
               })

      assert again.published_at == nil
    end
  end

  describe "a config the app says is public" do
    test "is read by a signed-in outsider of a public site, its secret part by editors only",
         ctx do
      {:ok, _config} =
        AppData.save_config(
          ctx.owner,
          ctx.site,
          nil,
          %{"public" => true, "menus" => %{"main" => []}, "secret" => %{"note" => "x"}},
          0
        )

      view = open_app(ctx.conn, ctx.outsider_account, ctx.site)

      assert %{ok: true, config: %{data: data}, manage: false} = call(view, "get_config")
      assert data["menus"] == %{"main" => []}
      refute Map.has_key?(data, "secret")
    end

    test "stays with the members when it does not say so", ctx do
      {:ok, _config} =
        AppData.save_config(ctx.owner, ctx.site, nil, %{"menus" => %{}}, 0)

      view = open_app(ctx.conn, ctx.outsider_account, ctx.site)

      assert %{ok: false, error: "not_a_member"} = call(view, "get_config")
    end

    test "says so with a boolean only", ctx do
      assert {:error, :invalid_value} =
               AppData.save_config(ctx.owner, ctx.site, nil, %{"public" => "yes"}, 0)
    end

    test "is read by a guest when the site is open to guests", ctx do
      {:ok, site} =
        Social.update_group(ctx.owner, ctx.site, %{"description_for_guests" => true})

      {:ok, _config} = AppData.save_config(ctx.owner, site, nil, %{"public" => true}, 0)

      {:ok, view, _html} = live(build_conn(), ~p"/groups/#{site.id}")

      render_hook(view, "app_api", %{"method" => "get_config", "params" => %{}, "app_id" => ""})
      assert_reply(view, %{ok: true, config: %{data: %{"public" => true}}})
    end
  end

  test "a group that inherits only by roles is a draft, one open to all is not" do
    assert Group.draft?(%Group{is_public: false, inherits_members: false})

    assert Group.draft?(%Group{
             is_public: false,
             inherits_members: true,
             inherit_role_keys: ["x"]
           })

    refute Group.draft?(%Group{is_public: false, inherits_members: true, inherit_role_keys: []})
    refute Group.draft?(%Group{is_public: true, inherits_members: false})
  end
end
