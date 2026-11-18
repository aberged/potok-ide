defmodule PotokIde.Social.PushCoalescingTest do
  @moduledoc """
  A group pushes a member once until it is read: the next value waits until
  they have read up to the one they were told of, or five minutes pass. What
  is meant for them (a mention, an answer to their value) always goes out.
  """
  use PotokIde.DataCase

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.PushNotifications
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.GroupMembership

  setup do
    {_author_account, author} = account_with_profile!("coalesce-author")
    {ana_account, ana} = account_with_profile!("coalesce-ana")
    {bob_account, bob} = account_with_profile!("coalesce-bob")
    group = group_with_members!(author, [ana, bob], %{"name" => "coalesce-group"})

    configure_push_notifications(self())

    {:ok, ana_device} =
      Accounts.upsert_push_subscription(Accounts.get_account!(ana_account.id), push_attrs())

    {:ok, bob_device} =
      Accounts.upsert_push_subscription(Accounts.get_account!(bob_account.id), push_attrs())

    %{
      author: author,
      ana: ana,
      bob: bob,
      group: group,
      ana_device: ana_device.endpoint,
      bob_device: bob_device.endpoint
    }
  end

  test "a second value waits until the first is read", ctx do
    {:ok, first} = Social.create_value(ctx.author, ctx.group, %{"content" => "one"})
    assert Enum.sort(pushed()) == Enum.sort([ctx.ana_device, ctx.bob_device])

    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "two"})
    assert pushed() == []

    :ok = Social.mark_group_values_read(ctx.ana, ctx.group, first.id)
    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "three"})
    assert pushed() == [ctx.ana_device]
  end

  test "reading an older value than the one pushed is not enough", ctx do
    {:ok, older} = Social.create_value(ctx.author, ctx.group, %{"content" => "older"})
    :ok = Social.mark_group_values_read(ctx.ana, ctx.group, older.id)
    membership(ctx.ana, ctx.group) |> mark_pushed(older.id + 1_000_000)
    _ = pushed()

    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "new"})
    refute ctx.ana_device in pushed()
  end

  test "five minutes later the next value pushes again", ctx do
    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "one"})
    _ = pushed()

    from(gm in GroupMembership, where: gm.group_id == ^ctx.group.id)
    |> Repo.update_all(set: [last_pushed_at: DateTime.add(DateTime.utc_now(:second), -301)])

    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "two"})
    assert Enum.sort(pushed()) == Enum.sort([ctx.ana_device, ctx.bob_device])
  end

  test "a mention and an answer always go out and leave the wait alone", ctx do
    {:ok, ana_value} = Social.create_value(ctx.ana, ctx.group, %{"content" => "mine"})
    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "one"})
    _ = pushed()
    pushed_for = membership(ctx.ana, ctx.group).last_push_value_id

    {:ok, _} = Social.create_value(ctx.author, ctx.group, %{"content" => "hi @coalesce-ana"})
    assert pushed() == [ctx.ana_device]

    {:ok, _} =
      Social.create_value(ctx.author, ctx.group, %{
        "content" => "an answer",
        "parent_id" => ana_value.id
      })

    assert pushed() == [ctx.ana_device]
    assert membership(ctx.ana, ctx.group).last_push_value_id == pushed_for
  end

  test "a thread waits on its own, apart from its conversation", ctx do
    {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "start"})

    {:ok, thread} =
      Social.get_or_create_value_thread(ctx.author, ctx.group, value, %{"name" => "nit"})

    :ok = Social.join_thread(ctx.bob, thread)
    # Bob has not read "start", which the conversation pushed him.
    _ = pushed()

    {:ok, _} = Social.create_value(ctx.author, thread, %{"content" => "in the thread"})
    assert pushed() == [ctx.bob_device]

    {:ok, _} = Social.create_value(ctx.author, thread, %{"content" => "again"})
    assert pushed() == []
  end

  defp membership(profile, group),
    do: Repo.get_by!(GroupMembership, profile_id: profile.id, group_id: group.id)

  defp mark_pushed(%GroupMembership{} = membership, value_id) do
    from(gm in GroupMembership,
      where: gm.profile_id == ^membership.profile_id and gm.group_id == ^membership.group_id
    )
    |> Repo.update_all(
      set: [last_push_value_id: value_id, last_pushed_at: DateTime.utc_now(:second)]
    )
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
