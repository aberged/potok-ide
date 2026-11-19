defmodule PotokIdeWeb.GroupLive.GroupKindSettingsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupPresets}

  setup %{conn: conn} do
    {account, owner} = account_with_profile!("kind-set-owner")
    parent = group_with_members!(owner, [])
    %{conn: log_in_account(conn, account), owner: owner, parent: parent}
  end

  defp create(ctx, preset) do
    {:ok, %{group: group}} =
      Social.create_group_from_preset(
        ctx.owner,
        ctx.parent,
        preset,
        Map.merge(GroupPresets.defaults(preset, ctx.parent), %{"name" => "Grupa #{preset}"})
      )

    group
  end

  defp settings(conn, group), do: live(conn, ~p"/groups/#{group.id}/edit_group")

  test "the basics show the kind and change it without a warning", %{conn: conn} = ctx do
    chat = create(ctx, "chat")
    {:ok, lv, _html} = settings(conn, chat)

    assert has_element?(lv, "#group-edit-kind-name", "Chat")

    lv |> element("#group-kind-change") |> render_click()

    assert has_element?(lv, "#group-kind-tile-chat[disabled]")
    assert has_element?(lv, "#group-kind-tile-folder")
    refute has_element?(lv, "#group-kind-tile-map[disabled]")

    lv |> element("#group-kind-tile-folder") |> render_click()

    assert has_element?(lv, "#group-kind-summary")
    refute has_element?(lv, "#group-kind-overwrite")

    lv |> element("#group-kind-apply") |> render_click()

    refute has_element?(lv, "#group-kind-menu")
    assert has_element?(lv, "#group-edit-kind-name", "Folder")
    assert Repo.get!(Group, chat.id).preset == :folder
  end

  test "overwriting an app warns and keeps it among the alternatives", %{conn: conn} = ctx do
    form = create(ctx, "questionnaire")
    {:ok, lv, _html} = settings(conn, form)

    lv |> element("#group-kind-change") |> render_click()
    lv |> element("#group-kind-tile-orders") |> render_click()

    assert has_element?(lv, "#group-kind-overwrite", "Form")
    assert has_element?(lv, "#group-kind-apply", "Overwrite")

    lv |> element("#group-kind-apply") |> render_click()

    group = Repo.get!(Group, form.id)
    assert group.preset == :orders
    assert [parked] = Social.list_alt_descriptions(group)
    assert parked.uses_api
    assert has_element?(lv, "#alt-description-#{parked.id}")
  end

  test "back returns to the kinds", %{conn: conn} = ctx do
    chat = create(ctx, "chat")
    {:ok, lv, _html} = settings(conn, chat)

    lv |> element("#group-kind-change") |> render_click()
    lv |> element("#group-kind-tile-page") |> render_click()
    lv |> element("#group-kind-back") |> render_click()

    assert has_element?(lv, "#group-kind-tiles")
    lv |> element("#group-kind-menu-close") |> render_click()
    refute has_element?(lv, "#group-kind-menu")
  end

  test "unsaved changes come first", %{conn: conn} = ctx do
    chat = create(ctx, "chat")
    {:ok, lv, _html} = settings(conn, chat)

    lv |> form("#group-edit-form", %{"group" => %{"name" => "Novo ime"}}) |> render_change()
    lv |> element("#group-kind-change") |> render_click()

    assert has_element?(lv, "#group-kind-blocked")
    refute has_element?(lv, "#group-kind-tiles")
  end

  test "a group made by hand shows no kind, and a direct group no row", %{conn: conn} = ctx do
    plain = group_with_members!(ctx.owner, [], %{parent: ctx.parent})
    {:ok, lv, _html} = settings(conn, plain)

    assert has_element?(lv, "#group-edit-kind-name", "No kind")

    {_account, other} = account_with_profile!("kind-set-other")
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, other)
    {:ok, lv, _html} = settings(conn, direct)

    refute has_element?(lv, "#group-edit-kind")
  end

  test "a form saved after another change of kind keeps the new one", %{conn: conn} = ctx do
    chat = create(ctx, "chat")
    {:ok, lv, _html} = settings(conn, chat)

    # Another editor's change, while this form stays open.
    {:ok, _changed} = Social.change_group_preset(ctx.owner, chat, "polls", "Prethodno")

    lv |> form("#group-edit-form", %{"group" => %{"name" => "Glasanja"}}) |> render_submit()

    group = Repo.get!(Group, chat.id)
    assert group.name == "Glasanja"
    assert group.uses_api
    assert group.preset == :polls
  end

  test "a description edited after another change of kind is refused", %{conn: conn} = ctx do
    page = create(ctx, "page")
    {:ok, lv, _html} = settings(conn, page)

    {:ok, _changed} = Social.change_group_preset(ctx.owner, page, "polls", "Prethodno")

    html =
      lv
      |> form("#group-edit-form", %{"group" => %{"description" => "Novi tekst"}})
      |> render_submit()

    assert html =~ "changed in the meantime"
    assert Repo.get!(Group, page.id).uses_api
  end
end
