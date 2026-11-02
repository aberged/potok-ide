defmodule PotokIde.EventsTest do
  # Push requests are captured through the global push configuration.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.{Event, Recurrence}
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("ev-owner")
    {member_account, member} = account_with_profile!("ev-member")
    {other_account, other} = account_with_profile!("ev-other")
    group = group_with_members!(owner, [member, other])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      other_account: other_account,
      other: other,
      group: group
    }
  end

  describe "create_event/5" do
    test "members add events by default", %{member: member, group: group} do
      date = Date.add(today(), 3)

      assert {:ok, %Event{} = event} =
               Events.create_event(member, group, event_attrs(date), zone(), announce: false)

      assert event.time_zone == zone()
      assert event.starts_at == Recurrence.to_utc(date, ~T[18:00:00], zone())
      assert event.ends_at == Recurrence.to_utc(date, ~T[19:30:00], zone())
      assert event.reminder_minutes == [60]
      assert event.next_reminder_at == Recurrence.to_utc(date, ~T[17:00:00], zone())
    end

    test "the root group and non-members cannot hold events", %{owner: owner, group: group} do
      {_account, outsider} = account_with_profile!("ev-outsider")
      attrs = event_attrs(Date.add(today(), 1))

      assert {:error, :not_permitted} =
               Events.create_event(owner, Social.get_root_group!(), attrs, zone())

      assert {:error, :not_permitted} = Events.create_event(outsider, group, attrs, zone())
    end

    test "nobody but admins adds events once everyone loses the permission", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_events,
          :neutral
        )

      attrs = event_attrs(Date.add(today(), 1))
      assert {:error, :not_permitted} = Events.create_event(ctx.member, ctx.group, attrs, zone())
      assert {:ok, _event} = Events.create_event(ctx.owner, ctx.group, attrs, zone())
    end

    test "validates the form", %{member: member, group: group} do
      date = Date.add(today(), 1)

      assert {:error, changeset} =
               Events.create_event(
                 member,
                 group,
                 event_attrs(date, %{"title" => " ", "end_time" => "17:00"}),
                 zone()
               )

      assert %{title: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Events.create_event(
                 member,
                 group,
                 event_attrs(date, %{"end_time" => "17:00"}),
                 zone()
               )

      assert %{end_time: ["must not be before the start"]} = errors_on(changeset)
    end

    test "a weekly event always repeats on the weekday it starts on", ctx do
      # A Wednesday, repeating on Mondays and Fridays as well.
      date = next_weekday(today(), 3)

      event =
        create_event!(
          ctx.member,
          ctx.group,
          event_attrs(date, %{"recurrence" => "weekly", "recurrence_weekdays" => ["", "1", "5"]})
        )

      assert event.recurrence_weekdays == [1, 3, 5]
    end

    test "announces the event in the chat and pushes to the other members", ctx do
      capture_push_requests!()
      owner_device = push_device!(ctx.owner_account)
      member_device = push_device!(ctx.member_account)
      other_device = push_device!(ctx.other_account)

      event =
        create_event!(ctx.owner, ctx.group, event_attrs(Date.add(today(), 2)), announce: true)

      assert is_integer(event.value_id)
      value = Social.get_value_for_display(event.value_id)
      assert value.event.id == event.id
      assert value.content =~ "Training"
      assert value.link_preview_dismissed

      assert pushed_endpoints() == Enum.sort([member_device, other_device])
      refute owner_device in pushed_endpoints()

      assert Social.update_value(ctx.owner, value, %{"content" => "edited"}) ==
               {:error, :announcement}
    end

    test "is not announced without the right to post values", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :post_values, :neutral)

      event =
        create_event!(ctx.member, ctx.group, event_attrs(Date.add(today(), 2)), announce: true)

      assert event.value_id == nil
    end
  end

  describe "update_event/4 and cancel_event/2" do
    setup ctx do
      %{event: create_event!(ctx.member, ctx.group, event_attrs(Date.add(today(), 4)))}
    end

    test "the author and members with manage_events change an event", ctx do
      attrs = %{"title" => "Match"}

      assert {:error, :not_permitted} = Events.update_event(ctx.other, ctx.event, attrs)
      assert {:ok, %Event{title: "Match"}} = Events.update_event(ctx.member, ctx.event, attrs)
      # The owner is the group's admin, who holds every permission.
      assert {:ok, %Event{title: "Final"}} =
               Events.update_event(ctx.owner, ctx.event, %{"title" => "Final"})
    end

    test "an author who left the group cannot change the event", ctx do
      {:ok, _} = Social.remove_group_member(ctx.owner, ctx.group, ctx.member)

      assert {:error, :not_permitted} =
               Events.update_event(ctx.member, ctx.event, %{"title" => "Match"})
    end

    test "tells the other members when the time changes", ctx do
      capture_push_requests!()
      member_device = push_device!(ctx.member_account)
      owner_device = push_device!(ctx.owner_account)

      {:ok, event} = Events.update_event(ctx.member, ctx.event, %{"title" => "Renamed"})
      assert pushed_endpoints() == []
      assert event.sequence == 0

      {:ok, event} = Events.update_event(ctx.member, event, %{"start_time" => "17:00"})
      assert pushed_endpoints() == [owner_device]
      refute member_device in pushed_endpoints()
      assert event.sequence == 1

      {:ok, _event} =
        Events.update_event(ctx.member, event, %{"location" => "Field"}, notify: false)

      assert pushed_endpoints() == []
    end

    test "cancelling takes the event off the calendar and tells members who did not decline",
         ctx do
      capture_push_requests!()
      owner_device = push_device!(ctx.owner_account)
      _other_device = push_device!(ctx.other_account)
      date = Recurrence.start_date(ctx.event)
      {:ok, _} = Events.respond(ctx.other, ctx.event, date, :declined)

      assert {:ok, cancelled} = Events.cancel_event(ctx.member, ctx.event)
      assert Event.cancelled?(cancelled)
      assert cancelled.next_reminder_at == nil
      assert pushed_endpoints() == [owner_device]

      {from, to} = window(date)
      assert Events.list_occurrences([ctx.group.id], from, to) == []
      assert {:error, :cancelled} = Events.update_event(ctx.member, cancelled, %{"title" => "x"})
    end
  end

  describe "answers" do
    setup ctx do
      start = Date.add(today(), 1)
      event = create_event!(ctx.owner, ctx.group, event_attrs(start, %{"recurrence" => "weekly"}))
      %{event: event, start: start}
    end

    test "are kept per occurrence and count members only", ctx do
      next_week = Date.add(ctx.start, 7)

      assert {:ok, _} = Events.respond(ctx.member, ctx.event, ctx.start, :going)
      assert {:ok, _} = Events.respond(ctx.other, ctx.event, ctx.start, :maybe)
      assert {:ok, _} = Events.respond(ctx.member, ctx.event, next_week, :declined)
      assert {:ok, _} = Events.respond(ctx.member, ctx.event, ctx.start, :going)

      summary = Events.response_summary(ctx.event, ctx.start, ctx.member)
      assert summary.counts == %{going: 1, maybe: 1, declined: 0}
      assert summary.mine == :going
      assert [%{id: member_id}] = summary.profiles.going
      assert member_id == ctx.member.id

      assert Events.response_summary(ctx.event, next_week, ctx.member).mine == :declined

      {:ok, _} = Social.remove_group_member(ctx.owner, ctx.group, ctx.other)
      assert Events.response_summary(ctx.event, ctx.start, ctx.member).counts.maybe == 0

      assert {:ok, nil} = Events.respond(ctx.member, ctx.event, ctx.start, nil)
      assert Events.response_summary(ctx.event, ctx.start, ctx.member).mine == nil
    end

    test "only for dates that are occurrences, and only for members", ctx do
      {_account, outsider} = account_with_profile!("ev-answer-out")

      assert {:error, :not_found} =
               Events.respond(ctx.member, ctx.event, Date.add(ctx.start, 1), :going)

      assert {:error, :not_found} =
               Events.respond(ctx.member, ctx.event, Date.add(ctx.start, -7), :going)

      assert {:error, :not_a_member_of_group} =
               Events.respond(outsider, ctx.event, ctx.start, :going)
    end

    test "to come are dropped when the time or the dates change", ctx do
      next_week = Date.add(ctx.start, 7)
      {:ok, _} = Events.respond(ctx.member, ctx.event, ctx.start, :going)
      {:ok, _} = Events.respond(ctx.member, ctx.event, next_week, :going)

      {:ok, event} = Events.update_event(ctx.owner, ctx.event, %{"title" => "Renamed"})
      assert Events.response_summary(event, ctx.start, ctx.member).mine == :going

      # Every second week: next week's occurrence is gone, the first stays.
      {:ok, event} = Events.update_event(ctx.owner, event, %{"recurrence_interval" => "2"})
      assert Events.response_summary(event, ctx.start, ctx.member).mine == :going
      assert Events.response_summary(event, next_week, ctx.member).mine == nil

      {:ok, event} = Events.update_event(ctx.owner, event, %{"start_time" => "17:30"})
      assert Events.response_summary(event, ctx.start, ctx.member).mine == nil
    end

    test "cancelling one occurrence leaves the others", ctx do
      capture_push_requests!()
      member_device = push_device!(ctx.member_account)
      next_week = Date.add(ctx.start, 7)

      assert {:ok, event} = Events.cancel_occurrence(ctx.owner, ctx.event, next_week)
      assert event.excluded_dates == [next_week]
      assert pushed_endpoints() == [member_device]

      {from, _} = window(ctx.start)
      {_, to} = window(Date.add(ctx.start, 14))

      assert Events.list_occurrences([ctx.group.id], from, to) |> Enum.map(& &1.date) ==
               [ctx.start, Date.add(ctx.start, 14)]

      assert {:error, :not_found} = Events.cancel_occurrence(ctx.owner, event, next_week)
      assert {:error, :not_permitted} = Events.cancel_occurrence(ctx.other, event, ctx.start)
    end
  end

  describe "calendar_group_ids/3" do
    test "adds the sub-groups the profile is a member of", ctx do
      member_sub = group_with_members!(ctx.owner, [ctx.member], %{parent: ctx.group})
      _public_sub = group_with_members!(ctx.owner, [], %{"is_public" => true, parent: ctx.group})
      deep = group_with_members!(ctx.owner, [ctx.member], %{parent: member_sub})

      assert Events.calendar_group_ids(ctx.member, ctx.group, false) == [ctx.group.id]

      assert Enum.sort(Events.calendar_group_ids(ctx.member, ctx.group, true)) ==
               Enum.sort([ctx.group.id, member_sub.id, deep.id])

      root_ids = Events.calendar_group_ids(ctx.member, Social.get_root_group!(), false)
      assert Enum.all?([ctx.group.id, member_sub.id, deep.id], &(&1 in root_ids))

      {_account, outsider} = account_with_profile!("ev-ids-out")
      assert Events.calendar_group_ids(outsider, ctx.group, false) == []
    end
  end

  test "list_occurrences/3 expands repeats in the window", ctx do
    start = Date.add(today(), 1)
    create_event!(ctx.owner, ctx.group, event_attrs(start, %{"recurrence" => "daily"}))
    create_event!(ctx.owner, ctx.group, event_attrs(Date.add(start, 1), %{"title" => "Once"}))

    {from, _} = window(start)
    {_, to} = window(Date.add(start, 2))

    assert Events.list_occurrences([ctx.group.id], from, to)
           |> Enum.map(&{&1.date, &1.event.title}) == [
             {start, "Training"},
             {Date.add(start, 1), "Once"},
             {Date.add(start, 1), "Training"},
             {Date.add(start, 2), "Training"}
           ]
  end

  # The whole local `date` in the test zone.
  defp window(date) do
    {Recurrence.to_utc(date, ~T[00:00:00], zone()),
     Recurrence.to_utc(Date.add(date, 1), ~T[00:00:00], zone())}
  end

  defp next_weekday(date, weekday),
    do: Date.add(date, Integer.mod(weekday - Date.day_of_week(date), 7) + 7)
end
