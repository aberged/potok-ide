defmodule PotokIdeWeb.GroupLive.UnreadDividerTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.GroupValueRead

  setup do
    {owner_account, owner} = account_with_profile!("divider-owner")
    {viewer_account, viewer} = account_with_profile!("divider-viewer")
    group = group_with_members!(owner, [viewer])

    %{
      owner_account: owner_account,
      owner: owner,
      viewer_account: viewer_account,
      viewer: viewer,
      group: group
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> live(path)
  end

  defp post!(profile, group, content) do
    {:ok, value} = Social.create_value(profile, group, %{"content" => content})
    value
  end

  defp post_many!(profile, group, count) do
    Enum.map(1..count, &post!(profile, group, "message #{&1}"))
  end

  describe "unread_start/2" do
    test "is nil without a read marker and counts from the first unread value", ctx do
      post!(ctx.owner, ctx.group, "before")
      assert Social.unread_start(ctx.viewer, ctx.group) == nil

      :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
      assert Social.unread_start(ctx.viewer, ctx.group) == nil

      [first, _second] = post_many!(ctx.owner, ctx.group, 2)
      assert Social.unread_start(ctx.viewer, ctx.group) == %{value_id: first.id, count: 2}
      assert Social.unread_start(nil, ctx.group) == nil
    end

    test "read_group_chat/2 marks the chat read and says where the unread began", ctx do
      post!(ctx.owner, ctx.group, "before")
      assert Social.read_group_chat(ctx.viewer, ctx.group) == nil
      assert Social.unread_start(ctx.viewer, ctx.group) == nil

      [first, _second, last] = post_many!(ctx.owner, ctx.group, 3)
      assert Social.read_group_chat(ctx.viewer, ctx.group) == %{value_id: first.id, count: 3}
      assert Social.read_group_chat(ctx.viewer, ctx.group) == nil

      assert Repo.get_by!(GroupValueRead, profile_id: ctx.viewer.id, group_id: ctx.group.id).last_read_value_id ==
               last.id
    end

    test "an empty chat read gets a marker, so its first values are unread", ctx do
      assert Social.read_group_chat(ctx.viewer, ctx.group) == nil
      first = post!(ctx.owner, ctx.group, "first")

      assert Social.unread_start(ctx.viewer, ctx.group) == %{value_id: first.id, count: 1}
    end

    test "leaves out app data values", ctx do
      :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
      post!(ctx.owner, ctx.group, "seen")
      :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)

      {:ok, _data} =
        Social.create_data_value(ctx.owner, ctx.group, %{
          "content" => "data:",
          "data" => %{"x" => 1}
        })

      assert Social.unread_start(ctx.viewer, ctx.group) == nil
    end
  end

  test "a member coming back finds the divider above the first unread value", ctx do
    post!(ctx.owner, ctx.group, "read already")
    :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
    [first | _rest] = post_many!(ctx.owner, ctx.group, 3)

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")

    assert has_element?(
             lv,
             "#value-#{first.id}[data-unread-start] #group-values-unread-divider",
             "3"
           )

    assert Social.unread_start(ctx.viewer, ctx.group) == nil
  end

  test "a profile that never opened the chat, or read it all, gets no divider", ctx do
    post_many!(ctx.owner, ctx.group, 2)

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")
    refute has_element?(lv, "#group-values-unread-divider")
    refute has_element?(lv, "[data-unread-start]")

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")
    refute has_element?(lv, "#group-values-unread-divider")
  end

  test "more unread values than a page open around the first of them", ctx do
    post!(ctx.owner, ctx.group, "read already")
    :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
    values = post_many!(ctx.owner, ctx.group, 30)
    first = hd(values)
    newest = List.last(values)

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")

    assert has_element?(lv, "#value-#{first.id} #group-values-unread-divider", "30")
    assert has_element?(lv, "#group-values-feed[data-has-newer='true']")
    assert has_element?(lv, "#group-values-load-newer")
    refute has_element?(lv, "#value-#{newest.id}")
  end

  test "a link to a value wins over the divider", ctx do
    linked = post!(ctx.owner, ctx.group, "linked")
    post_many!(ctx.owner, ctx.group, 3)
    :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
    post_many!(ctx.owner, ctx.group, 25)

    {:ok, lv, _html} =
      live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values?value=#{linked.id}")

    assert has_element?(lv, "#group-values-feed[data-focus-value-id='#{linked.id}']")
    assert has_element?(lv, "#value-#{linked.id}")
  end

  test "the divider stays put while the chat is open", ctx do
    :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
    [first, _second] = post_many!(ctx.owner, ctx.group, 2)

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")
    assert has_element?(lv, "#value-#{first.id} #group-values-unread-divider", "2")

    live_value = post!(ctx.owner, ctx.group, "while open")
    assert has_element?(lv, "#value-#{live_value.id}")
    refute has_element?(lv, "#value-#{live_value.id}[data-unread-start]")

    {:ok, _group} = Social.update_group(ctx.owner, ctx.group, %{"name" => "renamed-divider"})
    assert render(lv) =~ "renamed-divider"
    assert has_element?(lv, "#value-#{first.id} #group-values-unread-divider", "2")
  end

  test "coming back to the chat tab measures again", ctx do
    :ok = Social.mark_group_values_read(ctx.viewer, ctx.group)
    post_many!(ctx.owner, ctx.group, 3)

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.group.id}/values")
    assert has_element?(lv, "#group-values-unread-divider", "3")

    lv |> element("#group-files-summary") |> render_click()
    refute has_element?(lv, "#group-values-unread-divider")

    [first, _second] = post_many!(ctx.owner, ctx.group, 2)
    lv |> element("#group-values-summary") |> render_click()

    assert has_element?(lv, "#value-#{first.id} #group-values-unread-divider", "2")
  end
end
