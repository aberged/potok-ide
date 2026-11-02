defmodule PotokIdeWeb.TagLive.IndexTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Tags

  setup do
    {owner_account, owner} = account_with_profile!("tpage-owner")
    {member_account, member} = account_with_profile!("tpage-member")
    group = group_with_members!(owner, [member])
    {:ok, value} = Social.create_value(owner, group, %{"content" => "Spring plans"})

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
    |> live(path)
  end

  describe "the directory" do
    test "lists the profile's private tags and the public tags in use", ctx do
      %{owner: owner, member: member, value: value} = ctx
      {:ok, mine} = Tags.add_tag(member, :value, value.id, "later", :private)
      {:ok, public} = Tags.add_tag(owner, :value, value.id, "news", :public)
      {:ok, theirs} = Tags.add_tag(owner, :value, value.id, "owner-only", :private)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags")

      # The app header links here, next to the invitations.
      assert has_element?(lv, "#nav-tags-link[href='/tags']")
      assert has_element?(lv, "#tags-mine-#{mine.id}", "later")
      assert has_element?(lv, "#tags-public-#{public.id}", "news")
      refute has_element?(lv, "#tags-mine-#{theirs.id}")

      lv |> form("#tags-filter-form", filter: %{q: "lat"}) |> render_change()
      assert has_element?(lv, "#tags-mine-#{mine.id}")
      refute has_element?(lv, "#tags-public-#{public.id}")
    end

    test "renames and deletes private tags", ctx do
      {:ok, tag} = Tags.add_tag(ctx.member, :value, ctx.value.id, "draft", :private)
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags")

      lv |> element("#tags-rename-#{tag.id}") |> render_click()

      lv
      |> form("#tags-rename-form-#{tag.id}", tag: %{name: "final"})
      |> render_submit()

      assert has_element?(lv, "#tags-mine-#{tag.id}", "final")

      lv |> element("#tags-delete-#{tag.id}") |> render_click()
      refute has_element?(lv, "#tags-mine-#{tag.id}")
      assert has_element?(lv, "#tags-directory-mine-empty")
    end

    test "a tag opens the items that carry it", ctx do
      {:ok, tag} = Tags.add_tag(ctx.member, :value, ctx.value.id, "later", :private)
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags")

      lv |> element("#tags-mine-link-#{tag.id}") |> render_click()

      assert_patch(lv, ~p"/tags?t=#{tag.id}")
      assert has_element?(lv, "#tags-selected-#{tag.id}")
      assert has_element?(lv, "#tagged-value-#{ctx.value.id}", "Spring plans")
    end
  end

  describe "results" do
    test "show items carrying every chosen tag, by kind", ctx do
      %{owner: owner, member: member, group: group, value: value} = ctx
      {:ok, other} = Social.create_value(owner, group, %{"content" => "Autumn plans"})
      {:ok, plans} = Tags.add_tag(owner, :value, value.id, "plans", :public)
      {:ok, ^plans} = Tags.add_tag(owner, :value, other.id, "plans", :public)
      {:ok, ^plans} = Tags.add_tag(owner, :group, group.id, "plans", :public)
      {:ok, mine} = Tags.add_tag(member, :value, value.id, "mine", :private)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags?t=#{plans.id}")

      assert has_element?(lv, "#tagged-value-#{value.id}")
      assert has_element?(lv, "#tagged-value-#{other.id}")
      assert has_element?(lv, "#tagged-group-#{group.id}")
      assert has_element?(lv, "#tags-kind-values", "2")

      # A suggestion narrows the results to items with both tags.
      lv |> element("#tags-filter-suggestion-#{mine.id}") |> render_click()
      assert_patch(lv, ~p"/tags?#{[t: "#{plans.id},#{mine.id}"]}")
      assert has_element?(lv, "#tagged-value-#{value.id}")
      refute has_element?(lv, "#tagged-value-#{other.id}")
      refute has_element?(lv, "#tagged-group-#{group.id}")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags?t=#{plans.id}&kind=groups")
      assert has_element?(lv, "#tags-section-groups")
      refute has_element?(lv, "#tags-section-values")
    end

    test "stay inside a group and its sub-groups", ctx do
      %{owner: owner, member: member, group: group, value: value} = ctx
      sibling = group_with_members!(owner, [member])
      {:ok, elsewhere} = Social.create_value(owner, sibling, %{"content" => "Elsewhere"})
      {:ok, tag} = Tags.add_tag(member, :value, value.id, "x", :private)
      {:ok, ^tag} = Tags.add_tag(member, :value, elsewhere.id, "x", :private)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags?t=#{tag.id}&group=#{group.id}")

      assert has_element?(lv, "#tags-scope", group.name)
      assert has_element?(lv, "#tagged-value-#{value.id}")
      refute has_element?(lv, "#tagged-value-#{elsewhere.id}")

      lv |> element("#tags-scope-remove") |> render_click()
      assert has_element?(lv, "#tagged-value-#{elsewhere.id}")
    end

    test "never show what the profile cannot open or others' private tags", ctx do
      %{owner: owner, value: value} = ctx
      {:ok, public} = Tags.add_tag(owner, :value, value.id, "news", :public)
      {:ok, private} = Tags.add_tag(owner, :value, value.id, "secret", :private)

      {stranger_account, _stranger} = account_with_profile!("tpage-stranger")
      {:ok, lv, _html} = live_as(stranger_account, ~p"/tags?t=#{public.id}")

      refute has_element?(lv, "#tagged-value-#{value.id}")
      assert has_element?(lv, "#tags-no-results")

      # Another profile's private tag is dropped from the filter.
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/tags?t=#{private.id}")
      refute has_element?(lv, "#tags-selected-#{private.id}")
      assert has_element?(lv, "#tags-directory")

      # Its owner filters by it.
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/tags?t=#{private.id}")
      assert has_element?(lv, "#tags-selected-#{private.id}")
    end

    test "load more values page by page", ctx do
      %{owner: owner, group: group} = ctx

      values =
        for n <- 1..31 do
          {:ok, value} = Social.create_value(owner, group, %{"content" => "Value #{n}"})
          value
        end

      tag =
        values
        |> Enum.map(fn value ->
          {:ok, tag} = Tags.add_tag(owner, :value, value.id, "many", :private)
          tag
        end)
        |> hd()

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/tags?t=#{tag.id}&kind=values")

      refute has_element?(lv, "#tagged-value-#{hd(values).id}")
      lv |> element("#tags-load-more-values") |> render_click()
      assert has_element?(lv, "#tagged-value-#{hd(values).id}")
      refute has_element?(lv, "#tags-load-more-values")
    end
  end
end
