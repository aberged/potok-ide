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

  test "falls back to the configured refresh token when the persisted token is rejected" do
    assert {:ok, %GmailRefreshToken{}} = GmailRefreshToken.upsert("stored-refresh")

    attempt_counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      attempt = Agent.get_and_update(attempt_counter, fn count -> {count, count + 1} end)
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case attempt do
        0 ->
          assert body =~ "refresh_token=stored-refresh"

          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{
            "error" => "invalid_grant",
            "error_description" => "Token has been expired or revoked."
          })

        1 ->
          assert body =~ "refresh_token=config-refresh"
          Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
      end
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

  test "uses the persisted refresh token before the configured refresh token" do
    assert {:ok, %GmailRefreshToken{}} = GmailRefreshToken.upsert("stored-refresh")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "refresh_token=stored-refresh"

      Req.Test.json(conn, %{"access_token" => "fresh-token", "expires_in" => 3600})
    end)

    assert {:ok, [access_token: "fresh-token"]} =
             GmailToken.delivery_config(
               client_id: "test-client",
               client_secret: "test-secret",
               refresh_token: "config-refresh",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert %GmailRefreshToken{refresh_token: "stored-refresh"} = GmailRefreshToken.get()
  end

  test "returns a clear error when refresh token configuration is incomplete" do
    assert {:error, {:missing_config, "GMAIL_CLIENT_ID"}} =
             GmailToken.delivery_config(client_secret: "secret")

    assert {:error, {:missing_config, "GMAIL_REFRESH_TOKEN"}} =
             GmailToken.delivery_config(client_id: "client", client_secret: "secret")
  end
end
