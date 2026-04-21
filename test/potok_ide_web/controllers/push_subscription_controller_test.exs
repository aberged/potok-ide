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

    test "stores a native push token for the current account", %{conn: conn, account: account} do
      params = valid_native_subscription_params()

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions", %{"subscription" => params})

      assert %{
               "enabled" => true,
               "identifier" => identifier,
               "subscription_type" => "fcm"
             } = json_response(conn, 200)

      assert identifier == params["token"]

      assert [
               %PushSubscription{
                 account_id: account_id,
                 device_token: ^identifier,
                 device_platform: :android,
                 subscription_type: :fcm
               }
             ] = Accounts.list_push_subscriptions(account)

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

    test "removes a saved native push token", %{conn: conn, account: account} do
      params = valid_native_subscription_params()

      {:ok, subscription} =
        Accounts.upsert_push_subscription(account, native_subscription_attrs(params))

      conn =
        conn
        |> json_conn()
        |> delete(~p"/accounts/push-subscriptions", %{"identifier" => subscription.device_token})

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

    test "sends a test native notification through Firebase", %{conn: conn, account: account} do
      request_pid = self()
      configure_firebase_push_notifications(request_pid)
      params = valid_native_subscription_params()

      {:ok, _subscription} =
        Accounts.upsert_push_subscription(account, native_subscription_attrs(params))

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{"identifier" => params["token"]})

      assert %{"sent" => true} = json_response(conn, 200)

      assert_receive {:firebase_token_request, token_request}
      assert token_request[:url] == "https://oauth2.googleapis.com/token"
      assert token_request[:form][:grant_type] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert is_binary(token_request[:form][:assertion])

      assert_receive {:firebase_send_request, send_request}

      assert send_request[:url] ==
               "https://fcm.googleapis.com/v1/projects/potok-test/messages:send"

      assert send_request[:auth] == {:bearer, "test-access-token"}

      assert %{
               message: %{
                 token: token,
                 data: %{
                   "android_channel_id" => "potok-default",
                   "badge" => "http://localhost:4000/images/pwa/icon-192.png",
                   "body" => "Push notifications are enabled for your account.",
                   "icon" => "/images/pwa/icon-192.png",
                   "tag" => "potok-push-test",
                   "title" => "Potok notifications are active",
                   "url" => "/accounts/settings"
                 },
                 android: %{priority: "high"}
               }
             } = send_request[:json]

      assert token == params["token"]
    end

    test "returns an invalid firebase credentials error for blank firebase token url", %{
      conn: conn,
      account: account
    } do
      params = valid_native_subscription_params()

      Application.put_env(
        :potok_ide,
        PotokIde.PushNotifications,
        firebase_project_id: "potok-test",
        firebase_client_email: "push-test@potok-test.iam.gserviceaccount.com",
        firebase_private_key: valid_test_private_key(),
        firebase_token_url: "   ",
        request_fun: fn _options ->
          flunk("request_fun should not be called when firebase_token_url is invalid")
        end
      )

      {:ok, _subscription} =
        Accounts.upsert_push_subscription(account, native_subscription_attrs(params))

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{"identifier" => params["token"]})

      assert %{"error" => error} = json_response(conn, 502)
      assert error =~ "invalid_firebase_credentials"
      refute error =~ "URI.parse"
    end

    test "routes legacy device-token subscriptions through Firebase", %{
      conn: conn,
      account: account
    } do
      request_pid = self()
      configure_firebase_push_notifications(request_pid)
      token = "legacy-fcm-token-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now(:second)

      {1, _rows} =
        PotokIde.Repo.insert_all(PushSubscription, [
          %{
            account_id: account.id,
            subscription_type: :web_push,
            device_platform: :android,
            device_token: token,
            endpoint: nil,
            p256dh: nil,
            auth: nil,
            inserted_at: now,
            updated_at: now
          }
        ])

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{"identifier" => token})

      assert %{"sent" => true} = json_response(conn, 200)

      assert_receive {:firebase_send_request, send_request}
      assert send_request[:json][:message][:token] == token
    end

    test "returns an invalid subscription error for malformed web push rows", %{
      conn: conn,
      account: account
    } do
      now = DateTime.utc_now(:second)

      {1, _rows} =
        PotokIde.Repo.insert_all(PushSubscription, [
          %{
            account_id: account.id,
            subscription_type: :web_push,
            device_platform: :web,
            endpoint: nil,
            p256dh: nil,
            auth: nil,
            inserted_at: now,
            updated_at: now
          }
        ])

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{})

      assert %{"error" => error} = json_response(conn, 502)
      assert error =~ "invalid_subscription"
      refute error =~ "URI.parse"
    end

    test "returns an invalid subscription error for malformed web push endpoints", %{
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

      {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)
      now = DateTime.utc_now(:second)

      {1, _rows} =
        PotokIde.Repo.insert_all(PushSubscription, [
          %{
            account_id: account.id,
            subscription_type: :web_push,
            device_platform: :web,
            endpoint: "not-a-valid-url",
            p256dh: Base.url_encode64(public_key, padding: false),
            auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
            inserted_at: now,
            updated_at: now
          }
        ])

      conn =
        conn
        |> json_conn()
        |> post(~p"/accounts/push-subscriptions/test", %{})

      assert %{"error" => error} = json_response(conn, 502)
      assert error =~ "invalid_subscription"
      refute error =~ "URI.parse"
      refute_receive {:push_request, _request}
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
      subscription_type: :web_push,
      device_platform: :web,
      endpoint: params["endpoint"],
      auth: params["keys"]["auth"],
      p256dh: params["keys"]["p256dh"],
      expires_at: nil,
      user_agent: "ExUnit"
    }
  end

  defp valid_native_subscription_params do
    %{
      "type" => "fcm",
      "platform" => "android",
      "token" => "fcm-test-token-#{System.unique_integer([:positive])}"
    }
  end

  defp native_subscription_attrs(params) do
    %{
      subscription_type: :fcm,
      device_platform: :android,
      device_token: params["token"],
      user_agent: "ExUnit"
    }
  end

  defp configure_firebase_push_notifications(request_pid) do
    Application.put_env(
      :potok_ide,
      PotokIde.PushNotifications,
      firebase_project_id: "potok-test",
      firebase_client_email: "push-test@potok-test.iam.gserviceaccount.com",
      firebase_private_key: valid_test_private_key(),
      request_fun: fn options ->
        case options[:url] do
          "https://oauth2.googleapis.com/token" ->
            send(request_pid, {:firebase_token_request, options})
            {:ok, %Req.Response{status: 200, body: %{"access_token" => "test-access-token"}}}

          "https://fcm.googleapis.com/v1/projects/potok-test/messages:send" ->
            send(request_pid, {:firebase_send_request, options})
            {:ok, %Req.Response{status: 200, body: %{"name" => "projects/potok-test/messages/1"}}}

          _other_url ->
            {:error, :unexpected_url}
        end
      end
    )
  end

  defp valid_test_private_key do
    :public_key.generate_key({:rsa, 2048, 65_537})
    |> then(fn key ->
      [:public_key.pem_entry_encode(:RSAPrivateKey, key)]
      |> :public_key.pem_encode()
      |> IO.iodata_to_binary()
    end)
  end
end
