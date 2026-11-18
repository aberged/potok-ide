defmodule PotokIde.MapTilesSharedTest do
  @moduledoc """
  With the files' bucket, the machines share their map tiles: one another
  machine fetched this week comes from the bucket, not from OpenStreetMap.
  """
  # Swaps the storage config, so it cannot run next to other tests; the
  # limit on the source counts in Postgres.
  use PotokIde.DataCase, async: false

  alias PotokIde.{MapTiles, Storage}
  alias PotokIde.Storage.S3

  @osm_png <<137, 80, 78, 71, 13, 10, 26, 10, "from osm">>
  @shared_png <<137, 80, 78, 71, 13, 10, 26, 10, "from the bucket">>

  setup do
    previous = Application.get_env(:potok_ide, Storage)

    Application.put_env(:potok_ide, Storage,
      adapter: S3,
      bucket: "tiles-test",
      endpoint: "https://s3.example.com",
      region: "auto",
      access_key_id: "key",
      secret_access_key: "secret",
      req_options: [plug: {Req.Test, S3}, retry: false]
    )

    on_exit(fn -> Application.put_env(:potok_ide, Storage, previous) end)

    test_pid = self()

    Req.Test.stub(MapTiles, fn conn ->
      send(test_pid, {:osm, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(200, @osm_png)
    end)

    :ok
  end

  # Tiles kept in memory stay there, so each test asks for its own.
  defp tile, do: {19, :rand.uniform(500_000), :rand.uniform(500_000)}

  # The bucket answers GET with `stored` (nil for none) and tells of a PUT.
  defp stub_bucket(stored) do
    test_pid = self()

    Req.Test.stub(S3, fn conn ->
      case {conn.method, stored} do
        {"GET", nil} ->
          Plug.Conn.send_resp(conn, 404, "")

        {"GET", {png, fetched_at}} ->
          conn
          |> Plug.Conn.put_resp_header("x-amz-meta-fetched-at", Integer.to_string(fetched_at))
          |> Plug.Conn.send_resp(200, png)

        {"PUT", _stored} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test_pid,
            {:put, conn.request_path, body,
             Plug.Conn.get_req_header(conn, "x-amz-meta-fetched-at")}
          )

          Plug.Conn.send_resp(conn, 200, "")
      end
    end)
  end

  test "a tile another machine fetched this week comes from the bucket" do
    {z, x, y} = tile()
    stub_bucket({@shared_png, System.system_time(:millisecond) - :timer.hours(24)})

    assert MapTiles.fetch(z, x, y) == {:ok, @shared_png}
    refute_received {:osm, _path}
    refute_received {:put, _path, _body, _meta}
  end

  test "a tile nobody has is fetched from the source and written for the others" do
    {z, x, y} = tile()
    stub_bucket(nil)

    assert MapTiles.fetch(z, x, y) == {:ok, @osm_png}
    assert_received {:osm, osm_path}
    assert osm_path == "/#{z}/#{x}/#{y}.png"
    assert_received {:put, path, @osm_png, [fetched_at]}
    assert path == "/tiles-test/tiles/#{z}/#{x}/#{y}.png"
    assert String.to_integer(fetched_at) <= System.system_time(:millisecond)
  end

  test "a tile older than a week is fetched again" do
    {z, x, y} = tile()
    stub_bucket({@shared_png, System.system_time(:millisecond) - :timer.hours(24 * 8)})

    assert MapTiles.fetch(z, x, y) == {:ok, @osm_png}
    assert_received {:osm, _path}
    assert_received {:put, _path, @osm_png, _meta}
  end
end
