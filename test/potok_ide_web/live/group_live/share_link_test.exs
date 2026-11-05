defmodule PotokIdeWeb.GroupLive.ShareLinkTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
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

  describe "a group" do
    test "a public one can be shared by its link", %{account: account, owner: owner} do
      group = group_with_members!(owner, [], %{"is_public" => true})

      {:ok, lv, _html} = live_as(account, ~p"/groups/#{group.id}")

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
