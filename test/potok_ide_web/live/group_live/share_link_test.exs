defmodule PotokIdeWeb.GroupLive.ShareLinkTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Social

  setup do
    {account, owner} = account_with_profile!("share-owner")
    %{account: account, owner: owner}
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => zone()})
    |> live(path)
  end

  defp shared_link(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-share-link")
    |> List.first()
  end

  defp event_path(group, event), do: ~p"/groups/#{group.id}/calendar?#{[event: event.id]}"

  defp message_link(group, value),
    do: url(~p"/groups/#{group.id}/values?#{[value: value.id]}")

  describe "the page" do
    test "every page shares its own link from the top bar", %{account: account, owner: owner} do
      {_other_account, other} = account_with_profile!("share-page-other")

      private = group_with_members!(owner, [])
      {:ok, value} = Social.create_value(owner, private, %{"content" => "tema"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, private, value, %{"name" => "nit"})
      {:ok, direct} = Social.get_or_create_direct_group(owner, other)

      groups = [private, thread, direct, Social.get_root_group!()]

      for path <- Enum.map(groups, &~p"/groups/#{&1.id}") ++ [~p"/tags", ~p"/activity"] do
        {:ok, lv, _html} = live_as(account, path)

        # The link is read in the browser at the click, as an app may have moved it.
        assert has_element?(lv, "#nav-share-page[data-share-current]:not([hidden])"), path
        refute has_element?(lv, "#nav-share-page[data-share-link]"), path
      end
    end

    test "an account with no profile yet has nothing to share" do
      {:ok, lv, _html} = live_as(account_fixture(), ~p"/profiles")

      assert has_element?(lv, "#nav-share-page[hidden]")
    end
  end

  describe "a message" do
    test "has a link that opens the chat at it", %{account: account, owner: owner} do
      group = group_with_members!(owner, [])
      {:ok, value} = Social.create_value(owner, group, %{"content" => "tema"})

      {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}/values")

      assert shared_link(lv, "#value-link-#{value.id}") == message_link(group, value)
    end

    test "a reader of an open chat may take it too", %{owner: owner} do
      {reader, _profile} = account_with_profile!("share-reader")

      group =
        group_with_members!(owner, [], %{"is_public" => true, "has_public_chat" => true})

      {:ok, value} = Social.create_value(owner, group, %{"content" => "tema"})

      {:ok, lv, _html} = live_as(reader, ~p"/groups/#{group.id}/values")

      assert shared_link(lv, "#value-link-#{value.id}") == message_link(group, value)
    end

    test "in a thread it names the thread", %{account: account, owner: owner} do
      group = group_with_members!(owner, [])
      {:ok, origin} = Social.create_value(owner, group, %{"content" => "tema"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, origin, %{"name" => "nit"})
      {:ok, value} = Social.create_value(owner, thread, %{"content" => "odgovor"})

      {:ok, lv, _html} = live_as(account, ~p"/groups/#{thread.id}/values")

      assert shared_link(lv, "#value-link-#{value.id}") == message_link(thread, value)
    end

    test "not while it is being edited", %{account: account, owner: owner} do
      group = group_with_members!(owner, [])
      {:ok, value} = Social.create_value(owner, group, %{"content" => "tema"})

      {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}/values")
      lv |> element("#value-edit-#{value.id}") |> render_click()

      refute has_element?(lv, "#value-link-#{value.id}")
    end
  end

  describe "a group" do
    test "a public one can be shared by its link", %{account: account, owner: owner} do
      group = group_with_members!(owner, [], %{"is_public" => true})

      {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}")
      open_group_menu(lv)

      assert shared_link(lv, "#group-share-button") == url(~p"/groups/#{group.id}")
    end

    test "any other has nothing to show outside Potok", %{account: account, owner: owner} do
      {_other_account, other} = account_with_profile!("share-other")

      public = group_with_members!(owner, [], %{"is_public" => true})
      {:ok, value} = Social.create_value(owner, public, %{"content" => "tema"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, public, value, %{"name" => "nit"})
      {:ok, direct} = Social.get_or_create_direct_group(owner, other)
      private = group_with_members!(owner, [])

      for group <- [private, thread, direct, Social.get_root_group!()] do
        {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}")
        open_group_menu(lv)

        refute has_element?(lv, "#group-share-button")
      end
    end
  end

  describe "an event" do
    setup %{owner: owner} do
      %{group: group_with_members!(owner, []), date: Date.add(today(), 3)}
    end

    test "a public one can be shared by its link", ctx do
      event =
        create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))

      {:ok, lv, _html} = live_as(ctx.account, event_path(ctx.group, event))

      assert shared_link(lv, "#calendar-share") ==
               PotokIdeWeb.Endpoint.url() <> event_path(ctx.group, event)
    end

    test "a private one has no card to share", ctx do
      event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))

      {:ok, lv, _html} = live_as(ctx.account, event_path(ctx.group, event))

      assert has_element?(lv, "#calendar-event-detail")
      refute has_element?(lv, "#calendar-share")
    end

    test "a cancelled one has none either", ctx do
      event =
        create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))

      {:ok, _event} = Events.cancel_event(ctx.owner, event)

      {:ok, lv, _html} = live_as(ctx.account, event_path(ctx.group, event))

      assert has_element?(lv, "#calendar-event-detail")
      refute has_element?(lv, "#calendar-share")
    end
  end
end
