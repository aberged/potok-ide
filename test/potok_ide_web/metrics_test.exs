defmodule PotokIdeWeb.MetricsTest do
  @moduledoc """
  The metrics the app keeps of itself (`PotokIdeWeb.Telemetry`,
  `PotokIde.Metrics`): served in Prometheus' text format, the lateness of the
  drawn processes, and a dropped push job counted.
  """

  use PotokIde.DataCase, async: true

  import Plug.Test
  import PotokIde.EventsFixtures

  alias PotokIde.Processes.ValueProcess
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.AppData

  defp unique, do: System.unique_integer([:positive])

  defp scrape do
    opts = Peep.Plug.init(peep_worker: PotokIde.Metrics.peep(), on_unmatched_path: :halt)
    conn = Peep.Plug.call(conn(:get, "/metrics"), opts)
    {conn.status, conn.resp_body}
  end

  test "the metrics plug answers with the database's queue time and the VM's memory" do
    Repo.query!("SELECT 1")
    :telemetry.execute([:vm, :memory], %{total: 123_456, processes: 1, binary: 1, ets: 1})

    assert {200, body} = scrape()
    assert body =~ "potok_ide_repo_query_queue_time_bucket"
    assert body =~ "vm_memory_total"
  end

  test "any other path of the metrics port is not found" do
    opts = Peep.Plug.init(peep_worker: PotokIde.Metrics.peep(), on_unmatched_path: :halt)
    assert Peep.Plug.call(conn(:get, "/groups"), opts).status == 404
  end

  describe "the lateness of drawn processes" do
    setup do
      {_owner_account, owner} = account_with_profile!("me#{unique()}")
      {member_account, member} = account_with_profile!("me#{unique()}")

      group =
        group_with_members!(owner, [member], %{
          "uses_api" => true,
          "description" => "<p>app</p>",
          "description_format" => :html,
          "home_page" => :description
        })

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "kraj"}]
      }

      rule = %{"process" => %{"name" => "Prijem", "graph" => graph}}
      {:ok, _config} = AppData.save_config(owner, group, nil, %{"rules" => %{"molbe" => rule}}, 0)

      %{group: Social.get_group!(group.id), member: member, member_account: member_account}
    end

    test "is 0 with nothing due and grows with the longest due instance", ctx do
      assert PotokIde.Metrics.process_lag() == 0

      {:ok, value, _rule} =
        AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{"a" => 1})

      ValueProcess
      |> Repo.get_by!(value_id: value.id)
      |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -120, :second))
      |> Repo.update!()

      assert PotokIde.Metrics.process_lag() in 119..125
      assert PotokIde.Metrics.dispatch_process_lag() in 119..125
    end
  end

  test "a full job queue counts a dropped job" do
    ref = make_ref()
    test_pid = self()
    handler = "dropped-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:potok_ide, :job_queue, :dropped],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, sup} = start_supervised({Task.Supervisor, name: :"metrics_test_sup_#{unique()}"})
    name = :"metrics_test_queue_#{unique()}"

    start_supervised!(
      {PotokIde.JobQueue, name: name, task_supervisor: sup, max_running: 1, max_queued: 0}
    )

    gate = make_ref()
    PotokIde.JobQueue.run(name, fn -> receive do: (^gate -> :ok) end)
    PotokIde.JobQueue.run(name, fn -> :ok end)

    assert_receive {^ref, %{count: 1}, %{queue: queue}}, 2_000
    assert queue == inspect(name)
  end
end
