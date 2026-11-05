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
