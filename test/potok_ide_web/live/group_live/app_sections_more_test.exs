defmodule PotokIdeWeb.GroupLive.AppSectionsMoreTest do
  @moduledoc """
  What a site does with its articles besides writing them: finds them by a
  part of their name or text (`search_subgroups`), moves one to another
  section (`move_child`), and lets a draft open by itself at a time its
  editor picked (`publish_at`, `ScheduledPublications`).
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, add_member!: 3]

  alias PotokIde.History.GroupChange
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{ScheduledPublication, ScheduledPublications}

  setup do
    {owner_account, owner} = account_with_profile!("more-owner")
    {member_account, member} = account_with_profile!("more-member")

    site =
      group!(owner, Social.get_root_group!(), "more-site", %{
        "description" => "<p>site</p>",
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => true,
        "home_page" => :description,
        "description_for_guests" => true
      })

    add_member!(owner, site, member)

    view = open_app(build_conn(), owner_account, site)
    news = section!(view, "Vesti")
    sport = section!(view, "Sport")

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      site: site,
      view: view,
      news: news,
      sport: sport
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

  defp call(view, method, params) do
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

  defp article!(view, section, name, html, extra \\ %{}) do
    assert %{ok: true, group: article} =
             call(
               view,
               "create_child",
               Map.merge(
                 %{
                   "under" => section.id,
                   "name" => name,
                   "description" => html,
                   "description_format" => "html",
                   "is_public" => true,
                   "inherits_members" => true
                 },
                 extra
               )
             )

    article
  end

  defp names(%{groups: groups}), do: groups |> Enum.map(& &1.name) |> Enum.sort()

  describe "search" do
    setup ctx do
      article!(
        ctx.view,
        ctx.news,
        "Proleće u Topoliku",
        ~s(<!--potok-site {"v":1}-->\n<p>Čišćenje <strong>obale</strong> reke.</p>)
      )

      article!(ctx.view, ctx.sport, "Turnir u fudbalu", "<p>Subota na terenu.</p>")
      :ok
    end

    test "finds articles by their name or text, without minding case or diacritics", ctx do
      assert ["Proleće u Topoliku"] =
               names(call(ctx.view, "search_subgroups", %{"q" => "ciscenje"}))

      assert ["Proleće u Topoliku"] =
               names(call(ctx.view, "search_subgroups", %{"q" => "OBALE reke"}))

      assert ["Turnir u fudbalu"] = names(call(ctx.view, "search_subgroups", %{"q" => "turnir"}))

      assert %{groups: [found]} = call(ctx.view, "search_subgroups", %{"q" => "obale"})
      assert found.summary =~ "obale"
      assert found.description_html == nil
    end

    test "reads no markers or tags as text", ctx do
      assert [] = names(call(ctx.view, "search_subgroups", %{"q" => "potok-site"}))
      assert [] = names(call(ctx.view, "search_subgroups", %{"q" => "strong"}))
      assert [] = names(call(ctx.view, "search_subgroups", %{"q" => "   "}))
    end

    test "looks in one section with `under`", ctx do
      assert [] =
               names(
                 call(ctx.view, "search_subgroups", %{"q" => "turnir", "under" => ctx.news.id})
               )

      assert ["Turnir u fudbalu"] =
               names(
                 call(ctx.view, "search_subgroups", %{"q" => "turnir", "under" => ctx.sport.id})
               )
    end

    test "a guest finds by text only what is open to guests", ctx do
      article!(ctx.view, ctx.news, "Za prijavljene", "<p>Tajni sastanak saveta.</p>")

      {:ok, closed} =
        ctx.news.id
        |> Social.get_group!()
        |> Social.list_visible_child_groups_newest_first(ctx.owner, limit: 10)
        |> elem(0)
        |> Enum.find(&(&1.name == "Za prijavljene"))
        |> then(&Social.update_group(ctx.owner, &1, %{"description_for_guests" => false}))

      assert closed.is_public

      {:ok, guest, _html} = live(build_conn(), ~p"/groups/#{ctx.site.id}")

      render_hook(guest, "app_api", %{
        "method" => "search_subgroups",
        "params" => %{"q" => "sastanak"},
        "app_id" => ""
      })

      assert_reply(guest, %{ok: true, groups: []})

      render_hook(guest, "app_api", %{
        "method" => "search_subgroups",
        "params" => %{"q" => "prijavljene"},
        "app_id" => ""
      })

      assert_reply(guest, %{ok: true, groups: [%{name: "Za prijavljene", summary: nil}]})
    end
  end

  describe "moving an article" do
    test "goes to another section of the site, told of in the history of both", ctx do
      article = article!(ctx.view, ctx.news, "Utakmica", "<p>Tekst.</p>")

      assert %{ok: true, group: moved} =
               call(ctx.view, "move_child", %{
                 "id" => article.id,
                 "under" => ctx.news.id,
                 "to" => ctx.sport.id
               })

      assert moved.parent_id == ctx.sport.id
      assert [] = names(call(ctx.view, "list_subgroups", %{"id" => ctx.news.id}))
      assert ["Utakmica"] = names(call(ctx.view, "list_subgroups", %{"id" => ctx.sport.id}))

      rows =
        from(c in GroupChange,
          where:
            c.subject_type == "sub_group" and c.subject_id == ^article.id and c.op == :changed,
          select: {c.group_id, c.before, c.actor_id}
        )
        |> Repo.all()
        |> Map.new(fn {group_id, before, actor} -> {group_id, {before, actor}} end)

      assert {%{"to" => to}, actor} = rows[ctx.news.id]
      assert to == ctx.sport.id
      assert actor == ctx.owner.id
      assert {%{"from" => from}, ^actor} = rows[ctx.sport.id]
      assert from == ctx.news.id
    end

    test "only within the site, and only for its editors", ctx do
      article = article!(ctx.view, ctx.news, "Ostaje", "<p>Tekst.</p>")

      elsewhere =
        group!(ctx.owner, Social.get_root_group!(), "more-elsewhere", %{"is_public" => true})

      assert %{ok: false, error: "not_found"} =
               call(ctx.view, "move_child", %{
                 "id" => article.id,
                 "under" => ctx.news.id,
                 "to" => elsewhere.id
               })

      member_view = open_app(build_conn(), ctx.member_account, ctx.site)

      assert %{ok: false, error: "forbidden"} =
               call(member_view, "move_child", %{
                 "id" => article.id,
                 "under" => ctx.news.id,
                 "to" => ctx.sport.id
               })

      assert Social.get_group!(article.id).parent_id == ctx.news.id
    end
  end

  describe "a publication at a time" do
    defp draft!(ctx, extra) do
      article!(
        ctx.view,
        ctx.news,
        "Najava",
        "<p>Uskoro.</p>",
        Map.merge(%{"is_public" => false, "inherits_members" => false}, extra)
      )
    end

    defp in_hours(hours),
      do: DateTime.utc_now(:second) |> DateTime.add(hours * 3600) |> DateTime.to_iso8601()

    test "opens the draft when it is due, in the name of who scheduled it", ctx do
      draft = draft!(ctx, %{"publish_at" => in_hours(2)})

      assert draft.publish_at
      refute draft.is_public

      assert 0 = ScheduledPublications.run_due()
      assert 1 = ScheduledPublications.run_due(DateTime.add(DateTime.utc_now(), 3, :hour))

      published = Social.get_group!(draft.id)
      assert published.is_public
      assert published.inherits_members
      assert published.published_at
      refute Repo.get_by(ScheduledPublication, group_id: draft.id)

      assert %{actor_id: actor_id, cause: %{"via" => "scheduled"}} =
               Repo.one!(
                 from(c in GroupChange,
                   where:
                     c.subject_type == "group" and c.subject_id == ^draft.id and
                       c.op == :changed and fragment("? ->> 'via' = 'scheduled'", c.cause)
                 )
               )

      assert actor_id == ctx.owner.id
    end

    test "is shown to editors in the list and taken away by a withdrawal", ctx do
      draft = draft!(ctx, %{"publish_at" => in_hours(5), "publish_public" => false})

      assert %{groups: [listed]} = call(ctx.view, "list_children", %{"under" => ctx.news.id})
      assert listed.publish_at
      assert listed.publish_failure == nil

      assert %{ok: true, group: %{publish_at: nil}} =
               call(ctx.view, "withdraw_child", %{"id" => draft.id, "under" => ctx.news.id})

      refute Repo.get_by(ScheduledPublication, group_id: draft.id)
    end

    test "is taken away when the draft is published by hand", ctx do
      draft = draft!(ctx, %{"publish_at" => in_hours(5)})

      assert %{ok: true, group: %{publish_at: nil}} =
               call(ctx.view, "update_child", %{
                 "id" => draft.id,
                 "under" => ctx.news.id,
                 "is_public" => true
               })
    end

    test "a time gone by or too far is refused before anything is saved", ctx do
      assert %{ok: false, error: "invalid_date"} =
               call(ctx.view, "create_child", %{
                 "under" => ctx.news.id,
                 "name" => "Prošlost",
                 "publish_at" => in_hours(-1)
               })

      assert %{ok: false, error: "invalid_date"} =
               call(ctx.view, "create_child", %{
                 "under" => ctx.news.id,
                 "name" => "Daleko",
                 "publish_at" => in_hours(24 * 400)
               })

      assert %{groups: []} = call(ctx.view, "list_children", %{"under" => ctx.news.id})
    end

    test "one who may no longer edit the draft publishes nothing, and the editors see why", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.site)
      {:ok, role} = Social.create_group_role(ctx.owner, ctx.site, %{"name" => "urednik"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.site, role.key, :edit_group, :allow)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.site, role.key, :create_subgroups, :allow)

      {:ok, _assignment} =
        Social.assign_group_member_role(ctx.owner, ctx.site, ctx.member.id, role.key)

      section = section!(ctx.view, "Najave")
      member_view = open_app(build_conn(), ctx.member_account, ctx.site)

      assert %{ok: true, group: draft} =
               call(member_view, "create_child", %{
                 "under" => section.id,
                 "name" => "Moja najava",
                 "is_public" => false,
                 "inherits_members" => true,
                 "inherit_role_keys" => [role.key, "admin"],
                 "publish_at" => in_hours(1)
               })

      # Its author is the draft's admin, as of any group they make: that goes
      # too, by hand, with the role that brought them into the site's editors.
      :ok = Social.unassign_group_member_role(ctx.owner, ctx.site, ctx.member.id, role.key)

      Repo.delete_all(
        from(r in PotokIde.Social.GroupMemberRole,
          where: r.group_id == ^draft.id and r.profile_id == ^ctx.member.id
        )
      )

      PotokIde.Social.Access.forget([draft.id])

      assert 0 = ScheduledPublications.run_due(DateTime.add(DateTime.utc_now(), 2, :hour))
      refute Social.get_group!(draft.id).is_public

      assert %{groups: [listed]} = call(ctx.view, "list_children", %{"under" => section.id})
      assert listed.publish_failure == "not_permitted"
    end
  end
end
