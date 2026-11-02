defmodule PotokIdeWeb.GroupLive.TagsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Tags

  setup do
    {owner_account, owner} = account_with_profile!("gtag-owner")
    {member_account, member} = account_with_profile!("gtag-member")
    group = group_with_members!(owner, [member])
    {:ok, value} = Social.create_value(owner, group, %{"content" => "Plans for spring"})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      value: value
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => zone()})
    |> live(path)
  end

  # The visibility switch shows only to those who may add public tags.
  defp add_tag(lv, name, visibility \\ nil) do
    params = if visibility, do: %{name: name, visibility: visibility}, else: %{name: name}

    lv
    |> form("#tag-editor-form", tag: params)
    |> render_submit()
  end

  defp tag_named!(profile, name) do
    %{mine: mine, public: public} = Tags.list_directory(profile, name)
    Enum.find(mine ++ public, &(&1.name == name)) || raise "no tag #{name}"
  end

  describe "values" do
    test "a member tags a value privately and only that member sees it", ctx do
      %{group: group, value: value, member: member} = ctx
      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/values")
      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{group.id}/values")

      member_lv |> element("#value-tags-#{value.id}") |> render_click()

      assert has_element?(member_lv, "#tag-editor-item", "Plans for spring")
      # Members without manage_tags add private tags only.
      refute has_element?(member_lv, "#tag-editor-visibility")

      add_tag(member_lv, "later")
      tag = tag_named!(member, "later")

      assert has_element?(member_lv, "#tag-editor-tag-#{tag.id}")
      assert has_element?(member_lv, "#value-tag-list-#{value.id}-#{tag.id}", "later")
      refute has_element?(owner_lv, "#value-tag-list-#{value.id}")

      member_lv |> element("#tag-editor-remove-#{tag.id}") |> render_click()
      refute has_element?(member_lv, "#value-tag-list-#{value.id}")

      member_lv |> element("#tag-editor-close") |> render_click()
      refute has_element?(member_lv, "#tag-editor")
    end

    test "an admin's public tag reaches the other members live", ctx do
      %{group: group, value: value, owner: owner} = ctx
      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/values")
      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{group.id}/values")

      owner_lv |> element("#value-tags-#{value.id}") |> render_click()
      assert has_element?(owner_lv, "#tag-editor-visibility")

      add_tag(owner_lv, "news", "public")
      tag = tag_named!(owner, "news")

      assert has_element?(member_lv, "#value-tag-list-#{value.id}-#{tag.id}", "news")

      owner_lv |> element("#tag-editor-remove-#{tag.id}") |> render_click()
      refute has_element?(member_lv, "#value-tag-list-#{value.id}")
    end

    test "tags stay on a value when it changes", ctx do
      %{group: group, value: value, member: member} = ctx
      {:ok, _tag} = Tags.add_tag(member, :value, value.id, "keep", :private)
      tag = tag_named!(member, "keep")
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#value-tag-list-#{value.id}-#{tag.id}")

      render_hook(lv, "toggle_reaction", %{"id" => to_string(value.id), "emoji" => "👍"})
      assert has_element?(lv, "#value-tag-list-#{value.id}-#{tag.id}")
    end

    test "a suggestion adds a tag in one click", ctx do
      %{group: group, value: value, member: member, owner: owner} = ctx
      {:ok, other} = Social.create_value(owner, group, %{"content" => "Other"})
      {:ok, _tag} = Tags.add_tag(member, :value, other.id, "ideas", :private)
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/values")

      lv |> element("#value-tags-#{value.id}") |> render_click()
      lv |> form("#tag-editor-form", tag: %{name: "ide"}) |> render_change()
      lv |> element("#tag-editor-suggestion-0", "ideas") |> render_click()

      tag = tag_named!(member, "ideas")
      assert has_element?(lv, "#value-tag-list-#{value.id}-#{tag.id}")
      refute has_element?(lv, "#tag-editor-suggestion-0")
    end

    test "an invalid name is refused with a message", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      lv |> element("#value-tags-#{ctx.value.id}") |> render_click()
      add_tag(lv, "a/b")

      # In the dialog, which covers the flash messages.
      assert has_element?(lv, "#tag-editor-error")
      assert has_element?(lv, "#tag-editor-empty")

      add_tag(lv, "fine")
      refute has_element?(lv, "#tag-editor-error")
    end

    test "items the profile cannot open do not open the editor", ctx do
      {_account, stranger} = account_with_profile!("gtag-stranger")
      elsewhere = group_with_members!(stranger, [])
      {:ok, hidden} = Social.create_value(stranger, elsewhere, %{"content" => "Secret"})
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      render_hook(lv, "tag_editor_open", %{"kind" => "value", "id" => to_string(hidden.id)})

      refute has_element?(lv, "#tag-editor")
      assert has_element?(lv, "#flash-error")
    end
  end

  describe "other items" do
    test "files carry tags in the files list", ctx do
      %{group: group, member: member, owner: owner} = ctx

      {:ok, value} =
        Social.create_value(owner, group, %{"content" => ""}, [
          %{
            storage_key: "gtag/#{System.unique_integer([:positive])}",
            filename: "plan.txt",
            content_type: "text/plain",
            byte_size: 4
          }
        ])

      [file] = PotokIde.Repo.preload(value, :attachments).attachments
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/files")

      lv |> element("#file-tags-#{file.id}") |> render_click()
      add_tag(lv, "docs")

      tag = tag_named!(member, "docs")
      assert has_element?(lv, "#file-tag-list-#{file.id}-#{tag.id}", "docs")
    end

    test "the group's own tags show in its header for every member", ctx do
      %{group: group, owner: owner} = ctx
      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/values")
      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{group.id}/values")

      owner_lv |> element("#group-tags-button") |> render_click()
      add_tag(owner_lv, "team", "public")

      tag = tag_named!(owner, "team")
      assert has_element?(owner_lv, "#group-tag-list-#{tag.id}", "team")
      assert has_element?(member_lv, "#group-tag-list-#{tag.id}", "team")
      assert has_element?(owner_lv, "#group-tags-browse[href='/tags?group=#{group.id}']")
    end

    test "sub-groups carry tags in the parent's list", ctx do
      %{group: group, member: member, owner: owner} = ctx
      child = group_with_members!(owner, [member], %{parent: group})
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/sub_groups")

      lv |> element("#child-group-tags-#{child.id}") |> render_click()
      add_tag(lv, "mine")

      tag = tag_named!(member, "mine")
      assert has_element?(lv, "#child-group-tag-list-#{child.id}-#{tag.id}")
    end

    test "a member puts public tags on itself in the members list", ctx do
      %{group: group, member: member, owner: owner} = ctx
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{group.id}/members")

      lv |> element("#member-tags-#{owner.id}") |> render_click()
      refute has_element?(lv, "#tag-editor-visibility")
      lv |> element("#tag-editor-close") |> render_click()

      lv |> element("#member-tags-#{member.id}") |> render_click()
      assert has_element?(lv, "#tag-editor-visibility")
      add_tag(lv, "designer", "public")

      tag = tag_named!(member, "designer")
      assert has_element?(lv, "#member-#{member.id}-tag-list-#{tag.id}")

      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{group.id}/members")
      assert has_element?(owner_lv, "#member-#{member.id}-tag-list-#{tag.id}", "designer")
    end

    test "an open event carries tags", ctx do
      %{group: group, member: member, owner: owner} = ctx
      date = today() |> Date.end_of_month() |> Date.add(10)
      event = create_event!(owner, group, event_attrs(date))

      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{group.id}/calendar?event=#{event.id}")

      lv |> element("#event-tags-#{event.id}") |> render_click()
      add_tag(lv, "match")

      tag = tag_named!(member, "match")
      assert has_element?(lv, "#event-tag-list-#{event.id}-#{tag.id}", "match")
    end
  end
end
