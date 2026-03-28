defmodule PotokIde.GmailTokenTest do
  use ExUnit.Case, async: true

  alias PotokIde.GmailToken

  test "returns the configured access token when present" do
    assert {:ok, [access_token: "static-token"]} =
             GmailToken.delivery_config(access_token: "static-token")
  end

  test "exchanges a refresh token for an access token" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "grant_type=refresh_token"
      assert body =~ "client_id=test-client"
      assert body =~ "client_secret=test-secret"
      assert body =~ "refresh_token=test-refresh"

      Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
    end)

    assert {:ok, [access_token: "fresh-token"]} =
             GmailToken.delivery_config(
               client_id: "test-client",
               client_secret: "test-secret",
               refresh_token: "test-refresh",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "returns a clear error when refresh token configuration is incomplete" do
    assert {:error, {:missing_config, "GMAIL_CLIENT_ID"}} =
             GmailToken.delivery_config(client_secret: "secret", refresh_token: "refresh")
  end
end
