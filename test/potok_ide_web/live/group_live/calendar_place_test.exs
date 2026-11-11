defmodule PotokIdeWeb.GroupLive.CalendarPlaceTest do
  @moduledoc """
  An event's place on a map (`CalendarState`, `CalendarTab`): a group with a
  place picked from a menu, or a point picked on a map, never both, and the
  event's link to the root's map, shown only with what the viewer may see.
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.Event
  alias PotokIde.Repo
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("calp-owner")
    {member_account, member} = account_with_profile!("calp-member")

    # The calendar's group stands in Novi Sad; a bakery a kilometre away and a
    # public square far off have a place, and so does a closed office only
    # the owner is in.
    group =
      group_with_members!(owner, [member], %{
        "name" => "Mesna zajednica",
        "is_public" => true,
        "latitude" => 45.25,
        "longitude" => 19.85
      })

    bakery =
      group_with_members!(owner, [member], %{
        "name" => "Pekara",
        "latitude" => 45.25,
        "longitude" => 19.8628
      })

    square =
      group_with_members!(owner, [], %{
        "name" => "Trg u Nišu",
        "is_public" => true,
        "latitude" => 43.32,
        "longitude" => 21.9
      })

    office =
      group_with_members!(owner, [], %{
        "name" => "Kancelarija",
        "latitude" => 45.251,
        "longitude" => 19.851
      })

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      bakery: bakery,
      square: square,
      office: office,
      root: Social.get_root_group!(),
      date: today() |> Date.end_of_month() |> Date.add(10)
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> put_connect_params(%{"time_zone" => zone()})
    |> live(path)
  end

  defp calendar_path(group, date, extra \\ []) do
    month = Calendar.strftime(date, "%Y-%m")
    ~p"/groups/#{group.id}/calendar?#{[{:month, month} | extra]}"
  end

  defp new_event_form(ctx) do
    {:ok, lv, _html} = live_as(ctx.member_account, calendar_path(ctx.group, ctx.date))
    lv |> element("#calendar-day-#{ctx.date}") |> render_click()
    lv |> element("#calendar-new-event") |> render_click()
    lv
  end

  defp input_value(lv, id) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{id}")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp save(lv, attrs \\ %{}) do
    lv
    |> form("#calendar-event-form", event: Map.merge(%{"title" => "Sastanak"}, attrs))
    |> render_submit(%{"announce" => "false"})
  end

  test "the menu offers groups with a place, nearest first, and a pick fills the place", ctx do
    lv = new_event_form(ctx)
    refute has_element?(lv, "#calendar-place-chip")

    lv |> element("#calendar-place-toggle") |> render_click()

    ids =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='calendar-place-option-']:not([id*='-pin-'])")
      |> LazyHTML.attribute("id")

    assert ids == [
             "calendar-place-option-#{ctx.group.id}",
             "calendar-place-option-#{ctx.bakery.id}",
             "calendar-place-option-#{ctx.square.id}"
           ]

    assert has_element?(lv, "#calendar-place-option-#{ctx.bakery.id}", ~r/1[.,]0 km/)

    lv
    |> form("#calendar-place-search-form", %{"calendar_place" => %{"q" => "pek"}})
    |> render_change()

    refute has_element?(lv, "#calendar-place-option-#{ctx.group.id}")
    lv |> element("#calendar-place-option-#{ctx.bakery.id}") |> render_click()

    assert has_element?(lv, "#calendar-place-chip", "Pekara")
    assert has_element?(lv, "#calendar-place-group-id[value='#{ctx.bakery.id}']")
    assert has_element?(lv, "#event_location[value='Pekara']")
    assert has_element?(lv, "#calendar-place-private-hint")

    save(lv)

    event = Repo.one!(Event)
    assert event.place_group_id == ctx.bakery.id
    assert event.location == "Pekara"
    assert has_element?(lv, "#calendar-event-location-text", "Pekara")
    assert has_element?(lv, "#calendar-event-place-group[href='/groups/#{ctx.bakery.id}']")

    assert has_element?(
             lv,
             "#calendar-event-map[href='/groups/#{ctx.root.id}/map?event=#{event.id}']"
           )

    # Another pick replaces the name the first one wrote; words of one's own stay.
    lv |> element("#calendar-edit-event") |> render_click()
    lv |> element("#calendar-place-toggle") |> render_click()
    lv |> element("#calendar-place-option-#{ctx.square.id}") |> render_click()
    assert has_element?(lv, "#event_location[value='Trg u Nišu']")
    refute has_element?(lv, "#calendar-place-private-hint")

    lv |> form("#calendar-event-form", event: %{"location" => "Kod česme"}) |> render_change()
    lv |> element("#calendar-place-toggle") |> render_click()
    lv |> element("#calendar-place-option-#{ctx.bakery.id}") |> render_click()
    assert has_element?(lv, "#event_location[value='Kod česme']")
  end

  test "a point picked on the map is saved, and a group and a point replace each other", ctx do
    lv = new_event_form(ctx)
    refute has_element?(lv, "#calendar-place-map")

    lv |> element("#calendar-place-on-map") |> render_click()
    assert has_element?(lv, "#calendar-place-map[phx-hook='LocationPicker'][data-mode='point']")
    assert has_element?(lv, "#calendar-place-map[data-area-event='calendar_place_area']")
    assert has_element?(lv, "#calendar-place-map[data-center='[45.25,19.85]']")
    assert has_element?(lv, "#calendar-place-mode-point[aria-checked='true']")
    refute has_element?(lv, "#calendar-place-on-map")

    lv
    |> form("#calendar-event-form", event: %{"latitude" => "45.2671", "longitude" => "19.8335"})
    |> render_change()

    save(lv)

    event = Repo.one!(Event)
    assert {event.latitude, event.longitude, event.place_group_id} == {45.2671, 19.8335, nil}
    refute has_element?(lv, "#calendar-event-place-group")
    assert has_element?(lv, "#calendar-event-map")

    # The form opens with its map; a group takes the point's place.
    lv |> element("#calendar-edit-event") |> render_click()
    assert has_element?(lv, "#calendar-place-map")
    lv |> element("#calendar-place-toggle") |> render_click()
    lv |> element("#calendar-place-option-#{ctx.bakery.id}") |> render_click()
    refute has_element?(lv, "#calendar-place-map")
    assert input_value(lv, "calendar-place-latitude") in [nil, ""]
    save(lv)

    event = Repo.reload!(event)
    assert {event.latitude, event.place_group_id} == {nil, ctx.bakery.id}

    # And the map takes the group's place, opening where the group stands.
    lv |> element("#calendar-edit-event") |> render_click()
    lv |> element("#calendar-place-on-map") |> render_click()
    refute has_element?(lv, "#calendar-place-chip")
    assert has_element?(lv, "#calendar-place-map[data-center='[45.25,19.8628]']")
    lv |> element("#calendar-place-clear-point") |> render_click()
    refute has_element?(lv, "#calendar-place-map")
    save(lv)

    event = Repo.reload!(event)
    assert {event.latitude, event.place_group_id} == {nil, nil}
    refute has_element?(lv, "#calendar-event-map")
  end

  test "the map draws an area or a route as a group's Location card does", ctx do
    lv = new_event_form(ctx)
    lv |> element("#calendar-place-on-map") |> render_click()

    # An area: its tools and hint, and the pin the server puts inside it.
    lv |> element("#calendar-place-mode-area") |> render_click()
    assert_push_event(lv, "calendar_place_map_mode", %{mode: "area"})
    assert has_element?(lv, "#calendar-place-mode-area[aria-checked='true']")
    assert has_element?(lv, "#calendar-place-area-hint")
    refute has_element?(lv, "#calendar-place-area-tools.hidden")
    assert has_element?(lv, "#calendar-place-route-tools.hidden")

    square = %{
      "type" => "Polygon",
      "coordinates" => [[[19.8, 45.2], [19.9, 45.2], [19.9, 45.3], [19.8, 45.3], [19.8, 45.2]]]
    }

    render_hook(lv, "calendar_place_area", %{"area" => square})
    assert_reply(lv, %{ok: true, lat: lat, lng: lng})
    assert_in_delta lat, 45.25, 0.01
    assert_in_delta lng, 19.85, 0.01

    # The map writes the pin into the fields, as typed.
    lv
    |> form("#calendar-event-form", event: %{"latitude" => "#{lat}", "longitude" => "#{lng}"})
    |> render_change()

    save(lv)

    event = Repo.one!(Event) |> Events.load_shape()
    assert %Geo.MultiPolygon{} = event.area
    assert event.route == nil
    assert_in_delta event.latitude, 45.25, 0.01
    assert has_element?(lv, "#calendar-event-place-shape")
    assert has_element?(lv, "#calendar-event-map")

    # The form opens on the area; a route takes its place.
    lv |> element("#calendar-edit-event") |> render_click()
    assert has_element?(lv, "#calendar-place-map[data-mode='area'][data-area*='MultiPolygon']")
    lv |> element("#calendar-place-mode-route") |> render_click()

    walk = %{"type" => "LineString", "coordinates" => [[19.81, 45.21], [19.85, 45.22]]}
    render_hook(lv, "calendar_place_route", %{"route" => walk})
    assert_reply(lv, %{ok: true, lat: 45.21, lng: 19.81, length_text: _length})
    save(lv)

    event = Events.load_shape(Repo.reload!(event))
    assert {event.area, event.latitude, event.longitude} == {nil, 45.21, 19.81}
    assert %Geo.MultiLineString{} = event.route
    assert has_element?(lv, "#calendar-event-place-shape", "km")

    # A border the server refuses keeps the form open, saying why.
    lv |> element("#calendar-edit-event") |> render_click()
    lv |> element("#calendar-place-mode-area") |> render_click()

    bowtie = %{
      "type" => "Polygon",
      "coordinates" => [[[19.8, 45.2], [19.9, 45.3], [19.9, 45.2], [19.8, 45.3], [19.8, 45.2]]]
    }

    render_hook(lv, "calendar_place_area", %{"area" => bowtie})
    assert_reply(lv, %{ok: false})
    assert has_element?(lv, "#calendar-place-errors")
    save(lv)
    assert has_element?(lv, "#calendar-event-form")

    # A point drops the shape; so does taking the place off the map.
    lv |> element("#calendar-place-mode-point") |> render_click()
    lv |> element("#calendar-place-clear-point") |> render_click()
    save(lv)

    event = Events.load_shape(Repo.reload!(event))
    assert {event.area, event.route, event.latitude} == {nil, nil, nil}
  end

  test "a public event at a closed group shows others only its words", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.group,
        event_attrs(ctx.date, %{
          "is_public" => "true",
          "location" => "Kancelarija",
          "place_group_id" => "#{ctx.office.id}"
        })
      )

    path = calendar_path(ctx.group, ctx.date, event: event.id, on: Date.to_iso8601(ctx.date))

    {:ok, lv, _html} = live_as(ctx.owner_account, path)
    assert has_element?(lv, "#calendar-event-place-group")
    assert has_element?(lv, "#calendar-event-map")

    {outsider_account, _outsider} = account_with_profile!("calp-outsider")

    for account <- [ctx.member_account, outsider_account] do
      {:ok, lv, _html} = live_as(account, path)
      assert has_element?(lv, "#calendar-event-location-text", "Kancelarija")
      refute has_element?(lv, "#calendar-event-place-group")
      refute has_element?(lv, "#calendar-event-map")
    end
  end

  test "an author who no longer sees the group keeps it as the place", ctx do
    event =
      create_event!(
        ctx.member,
        ctx.group,
        event_attrs(ctx.date, %{"place_group_id" => "#{ctx.bakery.id}"})
      )

    {:ok, _} = Social.remove_group_member(ctx.owner, ctx.bakery, ctx.member)
    path = calendar_path(ctx.group, ctx.date, event: event.id, on: Date.to_iso8601(ctx.date))

    {:ok, lv, _html} = live_as(ctx.member_account, path)
    lv |> element("#calendar-edit-event") |> render_click()
    assert has_element?(lv, "#calendar-place-chip", "A group you do not see")
    refute has_element?(lv, "#calendar-place-chip", "Pekara")

    save(lv, %{"title" => "Renamed"})
    assert %Event{title: "Renamed", place_group_id: bakery_id} = Repo.reload!(event)
    assert bakery_id == ctx.bakery.id
  end

  test "a cancelled event keeps its words but has no link to the map", ctx do
    event =
      create_event!(
        ctx.member,
        ctx.group,
        event_attrs(ctx.date, %{"latitude" => "45.1", "longitude" => "19.9"})
      )

    {:ok, _cancelled} = Events.cancel_event(ctx.member, event)
    path = calendar_path(ctx.group, ctx.date, event: event.id, on: Date.to_iso8601(ctx.date))

    {:ok, lv, _html} = live_as(ctx.member_account, path)
    assert has_element?(lv, "#calendar-event-location-text", "Hall 2")
    refute has_element?(lv, "#calendar-event-map")
  end
end
