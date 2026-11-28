defmodule PotokIde.Social.SiteExample.Pictures do
  @moduledoc """
  The pictures of the example site (`PotokIde.Social.SiteExample`): simple
  scenes of a made-up town, drawn by ImageMagick, as the help page's pictures
  are. A name always draws the same picture, as its shapes come from a random
  generator seeded with it.

  The shapes go to ImageMagick in one `-draw` argument, never in a file:
  Debian's policy, as on the release image, forbids reading one (`@file`).
  Each shape stands in a graphic context of its own, so no fill or stroke
  leaks into the next.
  """

  alias PotokIde.ImageMagick

  @w 1200
  @h 750

  @pictures %{
    "naslovna" => {:canal, time: :evening, bridge: true},
    "rasveta" => {:street, time: :night},
    "ulica" => {:street, time: :day},
    "obala-1" => {:canal, time: :morning, people: 5},
    "obala-2" => {:canal, time: :day, people: 3, bridge: true},
    "obala-3" => {:canal, time: :overcast},
    "staza" => {:path, time: :day},
    "pijaca" => {:market, time: :day},
    "zbor" => {:hall, []},
    "vikend" => {:stage, choir: false},
    "hor" => {:stage, choir: true},
    "biblioteka" => {:library, []},
    "stara-1" => {:street, time: :day, old: true},
    "stara-2" => {:canal, time: :day, bridge: true, old: true},
    "stara-3" => {:market, time: :day, old: true},
    "stara-4" => {:park, time: :day, old: true},
    "derbi" => {:pitch, time: :evening},
    "trka-1" => {:path, time: :morning, runners: 7, finish: true},
    "trka-2" => {:path, time: :morning, runners: 10},
    "trka-3" => {:canal, time: :morning, people: 6},
    "kosarka" => {:court, []},
    "jesen-1" => {:autumn, []},
    "jesen-2" => {:autumn, path: true},
    "jesen-3" => {:park, time: :autumn},
    "park" => {:park, time: :day},
    "plan" => {:park, time: :morning},
    "dan" => {:park, time: :day, festive: true}
  }

  @skies %{
    day: {"#7fb8e6", "#e8f3fa"},
    morning: {"#a6cdea", "#fff1dc"},
    evening: {"#4f5f9a", "#f7c48c"},
    overcast: {"#aab7c2", "#e6ebef"},
    night: {"#0b1630", "#2b3d68"},
    autumn: {"#8fb9da", "#fbe9d2"}
  }

  @doc "The names of the pictures there are."
  def names, do: @pictures |> Map.keys() |> Enum.sort()

  @doc """
  Draws the picture `name` into the folder `dir` as `<name>.jpg`:
  `{:ok, path}`, or `{:error, reason}` when ImageMagick fails or is missing.
  """
  def draw(name, dir) do
    path = Path.join(dir, name <> ".jpg")

    case ImageMagick.run(args(name, path)) do
      {:ok, _output} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  What ImageMagick is called with to draw the picture `name` into `path`:
  the sky, one `-draw` with every shape, and the finish.
  """
  def args(name, path) do
    {scene, opts} = Map.fetch!(@pictures, name)
    :rand.seed(:exsss, {:erlang.phash2(name), 7, 11})
    {{top, bottom}, shapes} = scene(scene, opts)

    old =
      if opts[:old],
        do: ~w(-modulate 100,0 +level-colors #3a2a1c,#efe2c6 -attenuate 0.35 +noise Gaussian),
        else: []

    ["-size", "#{@w}x#{@h}", "gradient:#{top}-#{bottom}", "-draw", mvg(shapes)] ++
      old ++ ~w(-blur 0x0.6 -strip -quality 80) ++ [path]
  end

  defp mvg(shapes), do: Enum.join(["stroke-opacity 0" | shapes], " ")

  # ---------
  # Scenes
  # ---------

  defp scene(:canal, opts) do
    time = opts[:time] || :day
    water = %{evening: "#6f6f9a", overcast: "#6f8aa0", morning: "#5c94c2"}[time] || "#4a86b5"
    grass = if time == :evening, do: "#5c8a4a", else: "#6aa253"

    shapes =
      sky_light(time) ++
        far_line(395, "#7fa88a", 30) ++
        [
          fill("#5f8f55", polygon([{0, 405}, {600, 398}, {1200, 404}, {1200, 432}, {0, 432}]))
        ] ++
        Enum.flat_map(1..8, fn _ -> tree(rand(0, @w), 410, rand(22, 40), "#4f7f45") end) ++
        [
          fill(water, rect(0, 428, @w, 580)),
          fill("#ffffff", rect(0, 428, @w, 452), 0.12)
        ] ++
        sun_path(time) ++
        Enum.map(1..28, fn _ ->
          x = rand(0, @w - 40)
          y = rand(445, 570)
          line("#ffffff", 3, "path 'M #{x},#{y} Q #{x + 20},#{y - 5} #{x + 40},#{y}'", 0.35)
        end) ++
        [
          fill(
            grass,
            polygon([
              {0, 578},
              {200, 563},
              {450, 574},
              {700, 560},
              {950, 572},
              {1200, 562},
              {1200, 750},
              {0, 750}
            ])
          ),
          fill(
            darker(grass, 0.12),
            polygon([{0, 670}, {600, 650}, {1200, 668}, {1200, 750}, {0, 750}])
          )
        ] ++
        Enum.map(1..26, fn _ ->
          x = rand(0, @w)
          line("#3f6f35", 3, "line #{x},580 #{x + rand(-8, 8)},#{580 - rand(30, 70)}")
        end) ++
        if(opts[:bridge], do: bridge(), else: []) ++
        tree(110, 640, 125, "#4f8a3f") ++
        tree(1080, 630, 140, "#467f3a") ++
        people(opts[:people] || 0, 640, 700, 260, 940)

    {sky(time), shapes}
  end

  defp scene(:street, opts) do
    time = opts[:time] || :day
    night? = time == :night
    ground = 540

    houses =
      Stream.unfold(-20, fn x ->
        w = rand(150, 220)
        if x < @w, do: {{x, w}, x + w + rand(10, 24)}, else: nil
      end)
      |> Enum.flat_map(fn {x, w} -> house(x, w, ground, night?) end)

    shapes =
      sky_light(time) ++
        houses ++
        [
          fill(if(night?, do: "#454a58", else: "#bdb6ab"), rect(0, ground, @w, 575)),
          fill(if(night?, do: "#33363f", else: "#8f8a83"), rect(0, 575, @w, 583)),
          fill(if(night?, do: "#262a33", else: "#5d6168"), rect(0, 583, @w, @h))
        ] ++
        Enum.map(0..9, fn i ->
          fill(
            "#f2f2f2",
            rect(i * 130 + 20, 662, i * 130 + 90, 670),
            if(night?, do: 0.5, else: 0.85)
          )
        end) ++
        Enum.flat_map([110, 410, 710, 1010], &lamp(&1, 578, night?))

    {sky(time), shapes}
  end

  defp scene(:park, opts) do
    time = opts[:time] || :day
    autumn? = time == :autumn

    crown = fn ->
      if autumn?, do: leaf_color(), else: Enum.random(["#4f8a3f", "#5a9646", "#467f3a"])
    end

    shapes =
      sky_light(time) ++
        far_line(400, if(autumn?, do: "#b9864a", else: "#5f8f55"), 40) ++
        [fill(if(autumn?, do: "#a5ad5f", else: "#79b05a"), rect(0, 425, @w, @h))] ++
        Enum.map(1..8, fn _ ->
          fill("#ffffff", ellipse(rand(0, @w), rand(470, 740), rand(60, 160), rand(10, 26)), 0.12)
        end) ++
        [
          fill(
            "#d8c7a4",
            polygon([
              {500, 750},
              {700, 750},
              {650, 620},
              {705, 520},
              {640, 440},
              {605, 426},
              {580, 440},
              {615, 520},
              {555, 620}
            ])
          )
        ] ++
        Enum.flat_map([{170, 470, 150}, {960, 455, 170}, {330, 440, 95}, {820, 438, 90}], fn {x,
                                                                                              g,
                                                                                              s} ->
          tree(x, g, s, crown.())
        end) ++
        bench(330, 600, 1.0) ++
        bench(820, 640, 1.15) ++
        lamp(470, 560, false) ++
        lamp(760, 600, false) ++
        if(autumn?, do: leaves(50, 440, @h), else: []) ++
        if(opts[:festive], do: bunting() ++ balloons(), else: []) ++
        people(if(opts[:festive], do: 7, else: 2), 640, 720, 120, 1080)

    {sky(time), shapes}
  end

  defp scene(:path, opts) do
    time = opts[:time] || :day

    # The path runs straight away from us: its middle and half its width at `y`.
    centre = fn _y -> 600 end
    half = fn y -> 40 + (y - 405) / 345 * 260 end

    shapes =
      sky_light(time) ++
        far_line(400, "#6f9a6a", 25) ++
        [
          fill("#9cc46b", polygon([{0, 405}, {600, 405}, {0, 750}])),
          fill("#86b35a", polygon([{600, 405}, {@w, 405}, {@w, 750}, {0, 750}])),
          fill("#5f97c2", polygon([{430, 405}, {475, 405}, {150, 750}, {0, 750}, {0, 720}])),
          fill("#7d8a96", polygon([{560, 405}, {640, 405}, {900, 750}, {300, 750}])),
          fill("#3f8f5a", polygon([{600, 405}, {640, 405}, {900, 750}, {600, 750}]), 0.5),
          line("#ffffff", 3, "line 560,405 300,750", 0.8),
          line("#ffffff", 3, "line 640,405 900,750", 0.8)
        ] ++
        Enum.map(0..9, fn i ->
          y0 = 410 + i * i * 3.6
          y1 = y0 + 6 + i * 2.6

          fill(
            "#ffffff",
            rect(centre.(y0) - 2 - i * 0.3, y0, centre.(y0) + 2 + i * 0.3, y1),
            0.85
          )
        end) ++
        Enum.flat_map(0..6, fn k ->
          t = k / 6
          tree(700 + t * 470, 420 + t * 330, 30 + t * 120, Enum.random(["#4f8a3f", "#5a9646"]))
        end) ++
        Enum.flat_map(1..4, fn k ->
          y = 405 + k * 80
          x = centre.(y) - half.(y) - 24
          lamp_scaled(x, y, 0.25 + k * 0.2)
        end) ++
        runners(opts[:runners] || 0, centre, half) ++
        if(opts[:finish], do: finish_arch(), else: [])

    {sky(time), shapes}
  end

  defp scene(:market, opts) do
    colors = [
      {"#d62828", "#ffffff"},
      {"#2a9d8f", "#ffffff"},
      {"#1d4e89", "#f1faee"},
      {"#f4a261", "#ffffff"}
    ]

    backs =
      Enum.flat_map(0..5, fn i ->
        x = i * 210 - 20
        h = rand(90, 140)

        [
          fill(
            Enum.random(["#e9dcc8", "#d9c3a5", "#cdd5c4", "#e2cdb0"]),
            rect(x, 430 - h, x + 200, 430)
          )
        ] ++
          Enum.map(0..2, fn j ->
            fill("#9cc7e6", rect(x + 30 + j * 55, 430 - h + 25, x + 60 + j * 55, 430 - h + 60))
          end)
      end)

    tents =
      colors
      |> Enum.with_index()
      |> Enum.flat_map(fn {{a, b}, i} -> tent(40 + i * 290, a, b) end)

    shapes =
      sky_light(:day) ++
        backs ++
        [fill("#cfc6b4", rect(0, 430, @w, @h))] ++
        Enum.map(1..10, fn i ->
          line("#a59c8a", 2, "line 0,#{430 + i * 32} #{@w},#{430 + i * 32}", 0.5)
        end) ++
        tents ++
        people(6, 640, 730, 60, 1140)

    {sky(opts[:time] || :day), shapes}
  end

  defp scene(:hall, _opts) do
    shapes =
      Enum.flat_map([140, 470, 800], fn x ->
        [
          fill("#7b5a3c", rect(x - 8, 92, x + 268, 338)),
          fill("#cfe6f5", rect(x, 100, x + 260, 330)),
          fill("#ffffff", rect(x, 100, x + 260, 170), 0.35),
          fill("#7b5a3c", rect(x + 126, 100, x + 134, 330))
        ]
      end) ++
        [
          fill("#a9774f", rect(0, 470, @w, @h)),
          fill("#2f5d8a", rect(400, 365, 800, 405)),
          line("#ffffff", 6, "line 440,385 760,385", 0.8)
        ] ++
        Enum.map(1..9, fn i ->
          line("#7a5236", 2, "line 0,#{470 + i * 30} #{@w},#{470 + i * 30}", 0.35)
        end) ++
        Enum.flat_map([510, 600, 690], fn x -> person(x, 520, 110, Enum.random(shirts())) end) ++
        [
          fill("#7a4f33", rect(420, 470, 780, 495)),
          fill("#2f5d8a", rect(430, 495, 770, 540))
        ] ++
        Enum.flat_map(0..3, fn row ->
          y = 610 + row * 45
          s = 1.0 + row * 0.22
          count = 9 - row

          Enum.flat_map(0..(count - 1), fn i ->
            x = 600 + (i - (count - 1) / 2) * 120 * s + rand(-10, 10)
            from_behind(x, y, 46 * s)
          end)
        end)

    {{"#efe4d2", "#e0cfb5"}, shapes}
  end

  defp scene(:stage, opts) do
    beams = ["#ff5d8f", "#5dd3ff", "#ffd35d", "#9d7bff"]

    shapes =
      stars(30, 240) ++
        [
          fill(
            "#14202e",
            polygon([
              {0, 330},
              {200, 300},
              {420, 325},
              {700, 290},
              {950, 320},
              {@w, 300},
              {@w, 540},
              {0, 540}
            ])
          ),
          fill("#1a2230", rect(0, 540, @w, @h)),
          fill("#1d1b2e", rect(280, 250, 920, 430)),
          fill("#3a2f2a", rect(250, 430, 950, 500)),
          fill("#2a221e", rect(250, 500, 950, 540)),
          fill("#555c66", rect(260, 228, 940, 246)),
          fill("#555c66", rect(260, 228, 276, 540)),
          fill("#555c66", rect(924, 228, 940, 540))
        ] ++
        Enum.flat_map(0..7, fn i ->
          x = 320 + i * 80
          color = Enum.at(beams, rem(i, 4))

          [
            fill(color, polygon([{x, 252}, {x - 90, 500}, {x + 90, 500}]), 0.16),
            fill(color, circle(x, 252, 9))
          ]
        end) ++
        if(opts[:choir],
          do:
            Enum.flat_map([{0, 458, 84}, {1, 494, 94}], fn {row, y, s} ->
              Enum.flat_map(0..6, fn i -> person(370 + i * 77 + row * 38, y, s, "#1d3557") end)
            end),
          else: Enum.flat_map([420, 560, 700, 800], &person(&1, 470, 120, Enum.random(shirts())))
        ) ++
        string_lights(110, 150) ++
        Enum.flat_map(0..2, fn row ->
          y = 640 + row * 50
          s = 1.0 + row * 0.25

          Enum.flat_map(0..(11 - row * 2), fn i ->
            from_behind(i * (110 + row * 30) + rand(-15, 15) + 20, y, 52 * s, "#0b0f1a")
          end)
        end)

    {sky(:night), shapes}
  end

  defp scene(:library, _opts) do
    book_colors = ~w(#8c2f39 #2f5d8a #3c6e47 #d9a441 #5a3d6b #b5651d #33475b #a23e48 #6b8f71)

    shelves =
      Enum.flat_map([60, 460], fn x0 ->
        [fill("#6b4a32", rect(x0, 110, x0 + 360, 650))] ++
          Enum.flat_map(0..4, fn row ->
            bottom = 210 + row * 105

            books =
              Stream.unfold(x0 + 14, fn x ->
                w = rand(14, 28)
                if x < x0 + 330, do: {{x, w}, x + w + rand(1, 4)}, else: nil
              end)
              |> Enum.map(fn {x, w} ->
                fill(
                  Enum.random(book_colors),
                  rect(x, bottom - rand(62, 92), min(x + w, x0 + 346), bottom)
                )
              end)

            [fill("#4a3222", rect(x0 + 10, bottom - 96, x0 + 350, bottom))] ++
              books ++ [fill("#8a6446", rect(x0 + 6, bottom, x0 + 354, bottom + 9))]
          end)
      end)

    shapes =
      [fill("#8a5e3b", rect(0, 650, @w, @h))] ++
        shelves ++
        [
          fill("#7b5a3c", rect(872, 112, 1128, 428)),
          fill("#cfe6f5", rect(880, 120, 1120, 420)),
          fill("#ffffff", rect(880, 120, 1120, 200), 0.4),
          fill("#7b5a3c", rect(996, 120, 1004, 420)),
          fill("#7b5a3c", rect(880, 266, 1120, 274)),
          fill("#7a4f33", rect(850, 560, 1180, 586)),
          fill("#5b3a24", rect(870, 586, 890, 700)),
          fill("#5b3a24", rect(1140, 586, 1160, 700)),
          fill("#ffe2a0", circle(1060, 470, 120), 0.18),
          fill("#3b3f46", rect(1056, 470, 1064, 560)),
          fill("#2f5d8a", polygon([{1020, 470}, {1100, 470}, {1085, 430}, {1035, 430}])),
          fill("#d9a441", rect(930, 540, 1010, 560)),
          fill("#8c2f39", rect(935, 528, 1005, 540))
        ]

    {{"#e9dcc5", "#d6c3a3"}, shapes}
  end

  defp scene(:pitch, opts) do
    time = opts[:time] || :day
    crowd = ~w(#d62828 #1d4e89 #f1faee #fcbf49 #2a9d8f)

    stripes =
      Enum.map(0..9, fn i ->
        fill(
          if(rem(i, 2) == 0, do: "#58a64c", else: "#4c9241"),
          polygon([
            {100 + i * 100, 430},
            {200 + i * 100, 430},
            {-50 + (i + 1) * 130, 750},
            {-50 + i * 130, 750}
          ])
        )
      end)

    shapes =
      sky_light(time) ++
        [
          fill("#2f343b", rect(0, 286, @w, 298)),
          fill("#8c939c", rect(0, 298, @w, 425))
        ] ++
        for(
          row <- 0..4,
          i <- 0..58,
          rand(0, 1) > 0.25,
          do: fill(Enum.random(crowd), circle(i * 20.5 + rand(0, 8), 312 + row * 22, 6))
        ) ++
        Enum.flat_map([60, 1140], fn x ->
          [
            line("#3b3f46", 8, "line #{x},425 #{x},120"),
            fill("#3b3f46", rect(x - 45, 100, x + 45, 135)),
            fill("#fff6d5", rect(x - 38, 106, x + 38, 129))
          ]
        end) ++
        stripes ++
        [
          line("#ffffff", 4, "path 'M 100,430 L 1100,430 L 1250,750'", 0.9),
          line("#ffffff", 4, "path 'M 100,430 L -50,750'", 0.9),
          line("#ffffff", 4, "line 600,430 600,750", 0.9),
          line("#ffffff", 4, "ellipse 600,560 130,48 0,360", 0.9),
          line("#ffffff", 5, "path 'M 52,520 L 52,470 L 24,470 L 24,540'", 0.95),
          line("#ffffff", 5, "path 'M 1148,520 L 1148,470 L 1176,470 L 1176,540'", 0.95)
        ] ++
        (Enum.map(0..7, fn i ->
           {rand(470, 700), rand(150, 1050), Enum.at(["#d62828", "#1d4e89"], rem(i, 2))}
         end)
         |> Enum.sort()
         |> Enum.flat_map(fn {y, x, shirt} -> person(x, y, 50 + (y - 430) * 0.3, shirt) end)) ++
        [fill("#ffffff", circle(640, 640, 9))]

    {sky(time), shapes}
  end

  defp scene(:court, _opts) do
    shapes =
      sky_light(:day) ++
        Enum.flat_map([90, 330, 610, 880, 1120], fn x ->
          tree(x, 330, rand(70, 100), "#4f8a3f")
        end) ++
        [fill("#7a8c6a", rect(0, 330, @w, @h))] ++
        Enum.map(0..40, fn i -> line("#5a5f66", 2, "line #{i * 30},300 #{i * 30},460", 0.5) end) ++
        [
          line("#5a5f66", 4, "line 0,300 1200,300", 0.8),
          fill("#c8693a", polygon([{60, 460}, {1140, 460}, {1260, 750}, {-60, 750}])),
          line("#ffffff", 4, "path 'M 60,460 L 1140,460 L 1260,750'", 0.9),
          line("#ffffff", 4, "path 'M 60,460 L -60,750'", 0.9),
          line("#ffffff", 4, "line 600,460 600,750", 0.9),
          line("#ffffff", 4, "ellipse 600,590 110,40 0,360", 0.9),
          line("#ffffff", 4, "path 'M 1130,520 L 960,520 L 990,640 L 1190,640'", 0.9),
          line("#3d3d3d", 10, "line 1100,690 1100,330"),
          line("#3d3d3d", 8, "line 1100,345 1075,345"),
          fill("#ffffff", rect(1000, 300, 1090, 370)),
          line("#d62828", 3, "rectangle 1030,330 1062,358"),
          line("#f77f00", 4, "ellipse 1046,378 26,7 0,360")
        ] ++
        Enum.map(0..4, fn i ->
          line("#ffffff", 2, "line #{1024 + i * 11},382 #{1030 + i * 8},412", 0.8)
        end) ++
        person(880, 620, 120, "#1d4e89") ++
        person(760, 700, 135, "#fcbf49") ++
        person(470, 660, 125, "#2a9d8f") ++
        [
          fill("#e76f51", circle(930, 520, 16)),
          line("#5a2a1a", 2, "line 914,520 946,520", 0.8)
        ]

    {sky(:day), shapes}
  end

  defp scene(:autumn, opts) do
    shapes =
      sky_light(:autumn) ++
        far_line(420, "#b9864a", 35) ++
        [fill("#a5ad5f", rect(0, 440, @w, @h))] ++
        Enum.map(1..14, fn _ ->
          fill(
            leaf_color(),
            ellipse(rand(0, @w), rand(470, 740), rand(50, 140), rand(8, 20)),
            0.35
          )
        end) ++
        if(opts[:path],
          do: [fill("#d8c7a4", polygon([{520, 750}, {760, 750}, {640, 450}, {610, 450}]))],
          else: []
        ) ++
        Enum.flat_map(
          [
            {130, 520, 160},
            {380, 480, 110},
            {560, 455, 70},
            {760, 470, 95},
            {1000, 520, 170},
            {880, 455, 60}
          ],
          fn {x, g, s} -> tree(x, g, s, leaf_color(), "#5a3e2b") end
        ) ++
        leaves(70, 120, @h) ++
        bench(300, 640, 1.1)

    {sky(:autumn), shapes}
  end

  # ---------
  # Parts of a scene
  # ---------

  defp sky(time), do: Map.fetch!(@skies, time)

  # The sun, the moon or the clouds of a time of day.
  defp sky_light(:night) do
    stars(45, 300) ++
      [
        fill("#f4f1de", circle(1020, 110, 120), 0.06),
        fill("#f4f1de", circle(1020, 110, 70), 0.12),
        fill("#f4f1de", circle(1020, 110, 38))
      ]
  end

  defp sky_light(:evening) do
    [
      fill("#ffd38a", circle(820, 340, 190), 0.12),
      fill("#ffd38a", circle(820, 340, 110), 0.25),
      fill("#ffe2a8", circle(820, 340, 55))
    ] ++ clouds(3, "#f6d2b8", 0.55)
  end

  defp sky_light(:overcast), do: clouds(9, "#f4f6f8", 0.8)

  defp sky_light(time) do
    x = rand(820, 1080)
    y = rand(80, 150)

    [
      fill("#fff4c2", circle(x, y, 150), 0.12),
      fill("#fff4c2", circle(x, y, 95), 0.25),
      fill("#fff4c2", circle(x, y, 52))
    ] ++ clouds(if(time == :morning, do: 3, else: 5), "#ffffff", 0.9)
  end

  defp sun_path(:evening) do
    Enum.map(0..13, fn i ->
      y = 438 + i * 10
      w = (24 + i * 7) * rand(0.6, 1.2)
      fill("#ffd38a", ellipse(820 + rand(-12, 12), y, w, 2.5), rand(0.25, 0.5))
    end)
  end

  defp sun_path(_time), do: []

  defp clouds(n, color, opacity) do
    Enum.flat_map(1..n, fn _ ->
      cx = rand(40, @w - 40)
      cy = rand(50, 230)

      Enum.map(1..5, fn _ ->
        fill(
          color,
          ellipse(cx + rand(-70, 70), cy + rand(-14, 14), rand(40, 80), rand(18, 30)),
          opacity
        )
      end)
    end)
  end

  defp stars(n, bottom) do
    Enum.map(1..n, fn _ ->
      fill("#ffffff", circle(rand(0, @w), rand(10, bottom), rand(1, 2.4)), rand(0.4, 0.9))
    end)
  end

  # A line of trees far away, as a band of round tops.
  defp far_line(y, color, step) do
    Enum.map(0..div(@w, step), fn i ->
      fill(color, circle(i * step, y, rand(step * 0.6, step * 1.2)))
    end) ++
      [fill(color, rect(0, y, @w, y + 20))]
  end

  defp tree(x, ground, size, crown, trunk \\ "#6b4a32") do
    tw = size * 0.16

    [
      fill(trunk, rect(x - tw / 2, ground - size * 1.1, x + tw / 2, ground)),
      fill(darker(crown, 0.15), circle(x - size * 0.35, ground - size * 1.15, size * 0.5)),
      fill(crown, circle(x + size * 0.3, ground - size * 1.2, size * 0.52)),
      fill(lighter(crown, 0.12), circle(x, ground - size * 1.55, size * 0.6))
    ]
  end

  defp house(x, w, ground, night?) do
    h = rand(170, 260)
    wall = Enum.random(~w(#e8d8c3 #d9b99b #c9d6c3 #e6c9a8 #d4dce6 #f0e2c8 #cfa98a))
    wall = if night?, do: darker(wall, 0.62), else: wall
    roof = Enum.random(~w(#a8553f #8f4a3a #6d5a4f #b5664a))
    roof = if night?, do: darker(roof, 0.55), else: roof
    top = ground - h
    rows = if h > 210, do: 2, else: 1
    cols = max(div(round(w), 75), 1)

    windows =
      for row <- 0..(rows - 1), col <- 0..(cols - 1) do
        wx = x + (col + 0.5) * w / cols - 17
        wy = top + 30 + row * 80
        lit? = night? and rand(0, 1) < 0.7

        cond do
          lit? ->
            [
              fill("#ffd77a", rect(wx - 8, wy - 8, wx + 42, wy + 52), 0.2),
              fill("#ffd77a", rect(wx, wy, wx + 34, wy + 44))
            ]

          night? ->
            [fill("#2a3550", rect(wx, wy, wx + 34, wy + 44))]

          true ->
            [
              fill("#ffffff", rect(wx - 3, wy - 3, wx + 37, wy + 47)),
              fill("#9cc7e6", rect(wx, wy, wx + 34, wy + 44))
            ]
        end
      end
      |> List.flatten()

    [
      fill(wall, rect(x, top, x + w, ground)),
      fill(roof, polygon([{x - 10, top}, {x + w / 2, top - rand(45, 80)}, {x + w + 10, top}]))
    ] ++
      windows ++
      if(h > 190,
        do: [fill(darker(wall, 0.35), rect(x + w / 2 - 18, ground - 62, x + w / 2 + 18, ground))],
        else: []
      )
  end

  defp lamp(x, ground, night?) do
    glow =
      if night?,
        do: [
          fill("#ffe2a0", polygon([{x + 40, 345}, {x - 70, ground}, {x + 150, ground}]), 0.12),
          fill("#ffe2a0", circle(x + 40, 345, 130), 0.1),
          fill("#ffe2a0", circle(x + 40, 345, 70), 0.18),
          fill("#fff3c4", circle(x + 40, 345, 22), 0.9)
        ],
        else: []

    [
      line("#3b3f46", 6, "line #{x},#{ground} #{x},330"),
      line("#3b3f46", 5, "path 'M #{x},332 Q #{x + 4},322 #{x + 40},328'"),
      fill("#4a4f58", ellipse(x + 40, 336, 20, 8))
    ] ++ glow
  end

  defp lamp_scaled(x, ground, s) do
    [
      line("#3b3f46", max(2, 6 * s), "line #{n(x)},#{n(ground)} #{n(x)},#{n(ground - 240 * s)}"),
      fill("#4a4f58", ellipse(x + 10 * s, ground - 240 * s, 16 * s, 6 * s))
    ]
  end

  defp bench(x, ground, s) do
    color = "#8a5a3c"

    [
      fill(color, rect(x - 70 * s, ground - 40 * s, x + 70 * s, ground - 30 * s)),
      fill(color, rect(x - 70 * s, ground - 70 * s, x + 70 * s, ground - 60 * s)),
      fill(color, rect(x - 70 * s, ground - 85 * s, x + 70 * s, ground - 75 * s)),
      line(
        "#3b3f46",
        5 * s,
        "line #{n(x - 60 * s)},#{n(ground)} #{n(x - 60 * s)},#{n(ground - 85 * s)}"
      ),
      line(
        "#3b3f46",
        5 * s,
        "line #{n(x + 60 * s)},#{n(ground)} #{n(x + 60 * s)},#{n(ground - 85 * s)}"
      )
    ]
  end

  defp bridge do
    posts = Enum.map(0..8, fn i -> {80 + i * 45, bridge_y(80 + i * 45)} end)

    [
      line("#8a7f74", 16, "path 'M 60,430 Q 260,300 460,430'"),
      line("#6f655c", 4, "path 'M 60,392 Q 260,262 460,392'")
    ] ++
      Enum.map(posts, fn {x, y} -> line("#6f655c", 4, "line #{x},#{n(y)} #{x},#{n(y - 38)}") end)
  end

  defp bridge_y(x) do
    t = (x - 60) / 400
    (1 - t) * (1 - t) * 430 + 2 * (1 - t) * t * 300 + t * t * 430
  end

  defp tent(x, a, b) do
    w = 250
    n = 8
    sw = w / n
    crates = ~w(#d62828 #f77f00 #6a994e #fcbf49 #7b2cbf)

    [
      line("#5a4636", 6, "line #{x},300 #{x},580"),
      line("#5a4636", 6, "line #{x + w},300 #{x + w},580")
    ] ++
      Enum.map(0..(n - 1), fn i ->
        fill(if(rem(i, 2) == 0, do: a, else: b), rect(x + i * sw, 280, x + (i + 1) * sw, 330))
      end) ++
      Enum.map(0..(n - 1), fn i ->
        fill(if(rem(i, 2) == 0, do: a, else: b), circle(x + (i + 0.5) * sw, 330, sw / 2))
      end) ++
      [
        fill("#8a6a4a", rect(x - 6, 500, x + w + 6, 520)),
        fill(darker(a, 0.25), rect(x, 520, x + w, 585))
      ] ++
      Enum.flat_map(0..3, fn i ->
        cx = x + 12 + i * 60
        fruit = Enum.random(crates)

        [fill("#b08a5a", rect(cx, 462, cx + 52, 500))] ++
          for(j <- 0..2, k <- 0..1, do: fill(fruit, circle(cx + 10 + j * 16, 462 - k * 10, 9)))
      end)
  end

  defp bunting do
    colors = ~w(#e4572e #f3a712 #29bf12 #00a5cf #9d4edd)

    flags =
      Enum.map(0..23, fn i ->
        t = i / 23
        {x, y} = bezier({0, 180}, {600, 300}, {@w, 170}, t)
        fill(Enum.at(colors, rem(i, 5)), polygon([{x - 14, y}, {x + 14, y + 2}, {x, y + 32}]))
      end)

    [line("#3b3f46", 2, "path 'M 0,180 Q 600,300 1200,170'")] ++ flags
  end

  defp balloons do
    colors = ~w(#e63946 #f4a261 #2a9d8f #ffb703 #8338ec #ff006e)

    Enum.flat_map(0..5, fn i ->
      x = 180 + i * 165 + rand(-30, 30)
      y = rand(330, 420)

      [
        line(
          "#555555",
          2,
          "line #{n(x)},#{n(y + 34)} #{n(x + rand(-10, 10))},#{n(y + 150)}",
          0.8
        ),
        fill(Enum.at(colors, i), ellipse(x, y, 26, 34)),
        fill("#ffffff", ellipse(x - 9, y - 12, 6, 9), 0.5)
      ]
    end)
  end

  defp string_lights(y_ends, y_mid) do
    wire = "path 'M 0,#{y_ends} Q 600,#{y_mid * 2 - y_ends} 1200,#{y_ends}'"

    bulbs =
      Enum.flat_map(0..30, fn i ->
        {x, y} = bezier({0, y_ends}, {600, y_mid * 2 - y_ends}, {@w, y_ends}, i / 30)
        [fill("#ffd77a", circle(x, y + 6, 16), 0.2), fill("#fff1c1", circle(x, y + 6, 5))]
      end)

    [line("#222831", 2, wire)] ++ bulbs
  end

  defp finish_arch do
    [
      fill("#d62828", rect(318, 470, 342, 700)),
      fill("#d62828", rect(858, 470, 882, 700)),
      fill("#d62828", rect(318, 430, 882, 480)),
      line("#ffffff", 6, "line 400,455 800,455", 0.85)
    ] ++
      Enum.map(0..13, fn i ->
        fill(
          if(rem(i, 2) == 0, do: "#111111", else: "#ffffff"),
          rect(330 + i * 39, 700, 369 + i * 39, 712)
        )
      end)
  end

  defp runners(0, _centre, _half), do: []

  defp runners(count, centre, half) do
    for _ <- 1..count do
      y = rand(470, 735)
      x = centre.(y) + rand(-0.8, 0.8) * half.(y)
      {y, x}
    end
    |> Enum.sort()
    |> Enum.flat_map(fn {y, x} ->
      person(x, y, 30 + (y - 405) * 0.45, Enum.random(shirts()), running: true)
    end)
  end

  defp people(0, _y0, _y1, _x0, _x1), do: []

  defp people(count, y0, y1, x0, x1) do
    for _ <- 1..count do
      {rand(y0, y1), rand(x0, x1)}
    end
    |> Enum.sort()
    |> Enum.flat_map(fn {y, x} -> person(x, y, 90 + (y - y0) * 0.5, Enum.random(shirts())) end)
  end

  defp shirts, do: ~w(#e63946 #457b9d #2a9d8f #f4a261 #8338ec #ffb703 #1d3557 #ef476f)

  # A person standing on `ground`, `s` tall.
  defp person(x, ground, s, shirt, opts \\ []) do
    skin = Enum.random(~w(#e0b48f #c68b5f #f1c9a5 #a8714a))
    hair = Enum.random(~w(#3b2a20 #1f1a17 #8a5a2b #c9a26b #6b6b6b))
    head = s * 0.11
    stride = if opts[:running], do: s * 0.12, else: 0

    [
      fill(
        "#2f3a4a",
        polygon([
          {x - s * 0.13, ground - s * 0.34},
          {x - 2, ground - s * 0.34},
          {x - s * 0.04 - stride, ground},
          {x - s * 0.14 - stride, ground}
        ])
      ),
      fill(
        "#2f3a4a",
        polygon([
          {x + 2, ground - s * 0.34},
          {x + s * 0.13, ground - s * 0.34},
          {x + s * 0.14 + stride, ground},
          {x + s * 0.04 + stride, ground}
        ])
      ),
      fill(
        shirt,
        roundrect(x - s * 0.17, ground - s * 0.72, x + s * 0.17, ground - s * 0.3, s * 0.06)
      ),
      fill(hair, circle(x, ground - s * 0.86, head * 1.04)),
      fill(skin, circle(x, ground - s * 0.835, head * 0.9))
    ]
  end

  # A person seen from behind, as in an audience.
  defp from_behind(x, y, s, color \\ nil) do
    shirt = color || Enum.random(shirts())
    hair = color || Enum.random(~w(#3b2a20 #1f1a17 #8a5a2b #c9a26b #6b6b6b))

    [
      fill(shirt, roundrect(x - s * 0.55, y - s * 0.5, x + s * 0.55, y + s * 0.6, s * 0.25)),
      fill(hair, circle(x, y - s * 0.75, s * 0.36))
    ]
  end

  defp leaves(count, y0, y1) do
    Enum.map(1..count, fn _ ->
      fill(leaf_color(), ellipse(rand(0, @w), rand(y0, y1), rand(4, 8), rand(2, 4)))
    end)
  end

  defp leaf_color, do: Enum.random(~w(#e07a2e #d9472b #f2b134 #c4612b #e8a33d))

  defp bezier({x0, y0}, {x1, y1}, {x2, y2}, t) do
    {(1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * x1 + t * t * x2,
     (1 - t) * (1 - t) * y0 + 2 * (1 - t) * t * y1 + t * t * y2}
  end

  # ---------
  # Shapes, in MVG
  # ---------

  # Every filled shape says its fill and its opacity, so it needs no context
  # of its own, which keeps the argument short: Windows takes a command line
  # of 32 KB at most, and Linux an argument of 128 KB. Strokes are off for the
  # whole drawing (`draw/2`), and a line turns them on in its own context.
  defp fill(color, shape, opacity \\ 1) do
    "fill '#{color}' fill-opacity #{num(opacity)} #{shape}"
  end

  defp line(color, width, shape, opacity \\ 1) do
    "push graphic-context fill-opacity 0 stroke '#{color}' stroke-opacity #{num(opacity)} " <>
      "stroke-width #{num(width)} stroke-linecap round #{shape} pop graphic-context"
  end

  defp rect(x0, y0, x1, y1), do: "rectangle #{n(x0)},#{n(y0)} #{n(x1)},#{n(y1)}"

  defp roundrect(x0, y0, x1, y1, r),
    do: "roundrectangle #{n(x0)},#{n(y0)} #{n(x1)},#{n(y1)} #{n(r)},#{n(r)}"

  defp circle(x, y, r), do: "circle #{n(x)},#{n(y)} #{n(x + r)},#{n(y)}"
  defp ellipse(x, y, rx, ry), do: "ellipse #{n(x)},#{n(y)} #{n(rx)},#{n(ry)} 0,360"

  defp polygon(points),
    do: "polygon " <> Enum.map_join(points, " ", fn {x, y} -> "#{n(x)},#{n(y)}" end)

  defp n(value), do: round(value)
  defp num(value) when is_integer(value), do: Integer.to_string(value)
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp rand(a, b), do: a + :rand.uniform() * (b - a)

  defp darker(hex, amount), do: mix(hex, "#000000", amount)
  defp lighter(hex, amount), do: mix(hex, "#ffffff", amount)

  defp mix("#" <> a, "#" <> b, amount) do
    [a, b] =
      Enum.map([a, b], fn hex ->
        for <<c::binary-size(2) <- hex>>, do: String.to_integer(c, 16)
      end)

    "#" <>
      (Enum.zip(a, b)
       |> Enum.map_join(fn {x, y} ->
         (x + (y - x) * amount) |> round() |> Integer.to_string(16) |> String.pad_leading(2, "0")
       end)
       |> String.downcase())
  end
end
