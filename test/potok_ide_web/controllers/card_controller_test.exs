defmodule PotokIdeWeb.CardControllerTest do
  # Swaps the drawing for a stub, which `PotokIde.LinkCardsTest` must not see.
  use PotokIdeWeb.ConnCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Repo
  alias PotokIde.Social

  @huge_id "99999999999999999999999"

  setup do
    {_account, owner} = account_with_profile!("card-owner")
    test_pid = self()

    paint = fn card, _picture ->
      send(test_pid, {:painted, card.kind, card.id})
      {:ok, "drawn", :whole}
    end

    Application.put_env(:potok_ide, PotokIde.LinkCards, paint: paint)
    on_exit(fn -> Application.delete_env(:potok_ide, PotokIde.LinkCards) end)

    %{owner: owner}
  end

  defp stub_paint(fun), do: Application.put_env(:potok_ide, PotokIde.LinkCards, paint: fun)

  defp group!(owner, attrs \\ %{}),
    do: group_with_members!(owner, [], Map.merge(%{"is_public" => true}, attrs))

  defp group_card(id), do: "/cards/group/#{id}.jpg"
  defp event_card(id), do: "/cards/event/#{id}.jpg"

  defp public_event!(owner, attrs \\ %{}) do
    create_event!(
      owner,
      group_with_members!(owner, []),
      event_attrs(Date.add(today(), 3), Map.merge(%{"is_public" => "true"}, attrs))
    )
  end

  defp assert_nothing(conn) do
    assert response(conn, 404) == ""
  end

  describe "the card of a group" do
    test "is a picture that may be kept for good", %{conn: conn, owner: owner} do
      conn = get(conn, group_card(group!(owner).id))

      assert response(conn, 200) == "drawn"
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "sets no session", %{conn: conn, owner: owner} do
      conn = get(conn, group_card(group!(owner).id))

      assert get_resp_header(conn, "set-cookie") == []
    end

    test "is drawn once, whatever address asks for it", %{conn: conn, owner: owner} do
      group = group!(owner)
      id = group.id

      for version <- ["a", "b", "c"] do
        assert conn |> get(group_card(id) <> "?v=" <> version) |> response(200) == "drawn"
      end

      assert_received {:painted, :group, ^id}
      refute_received {:painted, :group, ^id}
    end

    test "that lost its picture is kept only for a while", %{conn: conn, owner: owner} do
      stub_paint(fn _card, _picture -> {:ok, "without it", :partial} end)

      conn = get(conn, group_card(group!(owner).id))

      assert response(conn, 200) == "without it"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    test "that cannot be drawn is Potok's picture for a while", %{conn: conn, owner: owner} do
      stub_paint(fn _card, _picture -> :error end)

      conn = get(conn, group_card(group!(owner).id))

      assert response(conn, 200) == File.read!("priv/static/images/og.png")
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    end

    @tag :capture_log
    test "survives a drawing that falls apart", %{conn: conn, owner: owner} do
      stub_paint(fn _card, _picture -> raise "no" end)

      assert conn |> get(group_card(group!(owner).id)) |> response(200)
    end
  end

  describe "what guests cannot see" do
    test "looks like nothing", %{conn: conn, owner: owner} do
      {_other_account, other} = account_with_profile!("card-other")

      private = group_with_members!(owner, [])
      {:ok, direct} = Social.get_or_create_direct_group(owner, other)

      public = group!(owner)
      {:ok, value} = Social.create_value(owner, public, %{"content" => "tema"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, public, value, %{"name" => "nit"})

      for id <- [private.id, direct.id, thread.id, Social.get_root_group!().id] do
        conn |> get(group_card(id)) |> assert_nothing()
      end
    end

    test "a link to nothing looks the same", %{conn: conn} do
      for file <- ["0.jpg", "-1.jpg", "abc.jpg", "1.5.jpg", "#{@huge_id}.jpg", "999999.jpg"] do
        conn |> get("/cards/group/#{file}") |> assert_nothing()
        conn |> get("/cards/event/#{file}") |> assert_nothing()
      end
    end

    test "a group that closed is gone at once, even in the cache", %{conn: conn, owner: owner} do
      group = group!(owner)

      assert conn |> get(group_card(group.id)) |> response(200)

      group |> Ecto.Changeset.change(is_public: false) |> Repo.update!()

      conn |> get(group_card(group.id)) |> assert_nothing()
    end
  end

  describe "the card of a group in an app" do
    setup %{owner: owner} do
      app = group!(owner, %{"name" => "Vesti"})
      feed = group!(owner, %{:parent => app, "name" => ".feed"})
      story = group!(owner, %{:parent => feed, "name" => "Most"})

      %{app: app, feed: feed, story: story}
    end

    defp linked_card(app_id, file), do: "/cards/group/#{app_id}/#{file}"

    test "is a picture that may be kept for good, drawn apart from the group's own", ctx do
      id = ctx.story.id
      conn = get(ctx.conn, linked_card(ctx.app.id, "#{id}.jpg"))

      assert response(conn, 200) == "drawn"
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(conn, "set-cookie") == []
      assert_received {:painted, :group, ^id}

      assert ctx.conn |> get(group_card(id)) |> response(200) == "drawn"
      assert_received {:painted, :group, ^id}
    end

    test "is there for a direct sub-group of the app too", ctx do
      child = group!(ctx.owner, %{:parent => ctx.app, "name" => "Dete"})

      assert ctx.conn |> get(linked_card(ctx.app.id, "#{child.id}.jpg")) |> response(200) ==
               "drawn"
    end

    test "looks like nothing where guests do not reach the group through the app", ctx do
      other = group!(ctx.owner)
      deeper = group!(ctx.owner, %{:parent => ctx.story, "name" => "Dublje"})
      hidden = group_with_members!(ctx.owner, [], %{:parent => ctx.feed, "name" => "Skriveno"})
      closed = group_with_members!(ctx.owner, [], %{:parent => ctx.app, "name" => ".zatvoreno"})
      under_closed = group!(ctx.owner, %{:parent => closed, "name" => "Ispod"})
      private_app = group_with_members!(ctx.owner, [])
      in_private_app = group!(ctx.owner, %{:parent => private_app, "name" => "Javno"})

      for {app_id, id} <- [
            {ctx.app.id, other.id},
            {ctx.app.id, deeper.id},
            {ctx.app.id, hidden.id},
            {ctx.app.id, under_closed.id},
            {private_app.id, in_private_app.id},
            {ctx.app.id, ctx.app.id}
          ] do
        ctx.conn |> get(linked_card(app_id, "#{id}.jpg")) |> assert_nothing()
      end

      for {app_id, file} <- [
            {"abc", "#{ctx.story.id}.jpg"},
            {"0", "#{ctx.story.id}.jpg"},
            {@huge_id, "#{ctx.story.id}.jpg"},
            {ctx.app.id, "abc.jpg"},
            {ctx.app.id, "#{@huge_id}.jpg"}
          ] do
        ctx.conn |> get(linked_card(app_id, file)) |> assert_nothing()
      end
    end

    test "is gone at once when the group or the app closes, even in the cache", ctx do
      path = linked_card(ctx.app.id, "#{ctx.story.id}.jpg")
      assert ctx.conn |> get(path) |> response(200)

      closed = ctx.story |> Ecto.Changeset.change(is_public: false) |> Repo.update!()
      ctx.conn |> get(path) |> assert_nothing()

      closed |> Ecto.Changeset.change(is_public: true) |> Repo.update!()
      assert ctx.conn |> get(path) |> response(200)

      ctx.app |> Ecto.Changeset.change(is_public: false) |> Repo.update!()
      ctx.conn |> get(path) |> assert_nothing()
    end
  end

  describe "the card of an event" do
    test "is a picture too, even in a private group", %{conn: conn, owner: owner} do
      event = public_event!(owner)
      id = event.id

      conn = get(conn, event_card(id))

      assert response(conn, 200) == "drawn"
      assert_received {:painted, :event, ^id}
    end

    test "a private event looks like nothing", %{conn: conn, owner: owner} do
      event = create_event!(owner, group!(owner), event_attrs(today()))

      conn |> get(event_card(event.id)) |> assert_nothing()
    end

    test "a cancelled event is gone", %{conn: conn, owner: owner} do
      event = public_event!(owner)
      {:ok, _event} = Events.cancel_event(owner, event)

      conn |> get(event_card(event.id)) |> assert_nothing()
    end
  end
end
