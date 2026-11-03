defmodule PotokIde.Events.RemindersTest do
  # Push requests are captured through the global push configuration.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.{Notifications, Recurrence, ReminderScheduler}
  alias PotokIde.Repo
  alias PotokIde.Social

  setup do
    capture_push_requests!()

    {owner_account, owner} = account_with_profile!("rm-owner")
    {member_account, member} = account_with_profile!("rm-member")
    {other_account, other} = account_with_profile!("rm-other")
    group = group_with_members!(owner, [member, other])

    %{
      owner: owner,
      member: member,
      other: other,
      group: group,
      owner_device: push_device!(owner_account),
      member_device: push_device!(member_account),
      other_device: push_device!(other_account),
      date: Date.add(today(), 2)
    }
  end

  defp at(date, time), do: Recurrence.to_utc(date, time, zone())

  test "members get the organizer's reminder when it is due", ctx do
    event = create_event!(ctx.member, ctx.group, event_attrs(ctx.date))
    assert event.next_reminder_at == at(ctx.date, ~T[17:00:00])

    assert :ok = Events.send_due_reminders(at(ctx.date, ~T[16:59:30]))
    assert pushed_endpoints() == []

    assert :ok = Events.send_due_reminders(at(ctx.date, ~T[17:00:20]))

    assert pushed_endpoints() ==
             Enum.sort([ctx.owner_device, ctx.member_device, ctx.other_device])

    # Handled once, and nothing is left to come.
    assert :ok = Events.send_due_reminders(at(ctx.date, ~T[17:00:50]))
    assert pushed_endpoints() == []
    assert Repo.reload!(event).next_reminder_at == nil
  end

  test "members who declined the occurrence get none", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    {:ok, _} = Events.respond(ctx.other, event, ctx.date, :declined)
    {:ok, _} = Events.respond(ctx.member, event, ctx.date, :maybe)

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert pushed_endpoints() == Enum.sort([ctx.owner_device, ctx.member_device])
  end

  test "members' own reminders replace the organizer's", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))

    {:ok, _} =
      Events.set_member_reminders(ctx.member, event, %{"reminder_minutes" => ["", "1440"]})

    {:ok, _} = Events.set_member_reminders(ctx.other, event, %{"reminder_minutes" => [""]})

    assert Events.member_reminders(ctx.member, event) == [1440]
    assert Events.member_reminders(ctx.other, event) == []
    assert Events.member_reminders(ctx.owner, event) == nil
    # The member's day-before reminder comes first now.
    assert Repo.reload!(event).next_reminder_at == at(Date.add(ctx.date, -1), ~T[18:00:00])

    Events.send_due_reminders(at(Date.add(ctx.date, -1), ~T[18:00:00]))
    assert pushed_endpoints() == [ctx.member_device]

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert pushed_endpoints() == [ctx.owner_device]

    {:ok, nil} = Events.set_member_reminders(ctx.other, event, :default)
    assert Events.member_reminders(ctx.other, event) == nil
  end

  test "reminders found too late are dropped", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))

    Events.send_due_reminders(at(ctx.date, ~T[17:20:00]))
    assert pushed_endpoints() == []
    assert Repo.reload!(event).reminded_through == at(ctx.date, ~T[17:20:00])
  end

  test "cancelled events and occurrences remind nobody", ctx do
    once = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    {:ok, _} = Events.cancel_event(ctx.owner, once)
    _ = pushed_endpoints()

    weekly =
      create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"recurrence" => "weekly"}))

    {:ok, weekly} = Events.cancel_occurrence(ctx.owner, weekly, ctx.date)
    _ = pushed_endpoints()

    assert weekly.next_reminder_at == at(Date.add(ctx.date, 7), ~T[17:00:00])

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert pushed_endpoints() == []
  end

  test "former members get none", ctx do
    _event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    {:ok, _} = Social.remove_group_member(ctx.owner, ctx.group, ctx.other)

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert pushed_endpoints() == Enum.sort([ctx.owner_device, ctx.member_device])
  end

  test "of a public event, those who are no members get them when they come", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))
    {going_account, going} = account_with_profile!("rm-public-going")
    {own_account, own} = account_with_profile!("rm-public-own")
    {silent_account, _silent} = account_with_profile!("rm-public-silent")
    going_device = push_device!(going_account)
    own_device = push_device!(own_account)
    _silent_device = push_device!(silent_account)

    {:ok, _} = Events.respond(going, event, ctx.date, :going)
    {:ok, _} = Events.respond(own, event, ctx.date, :maybe)
    {:ok, _} = Events.set_member_reminders(own, event, %{"reminder_minutes" => ["", "1440"]})

    Events.send_due_reminders(at(Date.add(ctx.date, -1), ~T[18:00:00]))
    assert pushed_endpoints() == [own_device]

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))

    assert pushed_endpoints() ==
             Enum.sort([ctx.owner_device, ctx.member_device, ctx.other_device, going_device])
  end

  test "an account with two member profiles gets one push per device", ctx do
    {account, first} = account_with_profile!("rm-twin-a")

    {:ok, second} =
      Social.create_profile_for_account(account, %{
        username: "rm-twin-b",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    group = group_with_members!(ctx.owner, [first, second])
    # The owner was told that both accepted the invitation.
    _ = pushed_endpoints()
    device = push_device!(account)
    _event = create_event!(ctx.owner, group, event_attrs(ctx.date))

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert pushed_endpoints() == Enum.sort([ctx.owner_device, device])
  end

  test "all-day events remind before 09:00 on the day", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.group,
        event_attrs(ctx.date, %{
          "all_day" => "true",
          "reminder_minutes" => ["", "0", "1440", "60"]
        })
      )

    # "An hour before" does not fit an all-day event and is dropped.
    assert event.reminder_minutes == [0, 1440]
    assert event.next_reminder_at == at(Date.add(ctx.date, -1), ~T[09:00:00])

    Events.send_due_reminders(at(Date.add(ctx.date, -1), ~T[09:00:00]))
    assert length(pushed_endpoints()) == 3

    assert Repo.reload!(event).next_reminder_at == at(ctx.date, ~T[09:00:00])
  end

  test "a repeating event's next reminder follows its next occurrence", ctx do
    event =
      create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"recurrence" => "daily"}))

    Events.send_due_reminders(at(ctx.date, ~T[17:00:00]))
    assert length(pushed_endpoints()) == 3
    assert Repo.reload!(event).next_reminder_at == at(Date.add(ctx.date, 1), ~T[17:00:00])
  end

  test "reminders are written in the language of each device", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
    occurrence = Recurrence.build(event, ctx.date)
    payload_for = Notifications.reminder(ctx.group, occurrence, 60)

    assert payload_for.("en").title == "Training"
    assert payload_for.("en").body =~ "In 1 hour"
    assert payload_for.("en").body =~ "18:00"
    assert payload_for.("en").body =~ "Hall 2"
    refute payload_for.("sr").body =~ "In 1 hour"
    assert payload_for.(nil) == payload_for.("sr")
    assert payload_for.("de") == payload_for.("sr")

    assert payload_for.("en").url ==
             "/groups/#{ctx.group.id}/calendar?event=#{event.id}&on=#{ctx.date}"
  end

  test "the scheduler does not start when it is turned off" do
    assert ReminderScheduler.start_link([]) == :ignore
  end

  test "next_reminder_at/3 is nil without offsets or after the last occurrence", ctx do
    event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))

    assert Events.Reminders.next_reminder_at(event, [], DateTime.utc_now()) == nil

    assert Events.Reminders.next_reminder_at(event, [60], at(ctx.date, ~T[17:00:00])) == nil
  end
end
