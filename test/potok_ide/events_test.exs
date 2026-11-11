defmodule PotokIde.EventsTest do
  # Push requests are captured through the global push configuration.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.{Event, Recurrence}
  alias PotokIde.Social
  alias PotokIde.Social.{GroupAreas, GroupRoutes}

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

  describe "public events" do
    setup do
      {outsider_account, outsider} = account_with_profile!("ev-public-out")
      %{outsider_account: outsider_account, outsider: outsider, date: Date.add(today(), 2)}
    end

    test "are made public, or private again, only with publish_events", ctx do
      public_attrs = event_attrs(ctx.date, %{"is_public" => "true"})

      refute create_event!(ctx.member, ctx.group, public_attrs).is_public
      own = create_event!(ctx.member, ctx.group, event_attrs(ctx.date))
      {:ok, own} = Events.update_event(ctx.member, own, %{"is_public" => "true"})
      refute own.is_public

      # Admins hold every permission.
      event = create_event!(ctx.owner, ctx.group, public_attrs)
      assert event.is_public

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :publish_events,
          :allow
        )

      {:ok, own} = Events.update_event(ctx.member, own, %{"is_public" => "true"})
      assert own.is_public

      root = Social.get_root_group!()
      refute Events.can_publish?(Social.get_group_access(ctx.owner, root), root)
    end

    test "every profile sees and answers them", ctx do
      private = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"title" => "Closed"}))

      public =
        create_event!(
          ctx.owner,
          ctx.group,
          event_attrs(ctx.date, %{"title" => "Open", "is_public" => "true"})
        )

      assert {:error, :not_found} = Events.get_event(ctx.outsider, private.id)
      assert {:ok, %Event{id: public_id}} = Events.get_event(ctx.outsider, public.id)
      assert public_id == public.id

      {from, to} = window(ctx.date)
      assert Events.list_occurrences([], from, to) == []

      assert [%{event: %Event{id: ^public_id}}] =
               Events.list_occurrences([], from, to, public: true)

      # The profile's groups and the public events, each event once.
      assert Events.list_occurrences([ctx.group.id], from, to, public: true)
             |> Enum.map(& &1.event.id) == [private.id, public.id]

      assert {:error, :not_a_member_of_group} =
               Events.respond(ctx.outsider, private, ctx.date, :going)

      assert {:ok, _} = Events.respond(ctx.outsider, public, ctx.date, :going)
      assert {:ok, _} = Events.respond(ctx.member, public, ctx.date, :maybe)

      summary = Events.response_summary(public, ctx.date, ctx.outsider)
      assert summary.counts == %{going: 1, maybe: 1, declined: 0}
      assert summary.mine == :going

      reminders = %{"reminder_minutes" => ["", "1440"]}
      assert {:ok, _} = Events.set_member_reminders(ctx.outsider, public, reminders)

      assert {:error, :not_a_member_of_group} =
               Events.set_member_reminders(ctx.outsider, private, reminders)

      # Made private again, it is the members' only.
      {:ok, closed} = Events.update_event(ctx.owner, public, %{"is_public" => "false"})
      assert {:error, :not_found} = Events.get_event(ctx.outsider, public.id)
      assert Events.response_summary(closed, ctx.date, ctx.member).counts.going == 0
    end

    test "a group's public events, for its calendar", ctx do
      refute Events.public_events?(ctx.group)
      _private = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
      refute Events.public_events?(ctx.group)

      public =
        create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))

      elsewhere = group_with_members!(ctx.owner, [])
      create_event!(ctx.owner, elsewhere, event_attrs(ctx.date, %{"is_public" => "true"}))
      assert Events.public_events?(ctx.group)

      {from, to} = window(ctx.date)
      public_id = public.id

      assert [%{event: %Event{id: ^public_id}}] =
               Events.list_occurrences([], from, to, public: [ctx.group.id])

      assert Events.list_occurrences([], from, to, public: []) == []

      {:ok, _cancelled} = Events.cancel_event(ctx.owner, public)
      refute Events.public_events?(ctx.group)
    end

    test "changes reach those who said they come", ctx do
      capture_push_requests!()

      event =
        create_event!(
          ctx.owner,
          ctx.group,
          event_attrs(ctx.date, %{"is_public" => "true", "recurrence" => "weekly"})
        )

      next_week = Date.add(ctx.date, 7)
      {away_account, away} = account_with_profile!("ev-public-away")
      member_device = push_device!(ctx.member_account)
      outsider_device = push_device!(ctx.outsider_account)
      _away_device = push_device!(away_account)

      {:ok, _} = Events.respond(ctx.outsider, event, next_week, :going)
      {:ok, _} = Events.respond(away, event, ctx.date, :declined)

      # The new time drops the answers to come, but they are told first.
      {:ok, event} = Events.update_event(ctx.owner, event, %{"start_time" => "17:00"})
      assert pushed_endpoints() == Enum.sort([member_device, outsider_device])

      {:ok, _} = Events.respond(ctx.outsider, event, next_week, :maybe)
      {:ok, event} = Events.cancel_occurrence(ctx.owner, event, next_week)
      assert pushed_endpoints() == Enum.sort([member_device, outsider_device])

      {:ok, _event} = Events.cancel_event(ctx.owner, event)
      assert pushed_endpoints() == Enum.sort([member_device, outsider_device])
    end

    test "made private, they no longer concern those who are no members", ctx do
      capture_push_requests!()
      event = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))
      member_device = push_device!(ctx.member_account)
      _outsider_device = push_device!(ctx.outsider_account)
      {:ok, _} = Events.respond(ctx.outsider, event, ctx.date, :going)

      {:ok, _event} =
        Events.update_event(ctx.owner, event, %{"is_public" => "false", "location" => "Hall 3"})

      assert pushed_endpoints() == [member_device]
    end

    test "changes are broadcast to calendars that show public events", ctx do
      Events.subscribe(:public)
      group_id = ctx.group.id

      private = create_event!(ctx.owner, ctx.group, event_attrs(ctx.date))
      refute_received {:calendar, _}

      public =
        create_event!(ctx.owner, ctx.group, event_attrs(ctx.date, %{"is_public" => "true"}))

      assert_received {:calendar, {:events_changed, ^group_id}}

      {:ok, _} = Events.respond(ctx.outsider, public, ctx.date, :going)
      assert_received {:calendar, {:responses_changed, _event_id, _date}}

      # Made private: calendars showing it drop it.
      {:ok, _} = Events.update_event(ctx.owner, public, %{"is_public" => "false"})
      assert_received {:calendar, {:events_changed, ^group_id}}

      {:ok, _} = Events.update_event(ctx.owner, private, %{"title" => "Renamed"})
      refute_received {:calendar, _}
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

  describe "places" do
    setup ctx do
      # A spot the owner and the member are in, a closed one only the owner is
      # in, and a group with no place.
      spot =
        group_with_members!(ctx.owner, [ctx.member], %{
          "name" => "Dom kulture",
          "latitude" => 45.25,
          "longitude" => 19.85
        })

      closed =
        group_with_members!(ctx.owner, [], %{
          "name" => "Kancelarija",
          "latitude" => 45.26,
          "longitude" => 19.86
        })

      plain = group_with_members!(ctx.owner, [ctx.member])
      %{spot: spot, closed: closed, plain: plain, date: Date.add(today(), 5)}
    end

    test "an event takes place at a group the author sees, or at a point of its own", ctx do
      attrs = event_attrs(ctx.date, %{"place_group_id" => "#{ctx.spot.id}"})
      assert {:ok, event} = Events.create_event(ctx.member, ctx.group, attrs, zone())
      assert event.place_group_id == ctx.spot.id
      assert event.location == "Hall 2"

      assert %{group: group, lat: 45.25, lng: 19.85, shape: :point} =
               Events.place(ctx.member, event)

      assert group.id == ctx.spot.id

      for id <- [ctx.closed.id, ctx.plain.id, Social.get_root_group!().id] do
        attrs = event_attrs(ctx.date, %{"place_group_id" => "#{id}"})
        assert {:error, changeset} = Events.create_event(ctx.member, ctx.group, attrs, zone())
        assert %{place_group_id: ["That group has no place you can see."]} = errors_on(changeset)
      end

      attrs = event_attrs(ctx.date, %{"latitude" => "44.8125004", "longitude" => "20.4612"})
      assert {:ok, event} = Events.create_event(ctx.member, ctx.group, attrs, zone())
      assert {event.latitude, event.longitude} == {44.8125, 20.4612}

      assert Events.place(ctx.other, event) == %{
               group: nil,
               lat: 44.8125,
               lng: 20.4612,
               shape: :point,
               bounds: [[44.8125, 20.4612], [44.8125, 20.4612]],
               length: nil
             }
    end

    test "a group and a point at once, half a point or a point off the Earth is a mistake",
         ctx do
      both =
        event_attrs(ctx.date, %{
          "place_group_id" => "#{ctx.spot.id}",
          "latitude" => "45.0",
          "longitude" => "20.0"
        })

      assert {:error, changeset} = Events.create_event(ctx.member, ctx.group, both, zone())

      assert %{place_group_id: ["An event's place is a group or a point on the map, not both."]} =
               errors_on(changeset)

      half = event_attrs(ctx.date, %{"latitude" => "45.0"})
      assert {:error, changeset} = Events.create_event(ctx.member, ctx.group, half, zone())
      assert %{longitude: ["can't be blank"]} = errors_on(changeset)

      off = event_attrs(ctx.date, %{"latitude" => "91", "longitude" => "20"})
      assert {:error, changeset} = Events.create_event(ctx.member, ctx.group, off, zone())
      assert %{latitude: [_message]} = errors_on(changeset)
    end

    test "the place follows its group and shows only to those who see the group", ctx do
      attrs = event_attrs(ctx.date, %{"place_group_id" => "#{ctx.closed.id}"})
      event = create_event!(ctx.owner, ctx.group, attrs)

      assert %{group: %{id: closed_id}} = Events.place(ctx.owner, event)
      assert closed_id == ctx.closed.id
      # The member sees the event but not the closed group: only its words.
      assert Events.place(ctx.member, event) == nil

      {:ok, _moved} =
        Social.update_group(ctx.owner, ctx.closed, %{"latitude" => 44.0, "longitude" => 21.0})

      assert %{lat: 44.0, lng: 21.0} = Events.place(ctx.owner, event)

      # Deleting the group leaves the words.
      {:ok, _deleted} = Social.delete_group(ctx.owner, Repo.reload!(ctx.closed))
      event = Repo.reload!(event)
      assert event.place_group_id == nil
      assert event.location == "Hall 2"
      assert Events.place(ctx.owner, event) == nil
    end

    test "a group kept as it was stays, though the editor no longer sees it", ctx do
      attrs = event_attrs(ctx.date, %{"place_group_id" => "#{ctx.spot.id}"})
      event = create_event!(ctx.member, ctx.group, attrs)
      {:ok, _} = Social.remove_group_member(ctx.owner, ctx.spot, ctx.member)

      assert {:ok, updated} =
               Events.update_event(
                 ctx.member,
                 event,
                 %{"title" => "Renamed", "place_group_id" => "#{ctx.spot.id}"}
               )

      assert updated.place_group_id == ctx.spot.id
    end

    test "members are told when the place on the map changes", ctx do
      capture_push_requests!()
      owner_device = push_device!(ctx.owner_account)
      event = create_event!(ctx.member, ctx.group, event_attrs(ctx.date))

      {:ok, event} =
        Events.update_event(ctx.member, event, %{"place_group_id" => "#{ctx.spot.id}"})

      assert pushed_endpoints() == [owner_device]

      {:ok, _event} =
        Events.update_event(ctx.member, event, %{
          "place_group_id" => "",
          "latitude" => "45.1",
          "longitude" => "19.9"
        })

      assert pushed_endpoints() == [owner_device]
    end

    test "an area or a route of its own keeps its pin, and takes the other's place", ctx do
      {:ok, area} =
        GroupAreas.decode(%{
          "type" => "Polygon",
          "coordinates" => [
            [[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.3], [19.8, 45.2]]
          ]
        })

      # The pin the form sent does not count: the area's is inside it.
      attrs =
        event_attrs(ctx.date, %{"latitude" => "1", "longitude" => "1"}) |> Map.put("area", area)

      assert {:ok, event} = Events.create_event(ctx.member, ctx.group, attrs, zone())
      assert_in_delta event.latitude, 45.25, 0.01
      assert_in_delta event.longitude, 19.85, 0.01

      assert %{group: nil, shape: :area, bounds: [[45.2, 19.8], [45.3, 19.9]], length: nil} =
               Events.place(ctx.other, event)

      assert %{"type" => "MultiPolygon"} = Events.shape_geojson(event)

      {:ok, route} =
        GroupRoutes.decode(%{
          "type" => "LineString",
          "coordinates" => [[19.81, 45.21], [19.85, 45.22]]
        })

      assert {:ok, event} = Events.update_event(ctx.member, event, %{"route" => route})
      event = Events.load_shape(event)
      assert {event.area, event.latitude, event.longitude} == {nil, 45.21, 19.81}
      assert %{shape: :route, length: meters} = Events.place(ctx.member, event)
      assert_in_delta meters, 3300, 300

      both =
        event_attrs(ctx.date, %{"latitude" => "45", "longitude" => "19"})
        |> Map.merge(%{"area" => area, "route" => route})

      assert {:error, changeset} = Events.create_event(ctx.member, ctx.group, both, zone())
      assert %{route: [_message]} = errors_on(changeset)

      # A group in place of its own place leaves no route behind.
      {:ok, event} =
        Events.update_event(ctx.member, event, %{
          "place_group_id" => "#{ctx.spot.id}",
          "latitude" => "",
          "longitude" => ""
        })

      event = Events.load_shape(event)
      assert {event.route, event.latitude, event.place_group_id} == {nil, nil, ctx.spot.id}
      assert Events.shape_geojson(event) == nil
    end

    test "an event without a date shows its next occurrence", ctx do
      event = create_event!(ctx.member, ctx.group, event_attrs(ctx.date))
      assert Events.upcoming_occurrence(event).date == ctx.date

      daily =
        create_event!(ctx.member, ctx.group, event_attrs(today(), %{"recurrence" => "daily"}))

      assert Events.upcoming_occurrence(daily).date in [today(), Date.add(today(), 1)]
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
