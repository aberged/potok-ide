defmodule PotokIde.Processes.RunEventsTest do
  @moduledoc """
  The trace of a run: each step it passed, where it waited and who answered,
  how it ended, whichever way it moved; and who may read it.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Processes
  alias PotokIde.Processes.{Engine, RunEvent, RunEvents, ValueProcess}
  alias PotokIde.{Repo, Social}
  alias PotokIde.Social.{Access, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_, owner} = account_with_profile!("re#{unique()}")
    {_, member} = account_with_profile!("re#{unique()}")
    {_, other} = account_with_profile!("re#{unique()}")
    {_, outsider} = account_with_profile!("re#{unique()}")
    group = group_with_members!(owner, [member, other], %{"is_public" => true})

    %{
      owner: owner,
      member: member,
      other: other,
      outsider: outsider,
      group: Social.get_group!(group.id)
    }
  end

  # A run that waits for a decision of anyone in the group.
  defp graph do
    %{
      "v" => 2,
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "odluka",
          "type" => "userTask",
          "label" => "Savet odlučuje",
          "role" => "everyone",
          "outcomes" => ["odobri", "odbij"]
        },
        %{"id" => "kraj", "type" => "endEvent", "label" => "Gotovo"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "odluka"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odobri"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odbij"}
      ]
    }
  end

  defp process!(ctx) do
    {:ok, process} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "name" => "P",
        "graph" => graph(),
        "trigger" => "manual",
        "trigger_config" => %{"roles" => ["everyone"]}
      })

    {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)
    process
  end

  defp start!(ctx, process) do
    {:ok, run} =
      DrawnProcesses.start(ctx.member, ctx.group, process.id, %{"title" => "T", "text" => "t"})

    Engine.run(run.id)
    run.id
  end

  defp kinds(run_id) do
    Repo.all(
      from(e in RunEvent, where: e.run_id == ^run_id, order_by: e.id, select: {e.kind, e.label})
    )
  end

  defp access(ctx, profile), do: Access.for_profile(profile, ctx.group)

  test "started, waiting, answered and done, with who and what", ctx do
    process = process!(ctx)
    run = start!(ctx, process)

    assert kinds(run) == [
             {"started", nil},
             {"passed", nil},
             {"waits", "Savet odlučuje"}
           ]

    {:ok, _} = Engine.complete_task(ctx.other, run, "odluka", "odobri", "može")
    Engine.run(run)

    assert kinds(run) == [
             {"started", nil},
             {"passed", nil},
             {"waits", "Savet odlučuje"},
             {"answered", "Savet odlučuje"},
             {"done", "Gotovo"}
           ]

    events = RunEvents.events(ctx.group, run, access(ctx, ctx.owner), ctx.owner)
    assert hd(events).actor.id == ctx.member.id
    answered = Enum.find(events, &(&1.kind == "answered"))
    assert {answered.actor.id, answered.outcome} == {ctx.other.id, "odobri"}
    # A comment is the task's, not the trace's.
    refute inspect(answered) =~ "može"
  end

  test "failed, taken up again and cancelled, by whoever did", ctx do
    process = process!(ctx)
    run = start!(ctx, process)

    Repo.update_all(from(i in ValueProcess, where: i.id == ^run),
      set: [status: :failed, error: %{"element" => "odluka", "reason" => "loop"}]
    )

    {:ok, _} = Processes.retry(ctx.group, :any, access(ctx, ctx.owner), run, ctx.owner)
    {:ok, _} = Processes.cancel(ctx.group, :any, access(ctx, ctx.owner), run, ctx.owner)

    events = Repo.all(from(e in RunEvent, where: e.run_id == ^run, order_by: e.id))

    assert [
             %{kind: "failed", outcome: "loop"},
             %{kind: "retried", actor_id: a},
             %{kind: "cancelled", actor_id: b}
           ] = Enum.take(events, -3)

    assert {a, b} == {ctx.owner.id, ctx.owner.id}
  end

  test "runs cancelled in bulk are in it, by the editor who switched the process off", ctx do
    process = process!(ctx)
    runs = for _ <- 1..3, do: start!(ctx, process)
    {:ok, _} = DrawnProcesses.deactivate(ctx.owner, ctx.group, process.id)

    for run <- runs do
      assert %{kind: "cancelled", actor_id: id} =
               Repo.one(
                 from(e in RunEvent, where: e.run_id == ^run, order_by: [desc: e.id], limit: 1)
               )

      assert id == ctx.owner.id
    end
  end

  test "a run cancelled while its step failed stays cancelled", ctx do
    process = process!(ctx)
    run = start!(ctx, process)
    {:ok, _} = Engine.cancel(run, ctx.owner)

    # The step that was under way comes back with its failure.
    Repo.update_all(from(i in ValueProcess, where: i.id == ^run), set: [status: :cancelled])
    Engine.run(run)
    assert Repo.get!(ValueProcess, run).status == :cancelled
  end

  test "a run that goes round keeps a row for each step past the first", ctx do
    process = process!(ctx)
    run = start!(ctx, process)
    before = length(kinds(run))

    Repo.update_all(from(i in ValueProcess, where: i.id == ^run),
      set: [status: :running, element: "a", steps: 150]
    )

    for n <- 1..60, element <- ["b", "a"] do
      Repo.update_all(from(i in ValueProcess, where: i.id == ^run),
        set: [element: element, steps: 200 + n]
      )
    end

    passed =
      Repo.all(
        from(e in RunEvent,
          where: e.run_id == ^run and e.kind == "passed" and e.element in ["a", "b"]
        )
      )

    assert [%{count: 60}, %{count: 60}] = passed
    assert Enum.all?(passed, & &1.last_at)
    assert length(kinds(run)) < before + 6
  end

  test "what steps made of the variables, for those who edit and for a while", ctx do
    process = process!(ctx)
    run = start!(ctx, process)

    Repo.query!(
      ~s|UPDATE value_processes SET status = 'running', element = 'dalje', vars = '{"n": 1}' WHERE id = $1|,
      [run]
    )

    Repo.query!(
      ~s|UPDATE value_processes SET element = 'jos', vars = '{"n": 2, "t": "x"}' WHERE id = $1|,
      [run]
    )

    vars = fn profile ->
      ctx.group
      |> RunEvents.events(run, access(ctx, profile), profile)
      |> List.last()
      |> Map.fetch!(:vars)
    end

    assert vars.(ctx.owner) == %{"n" => [1, 2], "t" => [nil, "x"]}
    assert vars.(ctx.member) == nil

    # Much of it keeps only which they were.
    big = String.duplicate("abcdefgh0123456789", 2_000)

    Repo.query!(
      "UPDATE value_processes SET element = 'kraj2', vars = jsonb_build_object('n', $2::text, 'r', gen_random_uuid()) WHERE id = $1",
      [run, Enum.map_join(1..400, &"#{&1}-#{:erlang.phash2({&1, big})}")]
    )

    assert %{"n" => nil} = vars.(ctx.owner)

    assert RunEvents.forget_vars(DateTime.add(DateTime.utc_now(), 29, :day)) == 0
    assert RunEvents.forget_vars(DateTime.add(DateTime.utc_now(), 31, :day)) > 0
    assert vars.(ctx.owner) == nil
  end

  test "those who edit read every run, members those they had a part in", ctx do
    process = process!(ctx)
    run = start!(ctx, process)

    runs = fn profile ->
      {runs, false} = RunEvents.runs(ctx.group, process.id, access(ctx, profile), profile)
      Enum.map(runs, & &1.id)
    end

    assert runs.(ctx.owner) == [run]
    assert runs.(ctx.member) == [run]
    assert runs.(ctx.other) == []
    assert runs.(ctx.outsider) == []
    assert RunEvents.events(ctx.group, run, access(ctx, ctx.other), ctx.other) == []
    assert RunEvents.events(ctx.group, run, access(ctx, ctx.outsider), ctx.outsider) == []

    {:ok, _} = Engine.complete_task(ctx.other, run, "odluka", "odbij")
    assert runs.(ctx.other) == [run]

    # Another group's address gives nothing.
    elsewhere = group_with_members!(ctx.outsider, [])

    assert RunEvents.events(
             elsewhere,
             run,
             Access.for_profile(ctx.outsider, elsewhere),
             ctx.outsider
           ) == []
  end

  test "runs go on from each other, the newest first", ctx do
    process = process!(ctx)
    size = RunEvents.page_size()
    ids = for _ <- 1..(size + 2), do: Engine.start_drawn_on(process, started_by: ctx.member.id).id
    access = access(ctx, ctx.owner)

    {first, true} = RunEvents.runs(ctx.group, process.id, access, ctx.owner)

    {rest, false} =
      RunEvents.runs(ctx.group, process.id, access, ctx.owner, List.last(first).event_id)

    assert Enum.map(first ++ rest, & &1.id) == Enum.reverse(ids)

    Engine.run(hd(first).id)
    {[newest | _], true} = RunEvents.runs(ctx.group, process.id, access, ctx.owner)
    assert newest.last.kind == "waits"
  end

  test "it outlives its run, and goes with the group", ctx do
    process = process!(ctx)
    run = start!(ctx, process)
    {:ok, _} = DrawnProcesses.delete(ctx.owner, ctx.group, process.id)
    refute Repo.get(ValueProcess, run)
    assert {"started", nil} in kinds(run)

    {:ok, _} = Social.delete_group(ctx.owner, Social.get_group!(ctx.group.id))
    assert kinds(run) == []
  end
end
