defmodule PotokIdeWeb.GroupLive.AccessPreviewTest do
  @moduledoc """
  An admin sees the group's page as others would (`?as=`): only an admin,
  only in a preview that holds, and nothing changes while it lasts.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupValueRead, Value}

  setup do
    {owner_account, owner} = account_with_profile!("ap-owner")
    {member_account, member} = account_with_profile!("ap-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "ap-group",
        "description" => "The text",
        "description_format" => :markdown,
        "is_public" => true,
        "home_page" => :chat
      })

    add_member!(owner, group, member)
    {:ok, _} = Social.create_own_group_manifest(owner, group)
    {:ok, muted} = Social.create_group_role(owner, group, %{"name" => "muted"})
    {:ok, _} = Social.set_group_role_permission(owner, group, muted.key, :post_values, :deny)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: Social.get_group!(group.id),
      muted: muted
    }
  end

  defp open(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp values_count(group),
    do: Repo.aggregate(from(v in Value, where: v.group_id == ^group.id), :count)

  test "an admin sees the page as a role would, with the banner", ctx do
    {:ok, lv, _html} =
      open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=#{ctx.muted.key}")

    assert has_element?(lv, "#access-preview-banner", "muted")
    # Muted may not write: the composer is not there.
    refute has_element?(lv, "#group-value-form")

    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=everyone")
    assert has_element?(lv, "#access-preview-banner")
    assert has_element?(lv, "#group-value-form")
  end

  test "nobody but an admin, and nothing the group does not have", ctx do
    {:ok, lv, _html} = open(ctx.member_account, ~p"/groups/#{ctx.group.id}/values?as=everyone")
    refute has_element?(lv, "#access-preview-banner")

    {:ok, private} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "ap-private",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{private.id}/values?as=outsider")
    refute has_element?(lv, "#access-preview-banner")

    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=no-such-role")
    refute has_element?(lv, "#access-preview-banner")
  end

  test "nothing changes while it lasts", ctx do
    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=everyone")
    before = values_count(ctx.group)

    lv |> form("#group-value-form", value: %{content: "from a preview"}) |> render_submit()

    assert values_count(ctx.group) == before
    assert render(lv) =~ "only a preview of the group"
  end

  test "a GIF from the keyboard, which needs no event, is not sent either", ctx do
    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=everyone")

    _ =
      lv
      |> file_input("#group-value-keyboard-media-form", :keyboard_media, [
        %{name: "keyboard-1.gif", content: "GIF89a", type: "image/gif"}
      ])
      |> render_upload("keyboard-1.gif")

    assert {[], false} = Social.list_group_attachments(ctx.group)
  end

  test "moving around keeps the preview, and leaving it mounts the page anew", ctx do
    {:ok, lv, _html} =
      open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values?as=#{ctx.muted.key}")

    lv |> element("#group-subgroups-summary") |> render_click()
    assert has_element?(lv, "#access-preview-banner")

    lv |> element("#access-preview-exit") |> render_click()
    assert_redirect(lv, ~p"/groups/#{ctx.group.id}/sub_groups")
  end

  test "it ends when the one who looks stops being an admin", ctx do
    {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")

    {:ok, lv, _html} =
      open(ctx.member_account, ~p"/groups/#{ctx.group.id}/values?as=#{ctx.muted.key}")

    assert has_element?(lv, "#access-preview-banner")

    :ok = Social.unassign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
    assert_redirect(lv, ~p"/groups/#{ctx.group.id}/values", 3000)
  end

  test "an app does not run in a preview, and no read marker moves", ctx do
    {:ok, group} =
      Social.update_group(ctx.owner, ctx.group, %{
        "uses_api" => "true",
        "home_page" => "description"
      })

    {:ok, _} = Social.create_value(ctx.member, group, %{"content" => "unread for the owner"})

    marker = fn ->
      Repo.one(
        from(r in GroupValueRead,
          where: r.group_id == ^group.id and r.profile_id == ^ctx.owner.id,
          select: r.last_read_value_id
        )
      )
    end

    before = marker.()

    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{group.id}/group_home?as=everyone")
    assert has_element?(lv, "#group-app-preview")
    refute has_element?(lv, ~s([phx-hook="GroupAppFrame"]))

    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{group.id}/values?as=everyone")
    _ = render(lv)
    assert marker.() == before
  end

  test "the overview leads an admin to the page as the roles picked", ctx do
    {:ok, lv, _html} = open(ctx.owner_account, ~p"/groups/#{ctx.group.id}/access")
    refute has_element?(lv, "#access-preview-open")

    lv |> element("#access-view-preset-new") |> render_click()

    assert has_element?(
             lv,
             ~s(#access-preview-open[href="/groups/#{ctx.group.id}?as=everyone"])
           )

    {:ok, lv, _html} = open(ctx.member_account, ~p"/groups/#{ctx.group.id}/access")
    lv |> element("#access-view-preset-new") |> render_click()
    refute has_element?(lv, "#access-preview-open")
  end
end
