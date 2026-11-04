defmodule PotokIde.Social.NotificationsTest do
  use PotokIde.DataCase, async: false

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Social
  alias PotokIde.Social.{Group, Notifications, Profile, Value}

  @ana %Profile{id: 1, username: "ana"}
  @group %Group{id: 2, name: "Hall"}
  @value %Value{id: 3, content: "Bring chairs"}

  describe "payloads" do
    test "are written in the language of each device" do
      payload_for = Notifications.value_created(@ana, @group, @value)

      assert payload_for.("en").title == "ana added a new value"
      assert payload_for.("en").body == "New value in Hall: Bring chairs"
      assert payload_for.("sr").title == "ana: nova vrednost"
      assert payload_for.("sr_Cyrl").body == "Нова вредност у групи Hall: Bring chairs"
      assert payload_for.(nil) == payload_for.("sr")
      assert payload_for.("de") == payload_for.("sr")
      assert payload_for.("pl") == payload_for.("sr")
      assert payload_for.("en").url == "/groups/2/values"
    end

    test "of a mention differ from the generic one only in the title" do
      generic = Notifications.value_created(@ana, @group, @value)
      mention = Notifications.value_mention(@ana, @group, @value)

      assert mention.("sr").title == "ana te pominje u grupi Hall"
      assert %{mention.("sr") | title: nil} == %{generic.("sr") | title: nil}
    end

    test "of reactions, invitations and shared profiles are translated" do
      bojan = %Profile{id: 4, username: "bojan"}

      for payload_for <- [
            Notifications.value_reaction(@ana, @group, @value, "👍"),
            Notifications.group_invitation(@ana, @group),
            Notifications.group_invitation_accepted(@group, @ana),
            Notifications.shared_profile_invitation(@ana, bojan),
            Notifications.shared_profile_invitation_accepted(bojan, @ana)
          ] do
        assert payload_for.("en").title =~ "ana"
        assert payload_for.("sr").title =~ "ana"
        refute payload_for.("sr").title == payload_for.("en").title
        refute payload_for.("sr_Cyrl").title == payload_for.("en").title
      end

      assert Notifications.value_reaction(@ana, @group, @value, "👍").("en").title ==
               "ana reacted 👍 to your value"
    end
  end

  describe "delivery" do
    setup do
      original_config = Application.get_env(:potok_ide, PushNotifications, [])
      on_exit(fn -> Application.put_env(:potok_ide, PushNotifications, original_config) end)
      configure_firebase(self())
      :ok
    end

    test "a value reaches each device of a member in that device's language" do
      author = profile!("notif-author")
      member_account = account_fixture()
      member = profile!("notif-member", member_account)
      group = group!(author, "notif-group")
      add_member!(author, group, member)

      device!(member_account, "en")
      device!(member_account, "sr_Cyrl")

      assert {:ok, _value} = Social.create_value(author, group, %{"content" => "Bring chairs"})

      titles = sent_titles(2)

      assert Enum.sort(titles) == [
               "notif-author added a new value",
               "notif-author: нова вредност"
             ]
    end

    test "the test notification follows the device's language" do
      account = account_fixture()
      device!(account, nil)

      assert {:ok, _result} = Accounts.send_test_push_notification(account)
      assert sent_titles(1) == ["Potok obaveštenja su uključena"]
    end
  end

  defp sent_titles(count) do
    for _request <- 1..count do
      assert_receive {:firebase_send_request, request}
      request[:json].message.data["title"]
    end
  end

  defp device!(account, locale) do
    {:ok, subscription} =
      Accounts.upsert_push_subscription(account, %{
        subscription_type: :fcm,
        device_platform: :android,
        device_token: "fcm-notif-#{System.unique_integer([:positive])}",
        user_agent: "ExUnit",
        locale: locale
      })

    subscription
  end

  defp profile!(username, account \\ account_fixture()) do
    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  defp group!(owner, name) do
    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => name,
        "description" => "",
        "description_format" => :markdown
      })

    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end

  defp configure_firebase(request_pid) do
    Application.put_env(
      :potok_ide,
      PushNotifications,
      firebase_project_id: "potok-test",
      firebase_client_email: "notif-test@potok-test.iam.gserviceaccount.com",
      firebase_private_key: test_private_key(),
      request_fun: fn options ->
        case options[:url] do
          "https://oauth2.googleapis.com/token" ->
            {:ok, %Req.Response{status: 200, body: %{"access_token" => "test-access-token"}}}

          "https://fcm.googleapis.com/v1/projects/potok-test/messages:send" ->
            send(request_pid, {:firebase_send_request, options})
            {:ok, %Req.Response{status: 200, body: %{"name" => "projects/potok-test/messages/1"}}}
        end
      end
    )
  end

  defp test_private_key do
    {:rsa, 2048, 65_537}
    |> :public_key.generate_key()
    |> then(&[:public_key.pem_entry_encode(:RSAPrivateKey, &1)])
    |> :public_key.pem_encode()
    |> IO.iodata_to_binary()
  end
end
