defmodule PotokIdeWeb.GroupLive.AppRefreshSettingsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppBuilds, Group, GroupAltDescription, GroupPresets}

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("osvezi-owner")
    parent = group_with_members!(owner, [])
    %{conn: log_in_account(conn, account), owner: owner, parent: parent}
  end

  defp create(ctx, preset) do
    {:ok, made} =
      Social.create_group_from_preset(
        ctx.owner,
        ctx.parent,
        preset,
        Map.merge(GroupPresets.defaults(preset, ctx.parent), %{"name" => "Grupa #{preset}"})
      )

    made
  end

  defp older(app) do
    ~s(<meta name="potok-app" content="#{app}">\n<!-- earlier -->\n) <>
      AppBuilds.current_html(app)
  end

  defp put_older(ctx, group, app) do
    {:ok, group} = Social.update_group(ctx.owner, group, %{"description" => older(app)})
    group
  end

  defp description(conn, group),
    do: live(conn, ~p"/groups/#{group.id}/edit_group?#{[section: "description"]}")

  test "an older Feed says so, and the button brings it and its FeedCreator to the newest",
       %{conn: conn} = ctx do
    %{group: feed, feed: desk} = create(ctx, "feed")
    feed = put_older(ctx, feed, "potok-feed")
    put_older(ctx, desk, "potok-feed-creator")

    {:ok, lv, _html} = description(conn, feed)

    assert has_element?(lv, "#group-description-app-size", "Feed")
    assert has_element?(lv, "#group-description-app-outdated")
    assert has_element?(lv, "#group-description-app-refresh[data-confirm*='FeedCreator']")

    lv |> element("#group-description-app-refresh") |> render_click()

    refute has_element?(lv, "#group-description-app-outdated")
    assert has_element?(lv, "#flash-group", "FeedCreator")
    assert Repo.get!(Group, feed.id).description == AppBuilds.current_html("potok-feed")

    assert Repo.get!(Group, desk.id).description ==
             AppBuilds.current_html("potok-feed-creator")
  end

  test "the newest build and an app of one's own have no button", %{conn: conn} = ctx do
    %{group: map} = create(ctx, "map")
    {:ok, lv, _html} = description(conn, map)

    assert has_element?(lv, "#group-description-app-size", "Map")
    refute has_element?(lv, "#group-description-app-refresh")

    own =
      group_with_members!(ctx.owner, [], %{"uses_api" => true, "description" => "<p>moja</p>"})

    {:ok, lv, _html} = description(conn, own)

    assert has_element?(lv, "#group-description-app-size")
    refute has_element?(lv, "#group-description-app-refresh")
  end

  test "unsaved changes come first", %{conn: conn} = ctx do
    %{group: form} = create(ctx, "questionnaire")
    form = put_older(ctx, form, "potok-forme")
    {:ok, lv, _html} = description(conn, form)

    lv |> form("#group-edit-form", %{"group" => %{"name" => "Nova anketa"}}) |> render_change()
    lv |> element("#group-description-app-refresh") |> render_click()

    assert has_element?(lv, "#flash-group", "Save or discard")
    assert Repo.get!(Group, form.id).description == older("potok-forme")
  end

  test "an app in an alternative description refreshes from its form", %{conn: conn} = ctx do
    group = group_with_members!(ctx.owner, [], %{parent: ctx.parent})

    {:ok, alt} =
      Social.create_alt_description(ctx.owner, group, %{
        "name" => "Glasanja",
        "uses_api" => "true",
        "description" => older("potok-glasanje")
      })

    {:ok, lv, _html} =
      live(conn, ~p"/groups/#{group.id}/edit_group?#{[section: "alt_descriptions"]}")

    lv |> element("#alt-description-#{alt.id}-edit") |> render_click()
    assert has_element?(lv, "#alt-description-app-outdated")

    lv |> element("#alt-description-app-refresh") |> render_click()

    assert Repo.get!(GroupAltDescription, alt.id).description ==
             AppBuilds.current_html("potok-glasanje")

    refute has_element?(lv, "#alt-description-app-outdated")
  end
end
