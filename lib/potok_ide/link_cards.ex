defmodule PotokIde.LinkCards do
  @moduledoc """
  The picture on the card of a shared link to a public group or event, drawn
  here at 1200x630, so that it suits every site that shows cards and does not
  depend on another server keeping a picture online.

  A wide photo fills the card. Any other picture sits in a tile above the name,
  and the mark stands in for a group without one. An event shows its date and
  never its group, which may be private. The parts are in `priv/cards`, made by
  `build.sh` there.

  `version/1` is a hash of everything that is drawn. Sites keep a picture by its
  address, so the address changes with the content, and as it comes from the
  data and not from what is asked for, nobody can ask for endless new drawings.
  Raise `@design` when the look of the cards changes.
  """

  require Logger

  alias PotokIde.Cache
  alias PotokIde.Events.{Event, Format, Recurrence}
  alias PotokIde.ImageMagick
  alias PotokIde.LinkPreviews.HTTP
  alias PotokIde.PlainText
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIdeWeb.Locale

  @design 1

  # For every outcome. A story is a public group too, so a crawl of all of them
  # must not stay in memory for long.
  @cache_ttl :timer.minutes(15)
  # Each step of a download has its own limits, and with redirects those add up
  # to half a minute.
  @download_timeout 6_000
  # The address is public and a drawing takes up to 150 MB of a machine with
  # 512, so they go one at a time (`PotokIde.LinkCards.Renderers`).
  @turn_timeout 8_000
  @turn_poll 50
  @draw_timeout 15_000

  @limits ~w(-limit memory 128MiB -limit map 256MiB -limit disk 256MiB) ++
            ~w(-limit area 64MP -limit width 12000 -limit height 12000 -limit time 15)
  @jpeg ~w(-strip -sampling-factor 4:2:0 -interlace JPEG -quality 82)

  # At least this wide and this much wider than high, a picture is a photo to
  # show whole rather than a logo.
  @photo_width 600
  @photo_ratio 1.3

  @max_title 90
  @max_line 60
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
    Cache.fetch({:link_card, card.kind, card.id, version(card)}, @cache_ttl, fn -> draw(card) end)
  end

  @doc false
  def escape(text) do
    text = text |> String.replace("\\", "\\\\") |> String.replace("%", "%%")

    if String.starts_with?(text, "@"), do: "\\" <> text, else: text
  end

  # The picture comes first and off the turn, as a slow server should not hold
  # up other cards.
  defp draw(card) do
    picture = read_picture(card)

    paint =
      :potok_ide
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:paint, &paint/2)

    in_turn(fn -> paint.(card, picture) end)
  rescue
    exception ->
      Logger.warning("Could not draw a link card: #{Exception.message(exception)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Could not draw a link card: #{inspect(reason)}")
      :error
  end

  defp in_turn(fun), do: in_turn(fun, System.monotonic_time(:millisecond) + @turn_timeout)

  defp in_turn(fun, deadline) do
    caller = self()
    ref = make_ref()

    case Task.Supervisor.start_child(__MODULE__.Renderers, fn -> send(caller, {ref, fun.()}) end) do
      {:ok, pid} ->
        await(pid, ref)

      {:error, :max_children} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@turn_poll)
          in_turn(fun, deadline)
        else
          :error
        end
    end
  end

  defp await(pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :error
    after
      @draw_timeout ->
        Process.demonitor(monitor, [:flush])
        Task.Supervisor.terminate_child(__MODULE__.Renderers, pid)
        :error
    end
  end

  # nil for a group without a picture a card can show, `:unreadable` for one that
  # could not be had, otherwise `%{bytes: _, type: _}`.
  defp read_picture(%{kind: :group, id: id, picture: hash}) when is_binary(hash) do
    case Social.get_group_avatar_source(id) do
      %{picture_url: url} when is_binary(url) -> url |> String.trim() |> picture_at()
      _ -> nil
    end
  end

  defp read_picture(_card), do: nil

  defp picture_at(url) do
    cond do
      Regex.match?(@svg_picture, url) -> nil
      String.starts_with?(url, "data:") -> url |> decode() |> typed()
      String.starts_with?(url, ["http://", "https://"]) -> url |> download() |> typed()
      true -> nil
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

  defp download(url) do
    task = Task.Supervisor.async_nolink(PotokIde.TaskSupervisor, fn -> HTTP.get_image(url) end)

    case Task.yield(task, @download_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, bytes}} -> {:ok, bytes}
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
  defp paint(card, picture) do
    dir = Path.join(System.tmp_dir!(), "potok_card_#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(dir)
      paint(card, picture, dir)
    after
      File.rm_rf(dir)
    end
  end

  defp paint(card, nil, dir), do: finish(compose(card, nil, dir), :whole)
  defp paint(card, :unreadable, dir), do: finish(compose(card, nil, dir), :partial)

  defp paint(card, %{} = picture, dir) do
    measured = measure(picture, dir)

    case measured && compose(card, measured, dir) do
      {:ok, jpeg} -> {:ok, jpeg, :whole}
      _broken -> finish(compose(card, nil, dir), :partial)
    end
  end

  defp finish({:ok, jpeg}, completeness), do: {:ok, jpeg, completeness}
  defp finish(_failed, _completeness), do: :error

  defp measure(%{bytes: bytes, type: type}, dir) do
    path = Path.join(dir, "picture")
    source = "#{type}:#{path}[0]"

    with :ok <- File.write(path, bytes),
         {:ok, output} <- ImageMagick.run(["-ping", source, "-format", "%w %h", "info:"]),
         [_all, width, height] <- Regex.run(~r/(\d+) (\d+)\s*\z/, output) do
      %{source: source, width: String.to_integer(width), height: String.to_integer(height)}
    else
      _ -> nil
    end
  end

  defp compose(card, picture, dir) do
    output = Path.join(dir, "card.jpg")

    with [_ | _] = layers <- layers(card, picture),
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

  defp layers(%{kind: :group}, %{width: width, height: height} = picture)
       when width >= @photo_width and width / height >= @photo_ratio do
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

  # Centered from the middle, a caption goes by the font's height, which cuts off
  # the marks on Č, Š and Ž in the first line, so it starts from the top and only
  # then moves to the middle, by what is really drawn. The space between lines
  # keeps those marks off the line above.
  defp text(string, width, height, size, color \\ "white") do
    ["(", "-background", "none", "-fill", color, "-font", part("Comfortaa-Bold.ttf")] ++
      ["-pointsize", "#{size}", "-interline-spacing", "#{div(size, 5)}", "-gravity", "north"] ++
      ["-size", "#{width}x", "caption:" <> escape(string), "-trim", "+repage"] ++
      ["-gravity", "center", "-extent", "#{width}x#{height}", ")"]
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
