defmodule PotokIde.EventsFixtures do
  @moduledoc """
  Profiles, groups, events and push devices for calendar tests.
  """

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Events
  alias PotokIde.Events.Recurrence
  alias PotokIde.PushNotifications
  alias PotokIde.Social

  @zone "Europe/Belgrade"

  def zone, do: @zone

  def account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {Accounts.get_account!(account.id), profile}
  end

  @doc "A group in `parent` (the root group by default) created by `owner`, with `members`."
  def group_with_members!(owner, members, attrs \\ %{}) do
    parent = Map.get(attrs, :parent) || Social.get_root_group!()

    {:ok, group} =
      Social.create_group(
        owner,
        parent,
        Map.merge(
          %{
            "name" => "group-#{System.unique_integer([:positive])}",
            "description" => "",
            "description_format" => :markdown,
            "home_page" => :chat
          },
          Map.delete(attrs, :parent)
        )
      )

    Enum.each(members, &add_member!(owner, group, &1))
    group
  end

  def add_member!(owner, group, member) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    :ok
  end

  @doc "Today in the test zone."
  def today, do: Recurrence.local_date(DateTime.utc_now(), @zone)

  @doc "Form params for an event on `date`, 18:00 to 19:30, reminding an hour before."
  def event_attrs(%Date{} = date, attrs \\ %{}) do
    Map.merge(
      %{
        "title" => "Training",
        "description" => "",
        "location" => "Hall 2",
        "all_day" => "false",
        "start_date" => Date.to_iso8601(date),
        "start_time" => "18:00",
        "end_date" => Date.to_iso8601(date),
        "end_time" => "19:30",
        "recurrence" => "none",
        "recurrence_interval" => "1",
        "reminder_minutes" => ["", "60"]
      },
      attrs
    )
  end

  def create_event!(profile, group, attrs, opts \\ [announce: false]) do
    {:ok, event} = Events.create_event(profile, group, attrs, @zone, opts)
    event
  end

  @doc """
  Sends every push request to the test process as `{:push_request, options}`
  instead of the network; `options[:url]` is the device's endpoint.
  """
  def capture_push_requests! do
    test_pid = self()
    original = Application.get_env(:potok_ide, PushNotifications, [])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:potok_ide, PushNotifications, original)
    end)

    Application.put_env(:potok_ide, PushNotifications,
      ttl: 60,
      vapid_subject: "mailto:test@example.com",
      vapid_public_key: Base.url_encode64(<<4>> <> :crypto.strong_rand_bytes(64), padding: false),
      vapid_private_key: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      request_fun: fn options ->
        send(test_pid, {:push_request, options})
        {:ok, %Req.Response{status: 201, body: ""}}
      end
    )
  end

  @doc "A web push device of `account`; returns its endpoint."
  def push_device!(account, locale \\ nil) do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, subscription} =
      Accounts.upsert_push_subscription(account, %{
        endpoint:
          "https://updates.push.services.mozilla.com/wpush/v2/#{System.unique_integer([:positive])}",
        auth: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        p256dh: Base.url_encode64(public_key, padding: false),
        expires_at: nil,
        user_agent: "ExUnit",
        locale: locale
      })

    subscription.endpoint
  end

  @doc "The endpoints that got a push since the last call, sorted."
  def pushed_endpoints(acc \\ []) do
    receive do
      {:push_request, options} -> pushed_endpoints([options[:url] | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
