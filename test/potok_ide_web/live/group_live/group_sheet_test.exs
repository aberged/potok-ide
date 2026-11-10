defmodule PotokIdeWeb.GroupLive.GroupSheetTest do
  @moduledoc """
  A sub-group's description over a map (`Show.GroupSheet`, `GroupLive.Sheet`):
  a LiveView of its own inside the page, bound to the sub-group, so the app in
  its description works with that group's rights.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Social
  alias PotokIde.Social.Value

  setup do
    {owner_account, owner} = account_with_profile!("sheet-owner")
    {member_account, member} = account_with_profile!("sheet-member")

    map = group!(owner, Social.get_root_group!(), %{"uses_api" => true, "is_public" => true})
    add_member!(owner, map, member)

    form =
      group!(owner, map, %{
        "uses_api" => true,
        "description" => "<p id='form-app'>form</p>",
        "inherits_members" => true,
        "latitude" => 44.8,
        "longitude" => 20.4
      })

    page =
      group!(owner, map, %{
        "description" => "Pekara na uglu, **sveža** svako jutro.",
        "description_format" => :markdown,
        "is_public" => true
      })

    %{
      owner_account: owner_account,
      member_account: member_account,
      owner: owner,
      member: member,
      map: map,
      form: form,
      page: page
    }
  end

  defp group!(owner, parent, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => "sheet-#{System.unique_integer([:positive])}",
            "description" => "<p>app</p>",
            "description_format" => :html,
            "home_page" => :description
          },
          attrs
        )
      )

    group
  end

  defp open_sheet(account, map, group) do
    {:ok, view, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => zone()})
      |> live(~p"/groups/#{map.id}/group_home")

    render_hook(view, "app_api", %{method: "show_group", params: %{id: group.id}, app_id: ""})
    assert_reply(view, %{ok: true})

    [sheet] = Enum.filter(live_children(view), &String.starts_with?(&1.id, "group-sheet-lv-"))
    {view, sheet}
  end

  defp call(lv, method, params \\ %{}) do
    render_hook(lv, "app_api", %{method: method, params: params, app_id: ""})
    assert_reply(lv, reply)
    reply
  end

  test "an app in the sheet acts on its own group, not on the map", ctx do
    {_view, sheet} = open_sheet(ctx.member_account, ctx.map, ctx.form)

    assert has_element?(
             sheet,
             "#sheet-app-frame[data-host='sheet'][data-upload='sheet_app_file']"
           )

    assert %{ok: true, group: %{id: id}} = call(sheet, "get_group")
    assert id == ctx.form.id

    assert %{ok: true, value: %{id: value_id}} = call(sheet, "insert_value", %{data: "{\"a\":1}"})
    assert PotokIde.Repo.get!(Value, value_id).group_id == ctx.form.id
  end

  test "the sheet's pin keeps the group's kind in its corner once the group picked a pin", ctx do
    {view, _sheet} = open_sheet(ctx.member_account, ctx.map, ctx.form)
    assert has_element?(view, "#group-sheet-pin")
    refute has_element?(view, "#group-sheet-pin [data-pin-mark]")

    form = ctx.form |> Ecto.Changeset.change(pin_icon: "shop") |> PotokIde.Repo.update!()
    {view, _sheet} = open_sheet(ctx.member_account, ctx.map, form)
    assert has_element?(view, "#group-sheet-pin [data-pin-mark]")

    # A group of no kind has no mark, on its avatar or on its pin.
    page = ctx.page |> Ecto.Changeset.change(pin_icon: "shop") |> PotokIde.Repo.update!()
    {view, _sheet} = open_sheet(ctx.member_account, ctx.map, page)
    refute has_element?(view, "#group-sheet-pin [data-pin-mark]")
  end

  test "a text description shows in the sheet, with its reactions", ctx do
    {_view, sheet} = open_sheet(ctx.member_account, ctx.map, ctx.page)

    assert has_element?(sheet, "#sheet-panel-description strong", "sveža")
    refute has_element?(sheet, "#group-description-switcher")

    render_hook(sheet, "toggle_group_reaction", %{"emoji" => "👍"})

    assert [%{emoji: "👍", count: 1}] =
             Social.group_reaction_summaries([ctx.page.id], ctx.member) |> Map.get(ctx.page.id)
  end

  test "a poll of the group opens and takes the vote inside the sheet", ctx do
    poll = create_poll!(ctx.owner, ctx.form)
    {_view, sheet} = open_sheet(ctx.member_account, ctx.map, ctx.form)

    assert %{ok: true} = call(sheet, "open_poll", %{id: poll.id})
    assert has_element?(sheet, "#poll-dialog")

    sheet |> element("#poll-dialog-card-vote-#{hd(option_ids(poll))}") |> render_click()

    assert %{voters_count: 1} = Polls.get_poll(poll.id)
  end

  test "the sheet opens no sheet, and leaves for the whole group on request", ctx do
    {_view, sheet} = open_sheet(ctx.member_account, ctx.map, ctx.form)

    assert %{ok: false, error: "unavailable"} = call(sheet, "show_group", %{id: ctx.page.id})

    render_hook(sheet, "app_api", %{
      method: "open_group",
      params: %{id: ctx.map.id, tab: "description"},
      app_id: ""
    })

    assert_redirect(sheet, ~p"/groups/#{ctx.map.id}/group_home")
  end

  test "the sheet closes when its group goes away", ctx do
    {view, _sheet} = open_sheet(ctx.member_account, ctx.map, ctx.page)

    {:ok, _deleted} = Social.delete_group(ctx.owner, ctx.page)

    assert_push_event(view, "group_sheet_closed", %{id: id})
    assert id == ctx.page.id
    refute has_element?(view, "#group-sheet")
  end

  # The sheet itself, as a page's `GroupSheet.dialog/1` mounts it.
  defp mount_sheet(ctx, parent, group) do
    {:ok, sheet, _html} =
      live_isolated(build_conn(), PotokIdeWeb.GroupLive.Sheet,
        session: %{
          "account_id" => ctx.member_account.id,
          "profile_id" => ctx.member.id,
          "parent_id" => parent.id,
          "group_id" => group.id,
          "locale" => "sr",
          "time_zone" => zone()
        }
      )

    sheet
  end

  test "under a group only its sub-groups open, under the root's map any group", ctx do
    deep =
      group!(ctx.owner, ctx.page, %{
        "description" => "Duboko **dole**.",
        "description_format" => :markdown,
        "is_public" => true
      })

    assert has_element?(mount_sheet(ctx, ctx.map, deep), "#group-sheet-unavailable")

    sheet = mount_sheet(ctx, Social.get_root_group!(), deep)
    refute has_element?(sheet, "#group-sheet-unavailable")
    assert has_element?(sheet, "#sheet-panel-description strong", "dole")
  end
end
