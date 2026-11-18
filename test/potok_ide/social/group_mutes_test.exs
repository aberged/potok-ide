defmodule PotokIde.Social.GroupMutesTest do
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupMembership, GroupMutes}

  setup do
    {author_account, author} = account_with_profile!("mute-author")
    {ana_account, ana} = account_with_profile!("mute-ana")
    {bob_account, bob} = account_with_profile!("mute-bob")
    group = group_with_members!(author, [ana, bob], %{"name" => "mute-group"})

    %{
      author_account: author_account,
      author: author,
      ana_account: ana_account,
      ana: ana,
      bob_account: bob_account,
      bob: bob,
      group: group
    }
  end

  describe "set/3" do
    test "silences for a while, until turned on, and lets the group speak again", ctx do
      assert {:ok, until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")
      assert DateTime.diff(until, DateTime.utc_now()) in 3_500..3_600
      assert Social.group_muted_until(ctx.ana, ctx.group) == until
      assert Social.muted_group_ids(ctx.ana) == [ctx.group.id]
      assert Social.muted_group_ids(ctx.bob) == []

      assert {:ok, forever} = Social.set_group_mute(ctx.ana, ctx.group, "forever")
      assert GroupMutes.forever?(forever)

      assert {:ok, nil} = Social.set_group_mute(ctx.ana, ctx.group, nil)
      assert Social.group_muted_until(ctx.ana, ctx.group) == nil
      assert Social.muted_group_ids(ctx.ana) == []
    end

    test "tells the profile's pages", ctx do
      Social.subscribe_profile(ctx.ana)
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "week")

      ana_id = ctx.ana.id
      group_id = ctx.group.id
      assert_receive {:group_mute_changed, ^ana_id, ^group_id}
    end

    test "only members can, and only for the lengths offered", ctx do
      {_account, stranger} = account_with_profile!("mute-stranger")

      assert {:error, :not_a_member} = Social.set_group_mute(stranger, ctx.group, "hour")
      assert {:error, :invalid_duration} = Social.set_group_mute(ctx.ana, ctx.group, "year")
    end

    test "a mute that ran out silences nothing", ctx do
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")
      past = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

      Repo.update_all(
        from(gm in GroupMembership,
          where: gm.group_id == ^ctx.group.id and gm.profile_id == ^ctx.ana.id
        ),
        set: [muted_until: past]
      )

      assert Social.group_muted_until(ctx.ana, ctx.group) == nil
      assert Social.muted_group_ids(ctx.ana) == []
    end

    test "a thread follows the conversation it was started from", ctx do
      {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "a thread here"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.author, ctx.group, value, %{"name" => "nit"})

      for profile <- [ctx.ana, ctx.bob], do: :ok = Social.join_thread(profile, thread)
      {:ok, until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")

      assert Enum.sort(Social.muted_group_ids(ctx.ana)) == Enum.sort([ctx.group.id, thread.id])
      assert Social.group_muted_until(ctx.ana, thread) == until
      assert Social.group_muted_until(ctx.bob, thread) == nil
    end
  end

  describe "unread values" do
    test "leave the badge and the sums, and stay on the group's own row", ctx do
      other = group_with_members!(ctx.author, [ctx.ana], %{"name" => "mute-other"})
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")

      {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "one"})
      {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "two"})
      {:ok, _} = Social.create_value(ctx.author, other, %{"content" => "three"})

      assert Social.count_root_group_unread_values(ctx.ana) == 1
      assert Social.nav_counts(ctx.ana).root_unread == 1
      assert Social.nav_counts(ctx.ana).muted_group_ids == [ctx.group.id]

      overview = Social.unread_overview(ctx.ana)
      assert overview.total == 1

      assert Social.unread_counts_for(overview, [ctx.group.id, other.id]) == %{
               ctx.group.id => 0,
               other.id => 1
             }

      assert Social.muted_unread_counts(overview, [ctx.group.id, other.id]) == %{
               ctx.group.id => 2
             }

      # Bob did not silence it.
      assert Social.count_root_group_unread_values(ctx.bob) == 2
    end

    test "count again once the group speaks", ctx do
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "forever")
      {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "one"})
      assert Social.count_root_group_unread_values(ctx.ana) == 0

      {:ok, nil} = Social.set_group_mute(ctx.ana, ctx.group, nil)
      assert Social.count_root_group_unread_values(ctx.ana) == 1
    end
  end

  describe "pushes" do
    setup ctx do
      request_pid = self()
      configure_push_notifications(request_pid)

      {:ok, ana_device} =
        Accounts.upsert_push_subscription(Accounts.get_account!(ctx.ana_account.id), push_attrs())

      {:ok, bob_device} =
        Accounts.upsert_push_subscription(Accounts.get_account!(ctx.bob_account.id), push_attrs())

      %{ana_device: ana_device.endpoint, bob_device: bob_device.endpoint}
    end

    test "a new value passes a member who silenced the group by", ctx do
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")
      {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "for everyone"})

      assert pushed() == [ctx.bob_device]
    end

    test "a mention and an answer still reach them", ctx do
      {:ok, ana_value} = Social.create_value(ctx.ana, ctx.group, %{"content" => "mine"})
      _ = pushed()
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")

      {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "hi @mute-ana"})
      assert Enum.sort(pushed()) == Enum.sort([ctx.ana_device, ctx.bob_device])

      {:ok, _} =
        Social.create_value(ctx.author, ctx.group, %{
          "content" => "an answer",
          "parent_id" => ana_value.id
        })

      assert Enum.sort(pushed()) == Enum.sort([ctx.ana_device, ctx.bob_device])
    end

    test "a value in a thread of a silenced conversation passes them by", ctx do
      {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.author, ctx.group, value, %{"name" => "nit"})

      for profile <- [ctx.ana, ctx.bob], do: :ok = Social.join_thread(profile, thread)
      _ = pushed()
      {:ok, _until} = Social.set_group_mute(ctx.ana, ctx.group, "hour")

      {:ok, _} = Social.create_value(ctx.author, thread, %{"content" => "in the thread"})

      assert pushed() == [ctx.bob_device]
    end

    test "a value in a thread pushes only those who take part in it", ctx do
      {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.author, ctx.group, value, %{"name" => "nit"})

      _ = pushed()
      {:ok, _} = Social.create_value(ctx.author, thread, %{"content" => "nobody else here"})
      assert pushed() == []

      :ok = Social.join_thread(ctx.bob, thread)
      {:ok, _} = Social.create_value(ctx.author, thread, %{"content" => "now bob is"})
      assert pushed() == [ctx.bob_device]
    end
  end

  # The endpoints pushed to, once the pushes of the last write went out.
  defp pushed(acc \\ []) do
    receive do
      {:push_request, options} -> pushed([options[:url] | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp push_attrs do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      endpoint:
        "https://updates.push.services.mozilla.com/wpush/v2/#{System.unique_integer([:positive])}",
      auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      p256dh: Base.url_encode64(public_key, padding: false),
      expires_at: nil,
      user_agent: "ExUnit"
    }
  end

  defp configure_push_notifications(request_pid) do
    original_config = Application.get_env(:potok_ide, PushNotifications, [])
    on_exit(fn -> Application.put_env(:potok_ide, PushNotifications, original_config) end)

    Application.put_env(
      :potok_ide,
      PushNotifications,
      ttl: 60,
      vapid_subject: "mailto:test@example.com",
      vapid_public_key: Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
      vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      request_fun: fn options ->
        send(request_pid, {:push_request, options})
        {:ok, %Req.Response{status: 201, body: ""}}
      end
    )
  end
end
