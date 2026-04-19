defmodule PotokIde.GmailTokenTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.GmailRefreshToken
  alias PotokIde.GmailToken

  test "returns the configured access token when refresh configuration is unavailable" do
    assert {:ok, [access_token: "static-token"]} =
             GmailToken.delivery_config(access_token: "static-token")
  end

  test "prefers refreshing the access token when refresh configuration is available" do
    assert {:ok, %GmailRefreshToken{}} = GmailRefreshToken.upsert("stored-refresh")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "grant_type=refresh_token"
      assert body =~ "refresh_token=stored-refresh"

      Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
    end)

    assert {:ok, [access_token: "fresh-token"]} =
             GmailToken.delivery_config(
               access_token: "stale-token",
               client_id: "test-client",
               client_secret: "test-secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
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

    assert %GmailRefreshToken{refresh_token: "test-refresh"} = GmailRefreshToken.get()
  end

  test "persists a rotated refresh token from the response" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "fresh-token",
        "refresh_token" => "rotated-refresh",
        "expires_in" => 3600
      })
    end)

    assert {:ok, [access_token: "fresh-token"]} =
             GmailToken.delivery_config(
               client_id: "test-client",
               client_secret: "test-secret",
               refresh_token: "test-refresh",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert %GmailRefreshToken{refresh_token: "rotated-refresh"} = GmailRefreshToken.get()
  end

  test "uses the configured refresh token before the persisted refresh token" do
    assert {:ok, %GmailRefreshToken{}} = GmailRefreshToken.upsert("stored-refresh")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "refresh_token=config-refresh"

      Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
    end)

    assert {:ok, [access_token: "fresh-token"]} =
             GmailToken.delivery_config(
               client_id: "test-client",
               client_secret: "test-secret",
               refresh_token: "config-refresh",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert %GmailRefreshToken{refresh_token: "config-refresh"} = GmailRefreshToken.get()
  end

  test "returns a clear error when refresh token configuration is incomplete" do
    assert {:error, {:missing_config, "GMAIL_CLIENT_ID"}} =
             GmailToken.delivery_config(client_secret: "secret")

    assert {:error, {:missing_config, "GMAIL_REFRESH_TOKEN"}} =
             GmailToken.delivery_config(client_id: "client", client_secret: "secret")
  end
end
