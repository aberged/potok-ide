defmodule PotokIdeWeb.GroupLive.ValueSearchTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("search-owner")
    {member_account, member} = account_with_profile!("search-member")
    group = group_with_members!(owner, [member])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
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

  defp search!(group, query, opts \\ []) do
    {:ok, {values, more?}} = Social.search_group_values(group, query, opts)
    {Enum.map(values, & &1.content), more?}
  end

  defp thread!(profile, group, value, name) do
    {:ok, thread} = Social.get_or_create_value_thread(profile, group, value, %{"name" => name})
    thread
  end

  describe "search_group_values/3" do
    test "matches without case, diacritics or script, newest first", ctx do
      post!(ctx.owner, ctx.group, "Idemo u Čačak")
      post!(ctx.owner, ctx.group, "Нешто друго")
      post!(ctx.member, ctx.group, "ЧАЧАК је близу")
      post!(ctx.owner, ctx.group, "cacak, **opet**")

      assert search!(ctx.group, "čačak") ==
               {["cacak, **opet**", "ЧАЧАК је близу", "Idemo u Čačak"], false}

      assert search!(ctx.group, "ЧАЧ") == search!(ctx.group, "cac")
      assert search!(ctx.group, "xyz") == {[], false}
    end

    test "pages from the oldest value found", ctx do
      values = for n <- 1..5, do: post!(ctx.owner, ctx.group, "page #{n}")

      {:ok, {first, true}} = Social.search_group_values(ctx.group, "page", limit: 2)
      assert Enum.map(first, & &1.content) == ["page 5", "page 4"]

      {:ok, {next, true}} =
        Social.search_group_values(ctx.group, "page", limit: 2, before_id: List.last(first).id)

      assert Enum.map(next, & &1.content) == ["page 3", "page 2"]

      {:ok, {last, false}} =
        Social.search_group_values(ctx.group, "page", limit: 2, before_id: List.last(next).id)

      assert Enum.map(last, & &1.id) == [hd(values).id]
    end

    test "takes LIKE's own characters as themselves and leaves out app data", ctx do
      post!(ctx.owner, ctx.group, "100% sigurno")
      post!(ctx.owner, ctx.group, "100 posto")

      {:ok, _data} =
        Social.create_data_value(ctx.owner, ctx.group, %{"content" => "100% data", "data" => %{}})

      term = Social.NameSearch.term("100%")
      assert search!(ctx.group, term) == {["100% sigurno"], false}
    end

    test "searches the threads a member is in only when asked", ctx do
      origin = post!(ctx.owner, ctx.group, "start")
      thread = thread!(ctx.owner, ctx.group, origin, "nit")
      post!(ctx.owner, thread, "proslava u niti")
      post!(ctx.owner, ctx.group, "proslava u chatu")

      assert search!(ctx.group, "proslava") == {["proslava u chatu"], false}

      assert search!(ctx.group, "proslava", threads_for: ctx.member) ==
               {["proslava u chatu", "proslava u niti"], false}

      {_outsider_account, outsider} = account_with_profile!("search-outsider")

      assert search!(ctx.group, "proslava", threads_for: outsider) ==
               {["proslava u chatu"], false}
    end

    test "an outsider does not find announcements of events that are not public", ctx do
      create_event!(ctx.owner, ctx.group, event_attrs(today(), %{"title" => "Tajni sastanak"}),
        announce: true
      )

      create_event!(
        ctx.owner,
        ctx.group,
        event_attrs(today(), %{"title" => "Javni sastanak", "is_public" => "true"}),
        announce: true
      )

      assert {[_public, _secret], false} = search!(ctx.group, "sastanak")
      assert {[public], false} = search!(ctx.group, "sastanak", outsider: true)
      assert public =~ "Javni"
    end
  end

  describe "the dialog" do
    test "the magnifier shows only on the chat", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      assert has_element?(lv, "#group-search-messages")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/files")
      refute has_element?(lv, "#group-search-messages")
    end

    test "finds messages, lights the match and opens one in the feed", ctx do
      older = post!(ctx.owner, ctx.group, "Krećemo u Čačak u osam")
      post!(ctx.owner, ctx.group, "nešto drugo")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      refute has_element?(lv, "#value-search-dialog")

      lv |> element("#group-search-messages") |> render_click()
      assert has_element?(lv, "#value-search-dialog #value-search-status-idle")

      lv |> form("#value-search-form", value_search: %{q: "c"}) |> render_change()
      assert has_element?(lv, "#value-search-status-idle")

      lv |> form("#value-search-form", value_search: %{q: "cacak"}) |> render_change()

      assert has_element?(lv, "#value-search-result-#{older.id}")

      assert has_element?(
               lv,
               "#value-search-result-#{older.id} span[class*='bg-yellow']",
               "Čačak"
             )

      assert has_element?(lv, "button#value-search-open-#{older.id}")

      lv |> element("#value-search-open-#{older.id}") |> render_click()
      refute has_element?(lv, "#value-search-dialog")
    end

    test "says when nothing is found and pages on", ctx do
      for n <- 1..25, do: post!(ctx.owner, ctx.group, "poruka broj #{n}")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      lv |> element("#group-search-messages") |> render_click()

      lv |> form("#value-search-form", value_search: %{q: "nema toga"}) |> render_change()
      assert has_element?(lv, "#value-search-status-empty")

      lv |> form("#value-search-form", value_search: %{q: "broj"}) |> render_change()
      refute has_element?(lv, "#value-search-status-empty")

      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#value-search-results > li")
             |> Enum.count() == 20

      lv |> element("#value-search-more") |> render_click()

      assert lv
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#value-search-results > li")
             |> Enum.count() == 25

      refute has_element?(lv, "#value-search-more")
    end

    test "a message from a thread links to the thread", ctx do
      origin = post!(ctx.owner, ctx.group, "start")
      thread = thread!(ctx.owner, ctx.group, origin, "nit")
      in_thread = post!(ctx.owner, thread, "proslava u niti")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      lv |> element("#group-search-messages") |> render_click()
      lv |> form("#value-search-form", value_search: %{q: "proslava"}) |> render_change()

      assert has_element?(
               lv,
               "a#value-search-open-#{in_thread.id}[href='/groups/#{thread.id}/values?value=#{in_thread.id}']"
             )
    end

    test "closes from its button", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      lv |> element("#group-search-messages") |> render_click()
      lv |> element("#value-search-close") |> render_click()
      refute has_element?(lv, "#value-search-dialog")
    end
  end
end
