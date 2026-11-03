defmodule PotokIdeWeb.StaticFontsTest do
  use PotokIdeWeb.ConnCase, async: true

  # App frames are sandboxed without `allow-same-origin`, so their font
  # requests are cross-origin and need CORS.
  test "fonts allow any origin", %{conn: conn} do
    conn = get(conn, "/fonts/comfortaa-latin.woff2")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "other static files keep no CORS header", %{conn: conn} do
    conn = get(conn, "/robots.txt")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
