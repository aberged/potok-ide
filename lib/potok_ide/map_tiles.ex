defmodule PotokIde.MapTiles do
  @moduledoc """
  The pictures a map is drawn on, passed on from OpenStreetMap
  (`PotokIdeWeb.MapTileController`, `/tiles/:z/:x/:y.png`).

  Maps in apps and in a group's settings take their tiles from Potok, not from
  OpenStreetMap: the frame of an app sends no `Referer`, which OSM asks of web
  maps, OSM never sees who is looking, and the source can change here without
  touching any app. Each tile is kept on disk for a week
  (`PotokIde.RenderCache`), as OSM's tile policy asks, and fetched once
  however many ask for it at the same moment.

  OSM asks for a User-Agent that names the service and a way to reach it (the
  site's address here; `:user_agent` in the config can add a contact), and for
  the attribution on every map.
  """

  require Logger

  alias PotokIde.{RateLimit, RenderCache}

  @defaults [
    url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    user_agent: "Potok/1.0 (+https://potok.rs)",
    max_zoom: 19,
    req_options: []
  ]

  # Serbia, Kosovo and Metohija included: where a map opens until its editors
  # save a view of their own. South-west, then north-east.
  @default_bounds [[41.85, 18.82], [46.19, 23.01]]

  @max_age :timer.hours(24 * 7)
  # A tile that failed is asked for again after this long, not on every request.
  @failure_ttl :timer.seconds(30)
  @max_bytes 1_000_000

  @doc "The tile's address for a map library, with `{z}`, `{x}` and `{y}`."
  def url_template(base) when is_binary(base), do: base <> "/{z}/{x}/{y}.png"

  @doc "What every map shows of where its tiles come from, as HTML."
  def attribution do
    ~s(&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>)
  end

  def max_zoom, do: config()[:max_zoom]

  def default_bounds, do: @default_bounds

  @doc "Whether `z`, `x` and `y` name a tile."
  def valid?(z, x, y) when is_integer(z) and is_integer(x) and is_integer(y) do
    side = Integer.pow(2, z)
    z >= 0 and z <= max_zoom() and x >= 0 and x < side and y >= 0 and y < side
  end

  def valid?(_z, _x, _y), do: false

  @doc """
  The PNG of tile `z/x/y`: `{:ok, binary}`, or `:error` when the source does
  not give it now.
  """
  def fetch(z, x, y) do
    case RenderCache.fetch({:map_tile, z, x, y}, @max_age, fn -> download(z, x, y) end,
           dir: cache_dir(),
           memory_ttl: @failure_ttl
         ) do
      {:ok, binary} when is_binary(binary) -> {:ok, binary}
      _failed -> :error
    end
  end

  defp download(z, x, y) do
    with :ok <- upstream_turn() do
      config = config()

      url =
        config[:url]
        |> String.replace("{z}", Integer.to_string(z))
        |> String.replace("{x}", Integer.to_string(x))
        |> String.replace("{y}", Integer.to_string(y))

      [
        url: url,
        headers: [{"user-agent", config[:user_agent]}],
        retry: false,
        connect_options: [timeout: 3_000],
        receive_timeout: 5_000,
        decode_body: false
      ]
      |> Keyword.merge(config[:req_options])
      |> Req.get()
      |> tile()
    end
  end

  defp tile({:ok, %Req.Response{status: 200, body: body} = response})
       when is_binary(body) and byte_size(body) <= @max_bytes do
    if image?(response), do: {:ok, body}, else: :error
  end

  defp tile({:ok, %Req.Response{status: status}}) do
    Logger.warning("Map tile source answered #{status}")
    :error
  end

  defp tile({:error, exception}) do
    Logger.warning("Map tile source failed: #{Exception.message(exception)}")
    :error
  end

  defp image?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.starts_with?(&1, "image/"))
  end

  # All of Potok together asks the source only so often, whoever is looking.
  defp upstream_turn do
    case RateLimit.hit(:tile_upstream, :all) do
      :ok -> :ok
      {:error, :rate_limited, _retry_after} -> :error
    end
  end

  defp cache_dir do
    case Keyword.fetch(config(), :cache_dir) do
      {:ok, dir} -> dir
      :error -> Path.join(System.tmp_dir!(), "potok-tiles")
    end
  end

  defp config, do: Keyword.merge(@defaults, Application.get_env(:potok_ide, __MODULE__, []))
end
