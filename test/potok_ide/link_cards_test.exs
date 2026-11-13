defmodule PotokIde.LinkCardsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.ImageMagick
  alias PotokIde.Initials
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

  defp linked_image(group, app), do: group |> LinkCards.linked_card(app) |> LinkCards.image()

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

    test "of a group in an app follows the app's name and picture too", %{owner: owner} do
      story = group!(owner, %{"name" => "Most"})
      app = group!(owner, %{"name" => "Vesti"})
      version = story |> LinkCards.linked_card(app) |> LinkCards.version()

      refute version == story |> LinkCards.group_card() |> LinkCards.version()
      assert story |> LinkCards.linked_card(app) |> LinkCards.version() == version

      {:ok, renamed} = Social.update_group(owner, app, %{"name" => "Vesti iz kraja"})
      renamed_version = story |> LinkCards.linked_card(renamed) |> LinkCards.version()
      refute renamed_version == version

      {:ok, pictured} =
        Social.update_group(owner, renamed, %{"group_picture_url" => "https://example.com/a.png"})

      pictured_version = story |> LinkCards.linked_card(pictured) |> LinkCards.version()
      refute pictured_version == renamed_version

      {:ok, described} = Social.update_group(owner, pictured, %{"description" => "Novo"})
      assert story |> LinkCards.linked_card(described) |> LinkCards.version() == pictured_version
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

    test "a group in an app is its own card with the app's pill", %{owner: owner} do
      story = group!(owner, %{"name" => "Most"})
      app = group!(owner, %{"name" => "🌍 Vesti iz kraja"})
      card = LinkCards.linked_card(story, app)

      assert Map.delete(card, :app) == LinkCards.group_card(story)
      assert card.app.id == app.id
      assert card.app.name == "Vesti iz kraja"
      assert card.app.initials == Initials.of("Vesti iz kraja")
      # The colours of the app's avatar, which hashes the name as it is.
      assert card.app.colors == Initials.colors("🌍 Vesti iz kraja")
    end

    test "cuts a long name of the app in its pill", %{owner: owner} do
      app = group!(owner, %{"name" => String.duplicate("Vesti ", 10)})
      name = LinkCards.linked_card(group!(owner, %{"name" => "Most"}), app).app.name

      assert String.length(name) <= 24
      assert String.ends_with?(name, "…")
    end

    test "an app's name with nothing to draw leaves the group's own card", %{owner: owner} do
      story = group!(owner, %{"name" => "Most"})

      assert LinkCards.linked_card(story, group!(owner, %{"name" => "🌍🌍"})) ==
               LinkCards.group_card(story)
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

    test "draws a group in an app with the app's pill, whatever the pictures", %{owner: owner} do
      apps = [
        group!(owner, %{"name" => "Vesti"}),
        group!(owner, %{"name" => "Vesti", "group_picture_url" => data_url(png!(200, 200))})
      ]

      stories = [
        group!(owner, %{"name" => "Most"}),
        group!(owner, %{"name" => "Most", "group_picture_url" => data_url(png!(300, 300))}),
        group!(owner, %{"name" => "Most", "group_picture_url" => data_url(png!(1080, 608))})
      ]

      for app <- apps, story <- stories do
        story |> linked_image(app) |> assert_drawn(:whole)
      end
    end

    test "draws the app's initials for now, while its picture cannot be read", %{owner: owner} do
      Req.Test.stub(LinkPreviews, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      app =
        group!(owner, %{
          "name" => "Vesti",
          "group_picture_url" => "https://pictures.example/gone.png"
        })

      owner |> group!(%{"name" => "Most"}) |> linked_image(app) |> assert_drawn(:partial)
    end

    test "draws any name of an app", %{owner: owner} do
      story = group!(owner, %{"name" => "Most"})

      for name <- ["100% @tvoj \\n test %w", "@/etc/passwd", "Вести из краја"] do
        story |> linked_image(group!(owner, %{"name" => name})) |> assert_drawn(:whole)
      end
    end

    test "puts the pill across from Potok's mark, or over a photo across from Potok's pill",
         %{owner: owner} do
      app = group!(owner, %{"name" => "Vesti iz kraja"})
      top_right = fn {x, y, _width, height} -> x >= 740 and y + height <= 100 end
      bottom_left = fn {x, y, width, _height} -> x + width <= 440 and y >= 536 end

      for {attrs, where} <- [
            {%{}, top_right},
            {%{"group_picture_url" => data_url(png!(300, 300))}, top_right},
            {%{"group_picture_url" => data_url(png!(1080, 608))}, bottom_left}
          ] do
        story = group!(owner, Map.put(attrs, "name", "Most"))
        {:ok, plain, :whole} = card_image(story)
        {:ok, linked, :whole} = linked_image(story, app)

        assert where.(difference_box(plain, linked))
      end
    end

    # ImageMagick cut the marks off the first line when it centered a caption.
    test "draws the marks on capital letters of an app's name whole", %{owner: owner} do
      story = group!(owner, %{"name" => "Most"})
      # A blue picture, so the white in the pill is only the name.
      picture = data_url(png!(200, 200))

      marked =
        label_height(story, group!(owner, %{"name" => "ŽŠČĆ", "group_picture_url" => picture}))

      plain =
        label_height(story, group!(owner, %{"name" => "ZSCC", "group_picture_url" => picture}))

      assert marked / plain > 1.15
    end
  end

  defp huge_picture, do: <<0x89, "PNG", :binary.copy("x", 5_000_001)::binary>>

  # Where two drawings of a card differ, as `{x, y, width, height}`.
  defp difference_box(jpeg, other) do
    in_temp_file(fn first ->
      in_temp_file(fn second ->
        File.write!(first, jpeg)
        File.write!(second, other)

        {:ok, box} =
          ImageMagick.run(
            ["jpeg:" <> first, "jpeg:" <> second, "-compose", "difference", "-composite"] ++
              ["-colorspace", "Gray", "-threshold", "12%", "-format", "%@", "info:"]
          )

        [width, height, x, y] =
          ~r/(\d+)x(\d+)\+(\d+)\+(\d+)\s*\z/
          |> Regex.run(box, capture: :all_but_first)
          |> Enum.map(&String.to_integer/1)

        {x, y, width, height}
      end)
    end)
  end

  # In pixels, the white of the name in the pill of a card without a photo.
  defp label_height(story, app) do
    {:ok, jpeg, :whole} = linked_image(story, app)

    in_temp_file(fn path ->
      File.write!(path, jpeg)

      {:ok, height} =
        ImageMagick.run(
          [path, "-crop", "420x70+740+18", "+repage", "-colorspace", "Gray"] ++
            ["-threshold", "85%", "-trim", "-format", "%h", "info:"]
        )

      String.to_integer(height)
    end)
  end

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
