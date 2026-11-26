defmodule PotokIde.Social.NotificationsTest do
  use PotokIde.DataCase, async: false

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Social
  alias PotokIde.Social.{Group, Notifications, Profile, Value}

  @ana %Profile{id: 1, username: "ana"}
  @group %Group{id: 2, name: "Hall"}
  @value %Value{id: 3, content: "Bring chairs", content_format: :markdown}

  describe "payloads" do
    test "are titled with the group and written in the language of each device" do
      payload_for = Notifications.value_created(@ana, @group, @value)
      en = PushNotifications.payload_for(payload_for, "en")

      assert en.title == "Hall"
      assert en.body == "ana: Bring chairs"
      assert en.text == "Bring chairs"
      assert en.sender == "ana"
      assert en.kind == "message"
      assert en.group_id == 2
      assert en.tag == "group-2-chat"
      assert en.url == "/groups/2/values"
      assert en.icon == PotokIdeWeb.Avatars.group_badge_url(@group)
      assert en.sender_icon == PotokIdeWeb.Avatars.profile_badge_url(@ana)
      assert is_integer(en.timestamp) and is_integer(en.expires_at)

      assert PushNotifications.payload_for(payload_for, "sr").body == "ana: Bring chairs"

      assert PushNotifications.payload_for(payload_for, nil) ==
               PushNotifications.payload_for(payload_for, "sr")

      assert PushNotifications.payload_for(payload_for, "de") ==
               PushNotifications.payload_for(payload_for, "sr")

      assert PushNotifications.payload_for(payload_for, "pl") ==
               PushNotifications.payload_for(payload_for, "sr")
    end

    test "of a mention and a reply say so, under the same tag as the conversation" do
      mention =
        PushNotifications.payload_for(Notifications.value_mention(@ana, @group, @value), "sr")

      reply = PushNotifications.payload_for(Notifications.value_reply(@ana, @group, @value), "sr")

      assert mention.title == "Hall"
      assert mention.body == "ana te pominje: Bring chairs"
      assert mention.kind == "mention"
      assert reply.body == "ana ti odgovara: Bring chairs"
      assert reply.kind == "reply"
      assert reply.url == "/groups/2/values?value=3"
      assert mention.tag == reply.tag
      assert mention.tag == "group-2-chat"

      assert PushNotifications.payload_for(
               Notifications.value_mention(@ana, @group, @value),
               "en"
             ).body ==
               "ana mentioned you: Bring chairs"
    end

    test "of a direct conversation are titled with the person, who is the one writing" do
      direct = %Group{id: 7, name: "ana & bojan", is_direct: true}

      payload =
        PushNotifications.payload_for(Notifications.value_created(@ana, direct, @value), "sr")

      assert payload.title == "ana"
      assert payload.body == "Bring chairs"
      assert payload.direct == true
      assert payload.icon == PotokIdeWeb.Avatars.profile_badge_url(@ana)
    end

    test "show the words of a message, not its markdown" do
      value = %Value{id: 3, content: "**Bring** chairs", content_format: :markdown}

      payload =
        PushNotifications.payload_for(Notifications.value_created(@ana, @group, value), "en")

      assert payload.body == "ana: Bring chairs"
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
        en = PushNotifications.payload_for(payload_for, "en")
        sr = PushNotifications.payload_for(payload_for, "sr")
        cyrl = PushNotifications.payload_for(payload_for, "sr_Cyrl")

        assert en.title <> en.body =~ "ana"
        assert sr.title <> sr.body =~ "ana"
        refute {sr.title, sr.body} == {en.title, en.body}
        refute {cyrl.title, cyrl.body} == {en.title, en.body}
        assert en.kind in ["reaction", "invitation"]
      end

      reaction = Notifications.value_reaction(@ana, @group, @value, "👍")
      assert PushNotifications.payload_for(reaction, "en").title == "Hall"
      assert PushNotifications.payload_for(reaction, "en").body == "ana: 👍 to “Bring chairs”"
      assert PushNotifications.payload_for(reaction, "sr").body == "ana: 👍 na „Bring chairs“"
    end
  end

  describe "a thread" do
    test "is titled with its group and the thread, and shows the group's picture" do
      author = profile!("thread-author")
      group = group!(author, "Zgrada")
      {:ok, value} = Social.create_value(author, group, %{"content" => "Lift ne radi"})
      {:ok, thread} = Social.get_or_create_value_thread(author, group, value, %{"name" => "Lift"})

      payload =
        PushNotifications.payload_for(Notifications.value_created(author, thread, @value), "sr")

      assert payload.title == "Zgrada › Lift"
      assert payload.icon == PotokIdeWeb.Avatars.group_badge_url(group)
      assert payload.group_id == thread.id
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

      messages = for _request <- 1..2, do: sent_message()
      assert Enum.map(messages, & &1.data["title"]) == ["notif-group", "notif-group"]

      # The app draws them itself, also in the background, in its channel.
      for message <- messages do
        refute Map.has_key?(message, :notification)
        assert message.data["kind"] == "message"
        assert message.data["android_channel_id"] == "potok-messages"
        assert message.data["badge"] == message.data["icon"]
        assert message.data["icon"] =~ ~r"\Ahttps?://.+/avatar/group/#{group.id}\?format=png"
        refute Map.has_key?(message.data, "expires_at")
        assert message.android.collapse_key == "group-#{group.id}-chat"
        assert message.android.ttl =~ ~r/\A\d+s\z/
      end
    end

    test "an iPhone groups a conversation's notifications and replaces the older" do
      author = profile!("ios-author")
      member_account = account_fixture()
      member = profile!("ios-member", member_account)
      group = group!(author, "ios-group")
      add_member!(author, group, member)
      device!(member_account, "sr", :ios)

      assert {:ok, _value} = Social.create_value(author, group, %{"content" => "Bring chairs"})

      message = sent_message()
      assert message.notification == %{title: "ios-group", body: "ios-author: Bring chairs"}
      assert message.apns.payload.aps."thread-id" == "group-#{group.id}"
      assert message.apns.payload.aps."mutable-content" == 1
      assert message.apns.headers["apns-collapse-id"] == "group-#{group.id}-chat"
      assert message.data["sender_icon"] =~ ~r"\Ahttps?://.+/avatar/profile/#{author.id}\?"
    end

    test "an expired payload is not sent" do
      account = account_fixture()
      device!(account, "en")

      payload =
        PushNotifications.localized(fn ->
          %{title: "Old", body: "news", expires_at: System.system_time(:second) - 1}
        end)

      assert :ok =
               PushNotifications.DeliverWorker.perform(%Oban.Job{
                 args: %{"account_ids" => [account.id], "payload" => payload}
               })

      refute_receive {:firebase_send_request, _request}
    end

    test "the test notification follows the device's language" do
      account = account_fixture()
      device!(account, nil)

      assert {:ok, _result} = Accounts.send_test_push_notification(account)
      assert sent_titles(1) == ["Potok obaveštenja su uključena"]
    end
  end

  defp sent_titles(count) do
    for _request <- 1..count, do: sent_message().data["title"]
  end

  defp sent_message do
    assert_receive {:firebase_send_request, request}
    request[:json].message
  end

  defp device!(account, locale, platform \\ :android) do
    {:ok, subscription} =
      Accounts.upsert_push_subscription(account, %{
        subscription_type: :fcm,
        device_platform: platform,
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
