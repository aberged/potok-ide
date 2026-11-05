defmodule PotokIde.LinkCardsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.ImageMagick
  alias PotokIde.LinkCards
  alias PotokIde.LinkPreviews
  alias PotokIde.Social

  @moduletag :capture_log

  setup do
    {_account, owner} = account_with_profile!("card-owner")
    %{owner: owner}
  end

  defp group!(owner, attrs \\ %{}),
    do: group_with_members!(owner, [], Map.merge(%{"is_public" => true}, attrs))

  defp public_event!(owner, attrs \\ %{}) do
    create_event!(
      owner,
      group!(owner),
      event_attrs(Date.add(today(), 3), Map.merge(%{"is_public" => "true"}, attrs))
    )
  end

  defp in_temp_file(fun) do
    path = Path.join(System.tmp_dir!(), "card_test_#{System.unique_integer([:positive])}")

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp png!(width, height) do
    in_temp_file(fn path ->
      {:ok, _} = ImageMagick.run(["-size", "#{width}x#{height}", "xc:#2e8fde", "png:" <> path])
      File.read!(path)
    end)
  end

  defp data_url(bytes, type \\ "image/png"), do: "data:#{type};base64," <> Base.encode64(bytes)

  defp format_of(jpeg) do
    in_temp_file(fn path ->
      File.write!(path, jpeg)
      {:ok, format} = ImageMagick.run([path, "-format", "%m %w %h", "info:"])
      format
    end)
  end

  defp card_image(group), do: group |> LinkCards.group_card() |> LinkCards.image()

  defp assert_drawn({:ok, jpeg, completeness}, expected) do
    assert completeness == expected
    assert format_of(jpeg) == "JPEG 1200 630"
    jpeg
  end

  describe "version/1" do
    test "stays with what is drawn and changes with it", %{owner: owner} do
      group = group!(owner, %{"name" => "Komšije"})
      version = group |> LinkCards.group_card() |> LinkCards.version()

      assert group |> LinkCards.group_card() |> LinkCards.version() == version

      {:ok, renamed} = Social.update_group(owner, group, %{"name" => "Komšije 2"})
      renamed_version = renamed |> LinkCards.group_card() |> LinkCards.version()
      assert renamed_version != version

      {:ok, pictured} =
        Social.update_group(owner, renamed, %{"group_picture_url" => "https://example.com/a.png"})

      assert pictured |> LinkCards.group_card() |> LinkCards.version() != renamed_version

      {:ok, described} = Social.update_group(owner, pictured, %{"description" => "Novo"})

      assert described |> LinkCards.group_card() |> LinkCards.version() ==
               pictured |> LinkCards.group_card() |> LinkCards.version()
    end
  end

  describe "what a card says" do
    test "keeps what the font has", %{owner: owner} do
      for {name, title} <- [
            {"🌍Potoktok", "Potoktok"},
            {"Čačak, Ћирилица и 100%", "Čačak, Ћирилица и 100%"},
            {"  dva   razmaka ", "dva razmaka"}
          ] do
        assert LinkCards.group_card(group!(owner, %{"name" => name})).title == title
      end
    end

    test "cuts a long name", %{owner: owner} do
      title = LinkCards.group_card(group!(owner, %{"name" => String.duplicate("reč ", 30)})).title

      assert String.length(title) <= 90
      assert String.ends_with?(title, "…")
    end

    test "an event shows when and where, and nothing of its group", %{owner: owner} do
      group = group!(owner, %{"name" => "Tajna grupa"})

      event =
        create_event!(
          owner,
          group,
          event_attrs(Date.add(today(), 3), %{"is_public" => "true", "location" => "Ada"})
        )

      card = LinkCards.event_card(event)

      assert card.line =~ "18:00–19:30"
      assert card.line =~ "Ada"
      assert card.day == Integer.to_string(Date.add(today(), 3).day)
      refute inspect(card) =~ "Tajna grupa"
    end

    test "an event is in the default language for everybody", %{owner: owner} do
      event = public_event!(owner)

      assert Gettext.with_locale(PotokIdeWeb.Gettext, "en", fn -> LinkCards.event_card(event) end) ==
               Gettext.with_locale(PotokIdeWeb.Gettext, "sr", fn ->
                 LinkCards.event_card(event)
               end)
    end

    test "a series shows its next occurrence", %{owner: owner} do
      # Tomorrow is the next occurrence at any time of day; today's could be
      # either side of 18:00.
      start = Date.add(today(), -13)

      event =
        create_event!(
          owner,
          group!(owner),
          event_attrs(start, %{
            "is_public" => "true",
            "recurrence" => "weekly",
            "recurrence_weekdays" => [Integer.to_string(Date.day_of_week(start))]
          })
        )

      assert LinkCards.event_card(event).day == Integer.to_string(Date.add(today(), 1).day)
    end
  end

  describe "escape/1" do
    test "leaves nothing for ImageMagick to read as its own" do
      assert LinkCards.escape("100%") == "100%%"
      assert LinkCards.escape("%w %h") == "%%w %%h"
      assert LinkCards.escape("a\\nb") == "a\\\\nb"
      assert LinkCards.escape("@/etc/passwd") == "\\@/etc/passwd"
      assert LinkCards.escape("mejl@potok.rs") == "mejl@potok.rs"
    end
  end

  describe "image/1" do
    @describetag :imagemagick

    test "draws a group without a picture", %{owner: owner} do
      owner |> group!() |> card_image() |> assert_drawn(:whole)
    end

    test "draws a logo in a tile, however small", %{owner: owner} do
      for {width, height} <- [{150, 150}, {200, 105}, {300, 500}] do
        owner
        |> group!(%{"group_picture_url" => data_url(png!(width, height))})
        |> card_image()
        |> assert_drawn(:whole)
      end
    end

    test "fills the card with a wide photo", %{owner: owner} do
      owner
      |> group!(%{"group_picture_url" => data_url(png!(1080, 608))})
      |> card_image()
      |> assert_drawn(:whole)
    end

    test "draws any name", %{owner: owner} do
      for name <- ["100% @tvoj \\n test %w", "@/etc/passwd", String.duplicate("дуго име ", 13)] do
        owner |> group!(%{"name" => name}) |> card_image() |> assert_drawn(:whole)
      end
    end

    # ImageMagick cut the marks off the first line when it centered a caption.
    test "draws the marks on capital letters whole", %{owner: owner} do
      marked = text_height(group!(owner, %{"name" => "ŽŠČĆ ŽŠČĆ"}))
      plain = text_height(group!(owner, %{"name" => "ZSCC ZSCC"}))

      assert marked / plain > 1.3
    end

    test "takes a picture from another site", %{owner: owner} do
      png = png!(400, 400)

      Req.Test.stub(LinkPreviews, fn
        %{request_path: "/moved.png"} = conn ->
          conn |> Plug.Conn.put_resp_header("location", "/a.png") |> Plug.Conn.send_resp(302, "")

        conn ->
          Plug.Conn.send_resp(conn, 200, png)
      end)

      owner
      |> group!(%{"group_picture_url" => "https://pictures.example/moved.png"})
      |> card_image()
      |> assert_drawn(:whole)
    end

    test "does not ask for an SVG, which it cannot draw", %{owner: owner} do
      test_pid = self()

      Req.Test.stub(LinkPreviews, fn conn ->
        send(test_pid, :requested)
        Plug.Conn.send_resp(conn, 200, "<svg></svg>")
      end)

      for picture <- [
            "https://deoba.example/favicon.svg",
            data_url("<svg></svg>", "image/svg+xml")
          ] do
        owner |> group!(%{"group_picture_url" => picture}) |> card_image() |> assert_drawn(:whole)
      end

      refute_received :requested
    end

    test "does without a picture that cannot be read, for now", %{owner: owner} do
      Req.Test.stub(LinkPreviews, fn
        %{request_path: "/gone.png"} = conn -> Plug.Conn.send_resp(conn, 404, "")
        %{request_path: "/page.png"} = conn -> Plug.Conn.send_resp(conn, 200, "<html></html>")
        %{request_path: "/huge.png"} = conn -> Plug.Conn.send_resp(conn, 200, huge_picture())
      end)

      for picture <- [
            "https://pictures.example/gone.png",
            "https://pictures.example/page.png",
            "https://pictures.example/huge.png",
            "https://pictures.internal.test/a.png",
            data_url("not a picture"),
            "data:image/png;base64,not base64"
          ] do
        owner
        |> group!(%{"group_picture_url" => picture})
        |> card_image()
        |> assert_drawn(:partial)
      end
    end

    test "survives a file that only looks like a picture", %{owner: owner} do
      broken = <<0x89, "PNG", :binary.copy("x", 200)::binary>>

      owner
      |> group!(%{"group_picture_url" => data_url(broken)})
      |> card_image()
      |> assert_drawn(:partial)
    end

    test "draws an event", %{owner: owner} do
      owner
      |> public_event!()
      |> LinkCards.event_card()
      |> LinkCards.image()
      |> assert_drawn(:whole)
    end

    test "gives up on a name with nothing to draw", %{owner: owner} do
      assert owner |> group!(%{"name" => "🌍🌍"}) |> card_image() == :error
    end

    test "a wide photo needs no name", %{owner: owner} do
      owner
      |> group!(%{"name" => "🌍🌍", "group_picture_url" => data_url(png!(1080, 608))})
      |> card_image()
      |> assert_drawn(:whole)
    end
  end

  defp huge_picture, do: <<0x89, "PNG", :binary.copy("x", 5_000_001)::binary>>

  # In pixels, in the part of the card that holds the name.
  defp text_height(group) do
    {:ok, jpeg, :whole} = card_image(group)

    in_temp_file(fn path ->
      File.write!(path, jpeg)

      {:ok, height} =
        ImageMagick.run([
          path,
          "-crop",
          "1040x270+80+206",
          "+repage",
          "-colorspace",
          "Gray",
          "-threshold",
          "85%",
          "-trim",
          "-format",
          "%h",
          "info:"
        ])

      String.to_integer(height)
    end)
  end
end
