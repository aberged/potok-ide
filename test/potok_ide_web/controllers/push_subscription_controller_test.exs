defmodule PotokIdeWeb.PushSubscriptionControllerTest do
  use PotokIdeWeb.ConnCase, async: false

  alias PotokIde.Accounts
  alias PotokIde.Accounts.PushSubscription

  setup :register_and_log_in_account

  setup do
    original_config = Application.get_env(:potok_ide, PotokIde.PushNotifications, [])

    on_exit(fn ->
      Application.put_env(:potok_ide, PotokIde.PushNotifications, original_config)
    end)

    :ok
  end

  describe "POST /accounts/push-subscriptions" do
    test "stores a push subscription for the current account", %{conn: conn, account: account} do
      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions", %{"subscription" => valid_subscription_params()})

      assert %{"enabled" => true, "endpoint" => endpoint} = json_response(conn, 200)

      assert [%PushSubscription{account_id: account_id, endpoint: ^endpoint}] =
               Accounts.list_push_subscriptions(account)

      assert account_id == account.id
    end
  end

  describe "DELETE /accounts/push-subscriptions" do
    test "removes a saved push subscription", %{conn: conn, account: account} do
      params = valid_subscription_params()
      {:ok, subscription} = Accounts.upsert_push_subscription(account, subscription_attrs(params))

      conn =
        conn
        |> json_conn()
        |> delete(~p"/accounts/push-subscriptions", %{"endpoint" => subscription.endpoint})

      assert %{"enabled" => false} = json_response(conn, 200)
      assert Accounts.list_push_subscriptions(account) == []
    end
  end

  describe "POST /accounts/push-subscriptions/test" do
    test "sends a test notification through the configured request function", %{
      conn: conn,
      account: account
    } do
      request_pid = self()

      Application.put_env(
        :potok_ide,
        PotokIde.PushNotifications,
        ttl: 60,
        vapid_subject: "mailto:test@example.com",
        vapid_public_key:
          Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
        vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        request_fun: fn options ->
          send(request_pid, {:push_request, options})
          {:ok, %Req.Response{status: 201, body: ""}}
        end
      )

      params = valid_subscription_params()

      {:ok, _subscription} =
        Accounts.upsert_push_subscription(account, subscription_attrs(params))

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{"endpoint" => params["endpoint"]})

      assert %{"sent" => true} = json_response(conn, 200)

      assert_receive {:push_request, request_options}
      assert request_options[:url] == params["endpoint"]
      assert Enum.any?(request_options[:headers], fn {key, _value} -> key == "Authorization" end)
      assert Enum.any?(request_options[:headers], fn {key, _value} -> key == "Crypto-Key" end)
    end
  end

  defp json_conn(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp valid_subscription_params do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" =>
        "https://updates.push.services.mozilla.com/wpush/v2/#{System.unique_integer([:positive])}",
      "expirationTime" => nil,
      "keys" => %{
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "p256dh" => Base.url_encode64(public_key, padding: false)
      }
    }
  end

  defp subscription_attrs(params) do
    %{
      endpoint: params["endpoint"],
      auth: params["keys"]["auth"],
      p256dh: params["keys"]["p256dh"],
      expires_at: nil,
      user_agent: "ExUnit"
    }
  end
end
