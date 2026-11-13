defmodule PotokIde.LinkCards do
  @moduledoc """
  The picture on the card of a shared link to a public group or event, drawn
  here at 1200x630, so that it suits every site that shows cards and does not
  depend on another server keeping a picture online.

  A wide photo fills the card. Any other picture sits in a tile above the name,
  and the mark stands in for a group without one. An event shows its date and
  never its group, which may be private. The parts are in `priv/cards`, made by
  `build.sh` there.

  A group a link into an app names (`linked_card/2`, such as a story of a
  feed) also carries the app in a pill like Potok's own: the app's picture in
  a circle, or its initials on its colour as the app shows them, and its name.
  The pill stands top right, across from Potok's mark, or bottom left over a
  wide photo, across from Potok's pill.

  `version/1` is a hash of everything that is drawn. Sites keep a picture by its
  address, so the address changes with the content, and as it comes from the
  data and not from what is asked for, nobody can ask for endless new drawings.
  Raise `@design` when the look of the cards changes.
  """

  require Logger

  alias PotokIde.Events.{Event, Format, Recurrence}
  alias PotokIde.ImageMagick
  alias PotokIde.Initials
  alias PotokIde.LinkPreviews.HTTP
  alias PotokIde.PlainText
  alias PotokIde.{RenderCache, Renderers}
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIdeWeb.Locale

  @design 1

  # A whole card is kept on disk (`PotokIde.RenderCache`) as long as its
  # version stands; a partial one or a failure is remembered in memory, for a
  # short time, as the picture may be back soon.
  @disk_max_age :timer.hours(24 * 7)
  @cache_ttl :timer.minutes(15)
  # Each step of a download has its own limits, and with redirects those add up
  # to half a minute.
  @download_timeout 6_000

  @limits ~w(-limit memory 128MiB -limit map 256MiB -limit disk 256MiB) ++
            ~w(-limit area 64MP -limit width 12000 -limit height 12000 -limit time 15)
  @jpeg ~w(-strip -sampling-factor 4:2:0 -interlace JPEG -quality 82)

  # At least this wide and this much wider than high, a picture is a photo to
  # show whole rather than a logo.
  @photo_width 600
  @photo_ratio 1.3

  @max_title 90
  @max_line 60
  @max_label 24

  # The app's pill copies Potok's own (`priv/cards/build.sh`): its height,
  # round ends, colour and type, with the app's picture where Potok's mark is.
  # Raise `@pill_design` when its look changes: only the cards with a pill are
  # drawn again.
  @pill_design 1
  @pill_height 56
  @pill_color "#0a47a3cc"
  @pill_text 22
  @pill_avatar 40
  # Wider names are drawn smaller. The widest pill stays clear of the tile, the
  # mark and the title on the plain layouts, and of Potok's pill over a photo.
  @max_pill_text 340
  # Text sizes by length. ImageMagick can fit a text to a box itself, but that
  # took over 15 s.
  @plain_sizes [{14, 96}, {28, 80}, {56, 64}, {@max_title, 48}]
  @tile_sizes [{30, 62}, {64, 50}, {@max_title, 40}]
  @event_sizes [{30, 58}, {64, 46}, {@max_title, 38}]

  @svg_picture ~r/^data:image\/svg|\.svg([?#]|$)/i
  @undrawable ~r/[^\p{Latin}\p{Cyrillic}\p{Greek}\p{N}\p{P}\p{Zs}\p{Sm}\p{Sc}]/u

  @doc "What the card of a public group shows."
  def group_card(%Group{} = group) do
    %{
      kind: :group,
      id: group.id,
      title: title(group.name),
      picture: Social.group_picture_hash(group.id)
    }
  end

  @doc """
  What the card of `group` shows where a link into the app of `app` names it
  (`PotokIdeWeb.PublicPreview.linked_groups/2`): the group's card and the
  app's pill. The group's plain card when nothing of the app's name can be
  drawn. The initials and their colours are the app's avatar's
  (`PotokIde.Initials`), so the pill looks like the group in Potok.
  """
  def linked_card(%Group{} = group, %Group{} = app) do
    case app.name |> drawable() |> cut(@max_label) do
      "" ->
        group_card(group)

      label ->
        group
        |> group_card()
        |> Map.put(:app, %{
          id: app.id,
          name: label,
          picture: Social.group_picture_hash(app.id),
          initials: app.name |> drawable() |> Initials.of(),
          colors: Initials.colors(app.name),
          look: @pill_design
        })
    end
  end

  @doc """
  What the card of a public event shows, in the default language, as one address
  serves everybody: its next occurrence, or the first one of a series that is
  over, so the address changes as the series moves on.
  """
  def event_card(%Event{} = event) do
    now = DateTime.utc_now(:second)
    occurrence = Recurrence.next_or_first(event, now)
    today = Recurrence.local_date(now, event.time_zone)

    Gettext.with_locale(PotokIdeWeb.Gettext, Locale.default_locale(), fn ->
      %{
        kind: :event,
        id: event.id,
        title: title(event.title),
        month: occurrence.date.month |> Format.month_short() |> String.upcase(),
        day: Integer.to_string(occurrence.date.day),
        line:
          [Format.occurrence(occurrence, event.time_zone, today), event.location]
          |> Enum.map(&drawable/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" · ")
          |> cut(@max_line)
      }
    end)
  end

  @doc "A short hash of everything `card` draws."
  def version(card) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({@design, card}))
    |> binary_part(0, 9)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  `{:ok, jpeg, :whole}`, `{:ok, jpeg, :partial}` for a card that has to do
  without a picture that could not be read and may be back soon, or `:error`
  for a card that cannot be drawn. Never raises: a link is shown without it.
  """
  def image(card) do
    {:link_card, card.kind, card.id, version(card)}
    |> RenderCache.fetch(@disk_max_age, fn -> draw_kept(card) end, memory_ttl: @cache_ttl)
    |> case do
      {:ok, jpeg} -> {:ok, jpeg, :whole}
      {:partial, jpeg} -> {:ok, jpeg, :partial}
      :error -> :error
    end
  end

  # Only a whole card is a picture to keep.
  defp draw_kept(card) do
    case draw(card) do
      {:ok, jpeg, :whole} -> {:ok, jpeg}
      {:ok, jpeg, :partial} -> {:partial, jpeg}
      _error -> :error
    end
  end

  @doc false
  def escape(text) do
    text = text |> String.replace("\\", "\\\\") |> String.replace("%", "%%")

    if String.starts_with?(text, "@"), do: "\\" <> text, else: text
  end

  # The pictures come first and off the turn, as a slow server should not hold
  # up other cards.
  defp draw(card) do
    pictures = read_pictures(card)

    paint =
      :potok_ide
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:paint, &paint/2)

    Renderers.run(fn -> paint.(card, pictures) end)
  rescue
    exception ->
      Logger.warning("Could not draw a link card: #{Exception.message(exception)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Could not draw a link card: #{inspect(reason)}")
      :error
  end

  # The group's picture and the picture of the app in its pill, each nil for
  # none a card can show, `:unreadable` for one that could not be had, otherwise
  # `%{bytes: _, type: _}`. The addresses are read here, where the database
  # is, and the downloads from other servers run at the same time.
  defp read_pictures(card) do
    deadline = System.monotonic_time(:millisecond) + @download_timeout

    [group, app] =
      [card, card[:app]]
      |> Enum.map(&(&1 |> picture_url() |> start_picture()))
      |> Enum.map(&finish_picture(&1, deadline))

    %{group: group, app: app}
  end

  # A group's card and the app in a pill both name a group by `id`.
  defp picture_url(%{id: id, picture: hash}) when is_integer(id) and is_binary(hash) do
    case Social.get_group_avatar_source(id) do
      %{picture_url: url} when is_binary(url) -> String.trim(url)
      _ -> nil
    end
  end

  defp picture_url(_part), do: nil

  defp start_picture(nil), do: nil

  defp start_picture(url) do
    cond do
      Regex.match?(@svg_picture, url) ->
        nil

      String.starts_with?(url, "data:") ->
        {:read, url |> decode() |> typed()}

      String.starts_with?(url, ["http://", "https://"]) ->
        {:download,
         Task.Supervisor.async_nolink(PotokIde.TaskSupervisor, fn -> HTTP.get_image(url) end)}

      true ->
        nil
    end
  end

  defp finish_picture(nil, _deadline), do: nil
  defp finish_picture({:read, picture}, _deadline), do: picture

  defp finish_picture({:download, task}, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, bytes}} -> typed({:ok, bytes})
      _ -> :unreadable
    end
  end

  defp decode(data_url) do
    with [_header, base64] <- String.split(data_url, ",", parts: 2),
         {:ok, bytes} <- base64 |> String.trim() |> Base.decode64() do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  defp typed({:ok, bytes}) do
    case type(bytes) do
      nil -> :unreadable
      type -> %{bytes: bytes, type: type}
    end
  end

  defp typed(:error), do: :unreadable

  # By the first bytes, as an address and a server may say anything, and
  # ImageMagick is told what to read, so it never guesses.
  defp type(<<0x89, "PNG", _rest::binary>>), do: "png"
  defp type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "jpeg"
  defp type(<<"GIF8", _rest::binary>>), do: "gif"
  defp type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "webp"
  defp type(_bytes), do: nil

  # One process makes, uses and removes the files.
  defp paint(card, pictures) do
    dir = Path.join(System.tmp_dir!(), "potok_card_#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(dir)
      paint(card, pictures, dir)
    after
      File.rm_rf(dir)
    end
  end

  # A card that has to do without a picture that could not be read is partial,
  # and so is one a picture broke, drawn once more without any.
  defp paint(card, %{group: group_picture, app: app_picture}, dir) do
    {picture, picture_whole?} = measured(group_picture, dir, "picture")
    {pill, pill_whole?} = pill(card, app_picture, dir)
    pictured? = picture != nil or match?(%{avatar: {:picture, _source}}, pill)

    case compose(card, picture, pill, dir) do
      {:ok, jpeg} when picture_whole? and pill_whole? ->
        {:ok, jpeg, :whole}

      {:ok, jpeg} ->
        {:ok, jpeg, :partial}

      _broken when pictured? ->
        finish(compose(card, nil, initials_pill(pill, card), dir), :partial)

      _broken ->
        :error
    end
  end

  defp finish({:ok, jpeg}, completeness), do: {:ok, jpeg, completeness}
  defp finish(_failed, _completeness), do: :error

  # A picture to draw, measured, and whether it is all the card should show.
  defp measured(nil, _dir, _name), do: {nil, true}
  defp measured(:unreadable, _dir, _name), do: {nil, false}

  defp measured(%{} = picture, dir, name) do
    case measure(picture, dir, name) do
      nil -> {nil, false}
      measured -> {measured, true}
    end
  end

  defp measure(%{bytes: bytes, type: type}, dir, name) do
    path = Path.join(dir, name)
    source = "#{type}:#{path}[0]"

    with :ok <- File.write(path, bytes),
         {:ok, output} <- ImageMagick.run(["-ping", source, "-format", "%w %h", "info:"]),
         [_all, width, height] <- Regex.run(~r/(\d+) (\d+)\s*\z/, output) do
      %{source: source, width: String.to_integer(width), height: String.to_integer(height)}
    else
      _ -> nil
    end
  end

  # The pill of the app a link went through, nil for a card without one, and
  # whether it has all it should. Its name is drawn first, as the pill is as
  # wide as the name.
  defp pill(%{app: app}, app_picture, dir) do
    {avatar, whole?} =
      case measured(app_picture, dir, "app_picture") do
        {%{source: source}, whole?} -> {{:picture, source}, whole?}
        {nil, whole?} -> {{:initials, app.initials, app.colors}, whole?}
      end

    case pill_label(app.name, dir) do
      {:ok, label, width} -> {%{label: label, width: width, avatar: avatar}, whole?}
      :error -> {nil, false}
    end
  end

  defp pill(_card, _app_picture, _dir), do: {nil, true}

  defp initials_pill(%{} = pill, %{app: app}),
    do: %{pill | avatar: {:initials, app.initials, app.colors}}

  defp initials_pill(nil, _card), do: nil

  # The name, drawn as the titles are and written next to the card's files,
  # with the width of the pill that holds it: the circle and the space around.
  defp pill_label(name, dir) do
    path = Path.join(dir, "label.png")

    args =
      @limits ++
        caption(name, 1000, @pill_text, "white") ++
        ["-resize", "#{@max_pill_text}x>", "-write", "png:" <> path, "-format", "%w", "info:"]

    # The width ends the output, after any warning on the way.
    with {:ok, output} <- ImageMagick.run(args),
         [_all, width] <- Regex.run(~r/(\d+)\s*\z/, output) do
      {:ok, "png:" <> path, 8 + @pill_avatar + 10 + String.to_integer(width) + 24}
    else
      _ -> :error
    end
  end

  defp compose(card, picture, pill, dir) do
    output = Path.join(dir, "card.jpg")

    with [_ | _] = layers <- layers(card, picture),
         layers = with_pill(layers, pill, photo?(card, picture)),
         {:ok, _output} <- ImageMagick.run(@limits ++ layers ++ @jpeg ++ ["jpeg:" <> output]) do
      File.read(output)
    else
      nil ->
        :error

      failure ->
        Logger.warning("Could not draw the card of #{card.kind} #{card.id}: #{inspect(failure)}")
        :error
    end
  end

  defguardp is_wide_photo(width, height)
            when width >= @photo_width and width / height >= @photo_ratio

  defp photo?(%{kind: :group}, %{width: width, height: height}) when is_wide_photo(width, height),
    do: true

  defp photo?(_card, _picture), do: false

  defp with_pill(layers, nil, _photo?), do: layers

  # Over a photo, bottom left across from Potok's pill.
  defp with_pill(layers, pill, true), do: over(layers, pill_layer(pill), 20, 556)

  # Top right across from Potok's mark, at the same distance from the edge and
  # with the same middle.
  defp with_pill(layers, pill, false), do: over(layers, pill_layer(pill), 1160 - pill.width, 25)

  defp pill_layer(%{label: label, width: width, avatar: avatar}) do
    radius = div(@pill_height, 2)

    (["(", "-size", "#{width}x#{@pill_height}", "xc:none", "-fill", @pill_color] ++
       ["-draw", "roundrectangle 0,0 #{width - 1},#{@pill_height - 1} #{radius},#{radius}"])
    |> over(avatar_layer(avatar), 8, div(@pill_height - @pill_avatar, 2))
    |> Kernel.++(["(", label, ")", "-gravity", "west", "-geometry", "+58+0", "-composite", ")"])
  end

  # The app's picture in a circle, as the app shows a group, or its initials on
  # its colour, as the app does for a group without a picture.
  defp avatar_layer({:picture, source}), do: tile(source, @pill_avatar, div(@pill_avatar, 2))

  defp avatar_layer({:initials, initials, {background, color}}) do
    middle = (@pill_avatar - 1) / 2

    (["(", "-size", "#{@pill_avatar}x#{@pill_avatar}", "xc:none", "-fill", background] ++
       ["-draw", "circle #{middle},#{middle} #{middle},0"] ++
       text(initials, @pill_avatar, @pill_avatar, 16, color))
    |> Kernel.++(["-gravity", "center", "-composite", ")"])
  end

  defp layers(%{kind: :group}, %{width: width, height: height} = picture)
       when is_wide_photo(width, height) do
    (["-define", "jpeg:size=2400x1260", picture.source] ++
       ["-resize", "1200x630^", "-gravity", "center", "-extent", "1200x630"])
    |> over([part("pill.png")], 1030, 556)
  end

  # Nothing of the name can be drawn, so `image/1` says so and the link shows
  # Potok's own picture.
  defp layers(%{title: ""}, _picture), do: nil

  defp layers(%{kind: :event} = card, _picture) do
    [part("base.png")]
    |> over([part("lockup.png")], 40, 30)
    |> over(date_tile(), 495, 60)
    |> over(text(card.month, 190, 44, 30, "#1565c6"), 505, 74)
    |> over(text(card.day, 190, 120, 92, "#0a47a3"), 505, 122)
    |> over(text(card.title, 1000, 120, size(card.title, @event_sizes)), 100, 286)
    |> over(text(card.line, 1000, 56, 30, "#d6ecff"), 100, 416)
  end

  defp layers(card, %{} = picture) do
    [part("base.png")]
    |> over([part("lockup.png")], 40, 30)
    |> over(tile(picture.source, 250, 48), 475, 66)
    |> over(text(card.title, 1000, 170, size(card.title, @tile_sizes)), 100, 338)
  end

  defp layers(card, nil) do
    [part("base.png")]
    |> over(["(", part("mark.png"), "-resize", "120x120", ")"], 540, 66)
    |> over(text(card.title, 1040, 270, size(card.title, @plain_sizes)), 80, 206)
  end

  defp over(layers, layer, x, y) do
    layers ++ layer ++ ["-gravity", "northwest", "-geometry", "+#{x}+#{y}", "-composite"]
  end

  # A transparent logo gets a white ground, like the avatars in the app.
  defp tile(source, side, radius) do
    last = side - 1
    box = "#{side}x#{side}"

    ["(", "-define", "jpeg:size=#{side * 2}x#{side * 2}", source] ++
      ["-background", "white", "-alpha", "remove", "-alpha", "off"] ++
      ["-resize", "#{box}^", "-gravity", "center", "-extent", box] ++
      ["(", "-size", box, "xc:black", "-fill", "white"] ++
      ["-draw", "roundrectangle 0,0 #{last},#{last} #{radius},#{radius}", ")"] ++
      ["-alpha", "off", "-compose", "CopyOpacity", "-composite", "-compose", "Over", ")"]
  end

  defp date_tile do
    ["(", "-size", "210x210", "xc:none", "-fill", "white"] ++
      ["-draw", "roundrectangle 0,0 209,209 44,44", ")"]
  end

  # Centered in a box of its own, by what is really drawn (`caption/4`).
  defp text(string, width, height, size, color \\ "white") do
    ["("] ++
      caption(string, width, size, color) ++
      ["-gravity", "center", "-extent", "#{width}x#{height}", ")"]
  end

  # Centered from the middle, a caption goes by the font's height, which cuts off
  # the marks on Č, Š and Ž in the first line, so it starts from the top and is
  # trimmed to what is really drawn. The space between lines keeps those marks
  # off the line above.
  defp caption(string, width, size, color) do
    ["-background", "none", "-fill", color, "-font", part("Comfortaa-Bold.ttf")] ++
      ["-pointsize", "#{size}", "-interline-spacing", "#{div(size, 5)}", "-gravity", "north"] ++
      ["-size", "#{width}x", "caption:" <> escape(string), "-trim", "+repage"]
  end

  defp size(text, sizes) do
    length = String.length(text)

    Enum.find_value(sizes, fn {limit, size} -> if length <= limit, do: size end)
  end

  defp part(name), do: Application.app_dir(:potok_ide, Path.join("priv/cards", name))

  defp title(text), do: text |> drawable() |> cut(@max_title)

  defp cut(text, max_length), do: PlainText.truncate(text, max_length) || ""

  # What the font has. Only the picture loses the rest, `og:title` keeps it.
  defp drawable(text) do
    text
    |> String.normalize(:nfc)
    |> String.replace(@undrawable, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
