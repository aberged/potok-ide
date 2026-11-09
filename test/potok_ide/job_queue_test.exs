defmodule PotokIde.JobQueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PotokIde.JobQueue

  setup do
    supervisor = start_supervised!(Task.Supervisor, id: :job_queue_test_tasks)
    name = :"job_queue_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {JobQueue, name: name, task_supervisor: supervisor, max_running: 2, max_queued: 2}
    )

    %{queue: name}
  end

  # A job that says it started and waits until told to finish.
  defp job(test, id) do
    fn ->
      send(test, {:started, id, self()})

      receive do
        :finish -> send(test, {:finished, id})
      end
    end
  end

  test "runs at most max_running jobs at once and starts the next as one ends", %{queue: queue} do
    for id <- 1..4, do: JobQueue.run(queue, job(self(), id))

    assert_receive {:started, 1, first}
    assert_receive {:started, 2, _second}
    refute_receive {:started, _id, _pid}, 50
    assert %{running: 2, queued: 2} = JobQueue.stats(queue)

    send(first, :finish)
    assert_receive {:finished, 1}
    assert_receive {:started, 3, _third}
    refute_receive {:started, 4, _fourth}, 50
  end

  test "drops a job once the line is full, with a warning", %{queue: queue} do
    for id <- 1..4, do: JobQueue.run(queue, job(self(), id))
    assert_receive {:started, 2, _pid}

    log =
      capture_log(fn ->
        JobQueue.run(queue, job(self(), 5))
        assert %{running: 2, queued: 2} = JobQueue.stats(queue)
      end)

    assert log =~ "dropped one"
  end

  test "a job that crashes frees its place", %{queue: queue} do
    capture_log(fn ->
      JobQueue.run(queue, fn -> raise "boom" end)
      JobQueue.run(queue, fn -> raise "boom" end)
      JobQueue.run(queue, job(self(), :after_crashes))
      assert_receive {:started, :after_crashes, _pid}, 1_000
    end)
  end
end
