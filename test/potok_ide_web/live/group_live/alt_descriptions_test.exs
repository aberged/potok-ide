defmodule PotokIdeWeb.GroupLive.AltDescriptionsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("alt-lv-owner")

    group =
      group!(owner, "alt-lv-group", %{
        "description" => "Default **text**",
        "is_public" => true
      })

    %{owner_account: owner_account, owner: owner, group: group}
  end

  describe "description switcher" do
    test "shows only when the group has alternative descriptions", ctx do
      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/group_home")

      refute has_element?(lv, "#group-description-switcher")

      poll = alt!(ctx.owner, ctx.group, %{"name" => "Poll", "uses_api" => true})

      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/group_home")

      assert has_element?(lv, "#group-description-switcher-default[aria-current=page]")
      assert has_element?(lv, "#group-description-switcher-#{poll.id}", "Poll")
      assert has_element?(lv, "#group-panel-description .rich-content")
    end

    test "opens an alternative app in its own frame with its own storage", ctx do
      poll =
        alt!(ctx.owner, ctx.group, %{
          "name" => "Poll",
          "uses_api" => true,
          "description" => "<p>poll</p>"
        })

      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/group_home")

      lv |> element("#group-description-switcher-#{poll.id}") |> render_click()
      assert_patch(lv, ~p"/groups/#{ctx.group.id}/group_home?d=#{poll.id}")

      frame =
        "#group-app-frame-alt-#{poll.id}" <>
          "[data-app-id='#{poll.id}']" <>
          "[data-storage-key='potok-app:#{ctx.group.id}:alt-#{poll.id}']"

      assert has_element?(lv, frame)
      assert has_element?(lv, "#group-description-switcher-#{poll.id}[aria-current=page]")

      lv |> element("#group-description-switcher-default") |> render_click()
      refute has_element?(lv, "#group-app-frame-alt-#{poll.id}")
      assert has_element?(lv, "#group-panel-description .rich-content")
    end

    test "opens the home description first", ctx do
      poll = alt!(ctx.owner, ctx.group, %{"name" => "Poll", "description" => "Poll *text*"})

      {:ok, _group} =
        Social.update_group(ctx.owner, ctx.group, %{"home_alt_description_id" => poll.id})

      {:ok, lv, _html} = live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}")
      assert has_element?(lv, "#group-description-switcher-#{poll.id}[aria-current=page]")

      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/group_home?d=default")

      assert has_element?(lv, "#group-description-switcher-default[aria-current=page]")
    end

    test "hides descriptions limited to roles the viewer does not hold", ctx do
      {member_account, member} = account_with_profile!("alt-lv-member")
      {helper_account, helper} = account_with_profile!("alt-lv-helper")
      add_member!(ctx.owner, ctx.group, member)
      add_member!(ctx.owner, ctx.group, helper)

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, helpers} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "helpers"})
      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, helper.id, helpers.key)

      secret =
        alt!(ctx.owner, ctx.group, %{"name" => "Secret", "visible_role_keys" => [helpers.key]})

      path = ~p"/groups/#{ctx.group.id}/group_home?d=#{secret.id}"

      {:ok, member_lv, _html} = live_as(ctx.conn, member_account, path)
      refute has_element?(member_lv, "#group-description-switcher")
      assert has_element?(member_lv, "#group-panel-description .rich-content")

      {:ok, helper_lv, _html} = live_as(ctx.conn, helper_account, path)

      assert has_element?(
               helper_lv,
               "#group-description-switcher-#{secret.id}[aria-current=page]"
             )

      {:ok, owner_lv, _html} = live_as(ctx.conn, ctx.owner_account, path)
      assert has_element?(owner_lv, "#group-description-switcher-#{secret.id}[aria-current=page]")
    end
  end

  describe "app api" do
    setup ctx do
      {:ok, group} = Social.update_group(ctx.owner, ctx.group, %{"uses_api" => "true"})
      poll = alt!(ctx.owner, group, %{"name" => "Poll", "uses_api" => true})

      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{group.id}/group_home?d=#{poll.id}")

      %{group: group, poll: poll, lv: lv}
    end

    test "keeps each app's values apart", %{lv: lv, poll: poll} = ctx do
      {:ok, default_value} =
        Social.create_data_value(ctx.owner, ctx.group, %{"content" => "data:", "data" => "{}"})

      app_call(lv, poll, "insert_value", %{"data" => ~s({"vote": 1})})
      assert_reply(lv, %{ok: true, value: %{description_id: poll_id} = poll_value})
      assert poll_id == poll.id

      app_call(lv, poll, "list_values", %{})
      assert_reply(lv, %{ok: true, values: [listed]})
      assert listed.id == poll_value.id

      app_call(lv, poll, "list_values", %{"scope" => "group"})
      assert_reply(lv, %{ok: true, values: values})
      assert Enum.sort(Enum.map(values, & &1.id)) == Enum.sort([default_value.id, poll_value.id])
    end

    test "updates the app's own description", %{lv: lv, poll: poll} = ctx do
      app_call(lv, poll, "update_description", %{"description" => "<p>poll v2</p>"})

      assert_reply(lv, %{
        ok: true,
        group: %{description: "<p>poll v2</p>", description_id: poll_id, name: "Poll"}
      })

      assert poll_id == poll.id
      assert Social.get_alt_description(ctx.group, poll.id).description == "<p>poll v2</p>"
      assert Social.get_group!(ctx.group.id).description == "Default **text**"
    end

    test "refuses calls of an app that is no longer on screen", %{lv: lv} do
      render_hook(lv, "app_api", %{
        "method" => "insert_value",
        "params" => %{"data" => "{}"},
        "app_id" => ""
      })

      assert_reply(lv, %{ok: false, error: "stale_app"})
    end
  end

  describe "edit tab" do
    test "creates, edits, orders, promotes and deletes alternative descriptions", ctx do
      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/edit_group")

      lv |> element("#alt-description-new") |> render_click()
      assert has_element?(lv, "#alt-description-form")

      lv
      |> form("#alt-description-form",
        group_alt_description: %{name: "Poll", description: "Vote!"}
      )
      |> render_submit()

      refute has_element?(lv, "#alt-description-form")
      [poll] = Social.list_alt_descriptions(ctx.group)
      assert has_element?(lv, "#alt-description-#{poll.id}", "Poll")

      lv |> element("#alt-description-new") |> render_click()

      lv
      |> form("#alt-description-form", group_alt_description: %{name: "Board"})
      |> render_submit()

      [^poll, board] = Social.list_alt_descriptions(ctx.group)

      lv |> element("#alt-description-#{board.id}-up") |> render_click()
      assert Enum.map(Social.list_alt_descriptions(ctx.group), & &1.id) == [board.id, poll.id]

      lv |> element("#alt-description-#{board.id}-edit") |> render_click()

      lv
      |> form("#alt-description-form", group_alt_description: %{name: "Kanban"})
      |> render_submit()

      assert has_element?(lv, "#alt-description-#{board.id}", "Kanban")

      lv |> element("#alt-description-#{poll.id}-promote") |> render_click()
      group = Social.get_group!(ctx.group.id)
      assert group.description == "Vote!"
      assert group.description_name == "Poll"
      assert has_element?(lv, "#alt-description-#{poll.id}", "Description")

      lv |> element("#alt-description-#{board.id}-delete") |> render_click()
      refute has_element?(lv, "#alt-description-#{board.id}")
      assert [_demoted] = Social.list_alt_descriptions(ctx.group)
    end

    test "shows validation errors in the form", ctx do
      _poll = alt!(ctx.owner, ctx.group, %{"name" => "Poll"})

      {:ok, lv, _html} =
        live_as(ctx.conn, ctx.owner_account, ~p"/groups/#{ctx.group.id}/edit_group")

      lv |> element("#alt-description-new") |> render_click()

      lv
      |> form("#alt-description-form", group_alt_description: %{name: "poll"})
      |> render_submit()

      assert has_element?(lv, "#alt-description-form", "is already used by another description")
    end
  end

  defp app_call(lv, alt, method, params) do
    render_hook(lv, "app_api", %{
      "method" => method,
      "params" => params,
      "app_id" => Integer.to_string(alt.id)
    })
  end

  defp live_as(conn, account, path) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(path)
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {account, profile}
  end

  defp group!(owner, name, attrs) do
    attrs =
      Map.merge(
        %{"name" => name, "description" => "", "description_format" => :markdown},
        attrs
      )

    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), attrs)
    group
  end

  defp alt!(owner, group, attrs) do
    {:ok, alt} = Social.create_alt_description(owner, group, attrs)
    alt
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
