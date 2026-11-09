defmodule PotokIdeWeb.ClientIpTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PotokIdeWeb.ClientIp

  defp conn_with_header(value) do
    conn(:get, "/")
    |> Map.put(:remote_ip, {172, 16, 0, 1})
    |> Plug.Conn.put_req_header("fly-client-ip", value)
  end

  test "takes the client's IP from the configured header" do
    conn = ClientIp.call(conn_with_header("203.0.113.7"), header: "fly-client-ip")
    assert conn.remote_ip == {203, 0, 113, 7}

    conn = ClientIp.call(conn_with_header("2001:db8::1"), header: "fly-client-ip")
    assert conn.remote_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
  end

  test "leaves the IP alone without a configured header" do
    conn = ClientIp.call(conn_with_header("203.0.113.7"), header: nil)
    assert conn.remote_ip == {172, 16, 0, 1}
  end

  test "leaves the IP alone when the header is missing or not an address" do
    conn = ClientIp.call(conn_with_header("not an ip"), header: "fly-client-ip")
    assert conn.remote_ip == {172, 16, 0, 1}

    conn = ClientIp.call(conn(:get, "/") |> Map.put(:remote_ip, {172, 16, 0, 1}), header: "x")
    assert conn.remote_ip == {172, 16, 0, 1}
  end

  test "is not configured outside Fly" do
    assert Application.get_env(:potok_ide, :client_ip_header) == nil
  end
end
