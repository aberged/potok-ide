defmodule PotokIdeWeb.GroupLive.AppPersonalTest do
  @moduledoc """
  An app's personal memory through the App API (`list_personal` and the rest):
  each viewer's own, unseen by the app's editors, and a guest's frame keeps
  it in the browser.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("pm#{unique()}")
    {member_account, member} = account_with_profile!("pm#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" =>
          ~s(<iframe src="https://ustav.example/" data-potok-api="get_personal"></iframe>),
        "description_format" => :html,
        "home_page" => :description
      })

    %{
      owner_account: owner_account,
      member_account: member_account,
      member: member,
      group: Social.get_group!(group.id)
    }
  end

  defp open_app(account, group) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> live(~p"/groups/#{group.id}/group_home")

    lv
  end

  defp call(lv, method, params \\ %{}) do
    render_hook(lv, "app_api", %{method: method, params: params, app_id: ""})
    assert_reply(lv, reply)
    reply
  end

  test "a viewer keeps their own memory, and the app's editor does not read it", ctx do
    member = open_app(ctx.member_account, ctx.group)

    assert %{ok: true} = call(member, "set_personal", %{key: "page", value: "/poglavlja/03.html"})
    assert %{ok: true, value: "/poglavlja/03.html"} = call(member, "get_personal", %{key: "page"})
    assert %{ok: true, items: [%{key: "page"}]} = call(member, "list_personal")

    owner = open_app(ctx.owner_account, ctx.group)
    assert %{ok: true, value: nil} = call(owner, "get_personal", %{key: "page"})
    assert %{ok: true, items: []} = call(owner, "list_personal")

    assert %{ok: true} = call(member, "delete_personal", %{key: "page"})
    assert %{ok: true, value: nil} = call(member, "get_personal", %{key: "page"})
  end

  test "a bad key or a value too big are refused", ctx do
    member = open_app(ctx.member_account, ctx.group)

    assert %{ok: false, error: "invalid_key"} =
             call(member, "set_personal", %{key: "a b", value: 1})

    assert %{ok: false, error: "too_big"} =
             call(member, "set_personal", %{key: "big", value: String.duplicate("x", 20_000)})
  end

  test "the page shows what apps remember and deletes it", ctx do
    member = open_app(ctx.member_account, ctx.group)
    assert %{ok: true} = call(member, "set_personal", %{key: "page", value: "/x"})

    {:ok, settings, _html} =
      build_conn()
      |> log_in_account(ctx.member_account)
      |> live(~p"/accounts/settings")

    row = "#settings-app-memory-#{ctx.group.id}-0"
    assert has_element?(settings, row)

    settings |> element("#{row} button") |> render_click()
    refute has_element?(settings, row)
    assert has_element?(settings, "#settings-app-memory-empty")
  end
end
