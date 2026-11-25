defmodule PotokIde.Social.ScheduledValues.SchedulerTest do
  @moduledoc """
  The scheduler sends a message at its time, without waiting for its next
  regular pass, and what fell due while nothing ran as soon as it starts.
  """

  # It runs as a named process on the shared connection.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{ScheduledValue, ScheduledValues}
  alias PotokIde.Social.ScheduledValues.Scheduler

  setup do
    previous = Application.get_env(:potok_ide, Scheduler)
    Application.put_env(:potok_ide, Scheduler, enabled: true, interval_ms: :timer.hours(1))
    on_exit(fn -> Application.put_env(:potok_ide, Scheduler, previous) end)

    {_account, author} = account_with_profile!("ss-author")
    group = group_with_members!(author, [])
    Social.subscribe_group(group)
    %{author: author, group: group}
  end

  defp schedule!(ctx, content, send_at) do
    {:ok, scheduled} =
      ScheduledValues.schedule(ctx.author, ctx.group, %{"content" => content}, [], send_at)

    scheduled
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(:second), seconds, :second)

  test "a message goes out within its second", ctx do
    start_supervised!(Scheduler)
    scheduled = schedule!(ctx, "on time", in_seconds(2))

    assert_receive {:value_created, _group_id, %{content: "on time"}}, 4_000
    late = DateTime.diff(DateTime.utc_now(), scheduled.send_at, :millisecond)
    assert late in 0..900
  end

  test "an earlier message moves the time up, and a cancelled one is not sent", ctx do
    start_supervised!(Scheduler)
    schedule!(ctx, "tomorrow", in_seconds(86_400))
    cancelled = schedule!(ctx, "cancelled", in_seconds(2))
    schedule!(ctx, "soon", in_seconds(2))
    :ok = ScheduledValues.cancel(ctx.author, ctx.group, cancelled.id)

    assert_receive {:value_created, _group_id, %{content: "soon"}}, 4_000
    refute_received {:value_created, _group_id, _value}
    assert [%ScheduledValue{content: "tomorrow"}] = ScheduledValues.list(ctx.author, ctx.group)
  end

  test "what fell due while nothing ran goes out at start", ctx do
    scheduled = schedule!(ctx, "missed", in_seconds(60))

    Repo.update_all(from(s in ScheduledValue, where: s.id == ^scheduled.id),
      set: [send_at: in_seconds(-120)]
    )

    start_supervised!(Scheduler)
    assert_receive {:value_created, _group_id, %{content: "missed"}}, 2_000
  end

  test "nudging does nothing while it is off" do
    assert Scheduler.nudge() == :ok
  end

  describe "delay_ms/3" do
    @now ~U[2026-11-26 08:00:00.400Z]

    test "waits for the next message, and at most the interval" do
      assert Scheduler.delay_ms(~U[2026-11-26 08:00:10Z], @now, 30_000) == 9_605
      assert Scheduler.delay_ms(~U[2026-11-26 09:00:00Z], @now, 30_000) == 30_000
      assert Scheduler.delay_ms(nil, @now, 30_000) == 30_000
    end

    test "what is due already is looked at again in a second, not at once" do
      assert Scheduler.delay_ms(~U[2026-11-26 08:00:00Z], @now, 30_000) == 1_000
      assert Scheduler.delay_ms(~U[2026-11-26 07:00:00Z], @now, 30_000) == 1_000
    end
  end
end
