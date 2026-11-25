defmodule PotokIdeWeb.GroupLive.SchedulingTest do
  @moduledoc """
  Scheduling a message from the composer: the dialog that asks for the time,
  the time the composer holds, the row above it and the list of what waits.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AccountProfile, ScheduledValue, ScheduledValues, Value}
  alias PotokIde.Storage
  alias PotokIdeWeb.GroupLive.Show.Scheduling

  @zone "Europe/Belgrade"

  setup do
    {author_account, author} = account_with_profile!("sc-author")
    {reader_account, reader} = account_with_profile!("sc-reader")
    group = group_with_members!(author, [reader])
    {:ok, _manifest} = Social.create_own_group_manifest(author, group)

    %{
      author_account: author_account,
      author: author,
      reader_account: reader_account,
      reader: reader,
      group: Social.get_group!(group.id)
    }
  end

  defp chat(account, group, query \\ %{}) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => @zone})
      |> live(~p"/groups/#{group.id}/values?#{query}")

    lv
  end

  # The browser's value of an input some minutes from now.
  defp local(minutes) do
    DateTime.utc_now(:second)
    |> DateTime.add(minutes, :minute)
    |> DateTime.shift_zone!(@zone)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp pick_time(lv, local \\ nil) do
    lv |> element("#group-value-schedule") |> render_click()
    lv |> form("#schedule-form", schedule: %{send_local: local || local(60)}) |> render_submit()
    lv
  end

  defp write(lv, content) do
    lv |> form("#group-value-form", value: %{content: content}) |> render_submit()
    render(lv)
    lv
  end

  defp schedule!(profile, group, content, minutes \\ 60) do
    {:ok, scheduled} =
      ScheduledValues.schedule(
        profile,
        group,
        %{"content" => content},
        [],
        DateTime.add(DateTime.utc_now(:second), minutes, :minute)
      )

    scheduled
  end

  defp values(group), do: Social.list_group_values(group)

  describe "picking the time" do
    test "opens from the + menu and from the send button", ctx do
      lv = chat(ctx.author_account, ctx.group)

      assert has_element?(lv, "#group-value-submit[data-can-schedule=true]")
      refute has_element?(lv, "#schedule-dialog")
      lv |> element("#group-value-schedule") |> render_click()

      assert has_element?(lv, "#schedule-dialog #schedule-form")
      assert has_element?(lv, "#schedule-dialog", @zone)
      lv |> element("#schedule-close") |> render_click()
      refute has_element?(lv, "#schedule-dialog")

      # What the hook of a held send button pushes.
      render_hook(lv, "schedule_open", %{})
      assert has_element?(lv, "#schedule-dialog")
    end

    test "a preset fills the time in", ctx do
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#group-value-schedule") |> render_click()
      lv |> element("#schedule-preset-tomorrow") |> render_click()

      tomorrow = Date.utc_today() |> Date.add(1)
      near = [tomorrow, Date.add(tomorrow, 1)]
      times = for date <- near, do: "#{date}T09:00"

      assert Enum.any?(times, &has_element?(lv, "#schedule_send_local[value^='#{&1}']"))
      assert has_element?(lv, "#schedule-preset-tomorrow[aria-pressed=true]")
    end

    test "takes only a time still to come", ctx do
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#group-value-schedule") |> render_click()

      for wrong <- [local(-5), local(60 * 24 * 400), ""] do
        lv |> form("#schedule-form", schedule: %{send_local: wrong}) |> render_submit()
        assert has_element?(lv, "#schedule-form .text-error")
        refute has_element?(lv, "#group-value-schedule-bar")
      end
    end

    test "has the composer send what is written, or hold the time", ctx do
      lv = chat(ctx.author_account, ctx.group)
      pick_time(lv)

      assert_push_event(lv, "value_composer_submit", %{})
      refute has_element?(lv, "#schedule-dialog")
      assert has_element?(lv, "#group-value-schedule-bar")
      assert has_element?(lv, "#group-value-submit .hero-clock")

      lv |> element("#group-value-schedule-cancel") |> render_click()
      refute has_element?(lv, "#group-value-schedule-bar")
      assert has_element?(lv, "#group-value-submit .hero-paper-airplane")

      write(lv, "at once")
      assert [%Value{content: "at once"}] = values(ctx.group)
    end

    test "reads the time in the zone of the browser", ctx do
      lv = chat(ctx.author_account, ctx.group)
      local = local(90)
      lv |> pick_time(local) |> write("later")

      assert [%ScheduledValue{send_at: send_at}] = ScheduledValues.list(ctx.author, ctx.group)
      shown = DateTime.shift_zone!(send_at, @zone)
      assert Calendar.strftime(shown, "%Y-%m-%dT%H:%M") == local
    end
  end

  describe "scheduling" do
    test "keeps the message out of the chat and shows the row above the composer", ctx do
      lv = chat(ctx.author_account, ctx.group)
      refute has_element?(lv, "#group-scheduled-bar")
      lv |> pick_time() |> write("later")

      assert_push_event(lv, "value_composer_reset", %{})
      assert values(ctx.group) == []
      refute has_element?(lv, "#group-values-list", "later")
      refute has_element?(lv, "#group-value-schedule-bar")
      assert has_element?(lv, "#group-scheduled-bar")
      assert has_element?(lv, "#flash-info")

      # The next one goes at once again.
      write(lv, "now")
      assert [%Value{content: "now"}] = values(ctx.group)
    end

    test "takes the reply and the files along", ctx do
      {:ok, question} = Social.create_value(ctx.reader, ctx.group, %{"content" => "question"})
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#value-reply-#{question.id}") |> render_click()
      pick_time(lv)

      upload =
        file_input(lv, "#group-value-form", :attachments, [
          %{name: "notes.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(upload, "notes.txt")
      write(lv, "")

      assert [%ScheduledValue{} = scheduled] = ScheduledValues.list(ctx.author, ctx.group)
      assert scheduled.parent_id == question.id

      assert [%{filename: "notes.txt", byte_size: 5} = file] =
               ScheduledValue.attachments(scheduled)

      assert {:ok, 5} = Storage.stat(file.storage_key)
      refute has_element?(lv, "#group-value-reply-preview")
      refute has_element?(lv, "#group-value-attachments")

      lv |> element("#group-scheduled-bar") |> render_click()
      assert has_element?(lv, "#scheduled-#{scheduled.id}", "notes.txt")
      assert has_element?(lv, "#scheduled-#{scheduled.id}", "question")
    end

    test "a time that passed meanwhile keeps the message and its files", ctx do
      lv = chat(ctx.author_account, ctx.group)
      pick_time(lv)
      past = DateTime.add(DateTime.utc_now(:second), -1, :minute)

      :sys.replace_state(lv.pid, fn state ->
        socket = Phoenix.Component.assign(state.socket, :schedule_at, past)
        %{state | socket: socket}
      end)

      upload =
        file_input(lv, "#group-value-form", :attachments, [
          %{name: "notes.txt", content: "hello", type: "text/plain"}
        ])

      render_upload(upload, "notes.txt")
      write(lv, "late")

      assert has_element?(lv, "#flash-error")
      assert has_element?(lv, "#group-value-attachments", "notes.txt")
      assert ScheduledValues.list(ctx.author, ctx.group) == []
      assert values(ctx.group) == []
    end

    test "only text or a file can be scheduled", ctx do
      lv = chat(ctx.author_account, ctx.group)
      lv |> pick_time() |> write("")

      assert ScheduledValues.list(ctx.author, ctx.group) == []
      assert has_element?(lv, "#group-value-schedule-bar")
    end
  end

  describe "the list" do
    test "changes the text and the time", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "first")
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#group-scheduled-bar") |> render_click()
      assert has_element?(lv, "#scheduled-#{scheduled.id}", "first")

      lv |> element("#scheduled-edit-#{scheduled.id}") |> render_click()

      lv
      |> form("#scheduled-edit-form", scheduled: %{content: "second", send_local: local(-1)})
      |> render_submit()

      assert has_element?(lv, "#scheduled-edit-form .text-error")

      lv
      |> form("#scheduled-edit-form", scheduled: %{content: "second", send_local: local(300)})
      |> render_submit()

      render(lv)
      refute has_element?(lv, "#scheduled-edit-form")
      assert has_element?(lv, "#scheduled-#{scheduled.id}", "second")
      assert Repo.get!(ScheduledValue, scheduled.id).content == "second"
    end

    test "sends one now", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "now then")
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#group-scheduled-bar") |> render_click()
      lv |> element("#scheduled-send-#{scheduled.id}") |> render_click()
      render(lv)

      assert [%Value{content: "now then"}] = values(ctx.group)
      assert has_element?(lv, "#group-values-list", "now then")
      refute has_element?(lv, "#scheduled-dialog")
      refute has_element?(lv, "#group-scheduled-bar")
      assert_push_event(lv, "scroll_values_to_latest", %{force: true})
    end

    test "deletes one", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "no more")
      kept = schedule!(ctx.author, ctx.group, "kept", 90)
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#group-scheduled-bar") |> render_click()
      lv |> element("#scheduled-delete-#{scheduled.id}") |> render_click()
      render(lv)

      refute has_element?(lv, "#scheduled-#{scheduled.id}")
      assert has_element?(lv, "#scheduled-#{kept.id}")
      assert [%ScheduledValue{content: "kept"}] = ScheduledValues.list(ctx.author, ctx.group)
    end

    test "says why one was not sent, also without the right to write", ctx do
      scheduled = schedule!(ctx.reader, ctx.group, "x")

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.author,
          ctx.group,
          "everyone",
          :post_values,
          :neutral
        )

      ScheduledValues.run_due(scheduled.send_at)
      lv = chat(ctx.reader_account, ctx.group)

      assert has_element?(lv, "#group-value-composer-disabled")
      lv |> element("#group-scheduled-bar") |> render_click()
      assert has_element?(lv, "#scheduled-failure-#{scheduled.id}")

      lv |> element("#scheduled-send-#{scheduled.id}") |> render_click()
      assert has_element?(lv, "#scheduled-error")
      assert values(ctx.group) == []
    end

    test "another page of the profile hears of every change", ctx do
      first = chat(ctx.author_account, ctx.group)
      second = chat(ctx.author_account, ctx.group)
      first |> pick_time() |> write("later")

      render(second)
      assert has_element?(second, "#group-scheduled-bar")

      [scheduled] = ScheduledValues.list(ctx.author, ctx.group)
      second |> element("#group-scheduled-bar") |> render_click()
      second |> element("#scheduled-edit-#{scheduled.id}") |> render_click()

      # It goes out while its form is open on the other page.
      ScheduledValues.run_due(scheduled.send_at)
      render(second)
      refute has_element?(second, "#scheduled-dialog")
      refute has_element?(second, "#group-scheduled-bar")
      assert has_element?(second, "#group-values-list", "later")
    end

    test "shows nothing of it to anyone else", ctx do
      schedule!(ctx.author, ctx.group, "secret")
      lv = chat(ctx.reader_account, ctx.group)

      refute has_element?(lv, "#group-scheduled-bar")
      render_hook(lv, "schedule_list_open", %{})
      refute has_element?(lv, "#scheduled-dialog")
    end

    test "every account with a shared profile sees it", ctx do
      {second_account, own_profile} = account_with_profile!("sc-second")
      Repo.insert!(%AccountProfile{account_id: second_account.id, profile_id: ctx.author.id})

      Repo.update_all(from(p in Social.Profile, where: p.id == ^ctx.author.id),
        set: [sharing: :shared]
      )

      schedule!(ctx.author, ctx.group, "ours")
      {:ok, _account} = Accounts.set_current_profile(second_account, ctx.author)
      lv = chat(second_account, ctx.group)
      assert has_element?(lv, "#group-scheduled-bar")

      refute own_profile.id == ctx.author.id
    end
  end

  describe "a message that goes out by itself" do
    test "does not move the feed of its author", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "by itself")
      lv = chat(ctx.author_account, ctx.group)
      ScheduledValues.run_due(scheduled.send_at)
      render(lv)

      assert has_element?(lv, "#group-values-list", "by itself")
      assert_push_event(lv, "scroll_values_to_latest", %{force: false})
      refute_push_event(lv, "scroll_values_to_latest", %{force: true}, 0)

      # What the author writes themselves still does.
      write(lv, "by hand")
      assert_push_event(lv, "scroll_values_to_latest", %{force: true})
    end
  end

  describe "who may" do
    test "a member without the right to post has neither the button nor the dialog", ctx do
      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.author,
          ctx.group,
          "everyone",
          :post_values,
          :neutral
        )

      lv = chat(ctx.reader_account, ctx.group)
      refute has_element?(lv, "#group-value-schedule")
      render_hook(lv, "schedule_open", %{})
      refute has_element?(lv, "#schedule-dialog")
    end

    test "someone outside writes in an open chat, but does not schedule", ctx do
      {outsider_account, _outsider} = account_with_profile!("sc-outsider")

      {:ok, group} =
        Social.update_group(ctx.author, ctx.group, %{
          "is_public" => true,
          "has_public_chat" => true
        })

      lv = chat(outsider_account, group)
      assert has_element?(lv, "#group-value-form")
      refute has_element?(lv, "#group-value-add")
      assert has_element?(lv, "#group-value-submit[data-can-schedule=false]")
      render_hook(lv, "schedule_open", %{})
      refute has_element?(lv, "#schedule-dialog")
    end

    test "a preview shows nothing of it and schedules nothing", ctx do
      schedule!(ctx.author, ctx.group, "mine")
      lv = chat(ctx.author_account, ctx.group, %{"as" => "everyone"})

      assert has_element?(lv, "#access-preview-banner")
      refute has_element?(lv, "#group-scheduled-bar")
      render_hook(lv, "schedule_open", %{})
      refute has_element?(lv, "#schedule-dialog")
    end

    test "a message being edited has no time to pick", ctx do
      {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "sent"})
      lv = chat(ctx.author_account, ctx.group)
      lv |> element("#value-edit-#{value.id}") |> render_click()
      render_hook(lv, "schedule_open", %{})

      refute has_element?(lv, "#schedule-dialog")
    end

    test "a direct conversation takes them too", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reader)
      lv = chat(ctx.author_account, direct)
      lv |> pick_time() |> write("later")

      assert [%ScheduledValue{content: "later"}] = ScheduledValues.list(ctx.author, direct)
    end
  end

  describe "presets/2 and when_text/3" do
    test "offers what is still ahead in the viewer's zone" do
      names = fn now -> for {name, _label, _at} <- Scheduling.presets(@zone, now), do: name end

      # Thursday at noon, Thursday late, and Sunday, when tomorrow is Monday.
      assert names.(~U[2026-11-26 11:00:00Z]) == ~w(hour evening tomorrow monday)
      assert names.(~U[2026-11-26 20:30:00Z]) == ~w(hour tomorrow monday)
      assert names.(~U[2026-11-29 11:00:00Z]) == ~w(hour evening tomorrow)

      assert [
               {"hour", _, "2026-11-27T00:30"},
               {"tomorrow", _, "2026-11-27T09:00"},
               {"monday", _, "2026-11-30T09:00"}
             ] = Scheduling.presets(@zone, ~U[2026-11-26 22:30:00Z])
    end

    test "names the day as the viewer sees it" do
      now = ~U[2026-11-26 22:30:00Z]

      assert Scheduling.when_text(~U[2026-11-26 22:45:00Z], @zone, now) =~ "23:45"
      assert Scheduling.when_text(~U[2026-11-27 08:00:00Z], @zone, now) =~ "09:00"
      assert Scheduling.when_text(~U[2026-12-24 08:00:00Z], @zone, now) =~ "24"
    end
  end
end
