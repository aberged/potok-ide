defmodule PotokIdeWeb.MapTileControllerTest do
  @moduledoc """
  Map tiles pass through Potok (`PotokIde.MapTiles`): fetched from the source
  with Potok's name, once, and served with no session to anyone.
  """
  use PotokIdeWeb.ConnCase, async: true

  alias PotokIde.RateLimit

  @png <<137, 80, 78, 71, 13, 10, 26, 10, "tile">>

  # Each test asks for its own tiles: kept ones stay in memory for a while.
  defp tile do
    {19, :rand.uniform(500_000), :rand.uniform(500_000)}
  end

  defp path({z, x, y}), do: "/tiles/#{z}/#{x}/#{y}.png"

  defp stub_source(test_pid, status \\ 200) do
    Req.Test.stub(PotokIde.MapTiles, fn conn ->
      send(test_pid, {:source, conn.request_path, Plug.Conn.get_req_header(conn, "user-agent")})

      conn
      |> Plug.Conn.put_resp_content_type("image/png", nil)
      |> Plug.Conn.send_resp(status, @png)
    end)
  end

  test "fetches a tile once, naming Potok, and serves it to anyone", %{conn: conn} do
    stub_source(self())
    {z, x, y} = tile = tile()

    conn = get(conn, path(tile))

    assert response(conn, 200) == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=604800"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'none'"

    assert_received {:source, source_path, [user_agent]}
    assert source_path == "/#{z}/#{x}/#{y}.png"
    assert user_agent =~ "Potok"
    assert user_agent =~ "potok.rs"

    assert build_conn() |> get(path(tile)) |> response(200) == @png
    refute_received {:source, _path, _user_agent}
  end

  test "refuses what is not a tile", %{conn: conn} do
    stub_source(self())

    for bad <- [
          "/tiles/20/0/0.png",
          "/tiles/2/4/0.png",
          "/tiles/2/0/-1.png",
          "/tiles/a/0/0.png",
          "/tiles/2/0/0.jpg",
          "/tiles/2/0/0"
        ] do
      assert conn |> get(bad) |> response(404) == "", bad
    end

    refute_received {:source, _path, _user_agent}
  end

  test "says the source failed, and keeps no answer in the browser", %{conn: conn} do
    stub_source(self(), 500)

    conn = get(conn, path(tile()))

    assert response(conn, 502) == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "takes only pictures from the source", %{conn: conn} do
    Req.Test.stub(PotokIde.MapTiles, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<h1>blocked</h1>")
    end)

    assert conn |> get(path(tile())) |> response(502) == ""
  end

  test "an IP that asks too often waits", %{conn: conn} do
    stub_source(self())
    ip = {10, 99, :rand.uniform(250), :rand.uniform(250)}

    # Counted in fixed windows: fill until the limit holds, so a window that
    # ends in between starts the count again and is filled too.
    Stream.repeatedly(fn -> RateLimit.hit(:tile_ip, RateLimit.ip_key(ip)) end)
    |> Enum.find(&match?({:error, :rate_limited, _retry_after}, &1))

    conn = get(%{conn | remote_ip: ip}, path(tile()))

    assert response(conn, 429) == ""
    assert [_seconds] = get_resp_header(conn, "retry-after")
  end
end
