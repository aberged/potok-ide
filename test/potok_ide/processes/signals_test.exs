defmodule PotokIde.Processes.SignalsTest do
  @moduledoc """
  A process drawn in Potok sends a signal in its group: the runs waiting for
  it there just then wake with what it carries, the processes that start on
  it start, and nothing is kept for later.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("sig#{unique()}")
    {member_account, member} = account_with_profile!("sig#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)
    {:ok, _config} = AppData.save_config(owner, group, nil, %{"rules" => %{"molbe" => %{}}}, 0)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: group
    }
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp chain(steps, extra_flows \\ []) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        steps ++ [%{"id" => "kraj", "type" => "endEvent"}]

    ids = Enum.map(nodes, & &1["id"])

    %{
      "nodes" => nodes,
      "flows" =>
        (ids
         |> Enum.chunk_every(2, 1, :discard)
         |> Enum.map(fn [a, b] -> %{"from" => a, "to" => b} end)) ++ extra_flows
    }
  end

  defp send_step(name, fields \\ []),
    do: %{
      "id" => "posalji",
      "type" => "serviceTask",
      "action" => "signal",
      "name" => name,
      "fields" => fields
    }

  defp receive_step(signal, extra \\ %{}),
    do: Map.merge(%{"id" => "prijem", "type" => "receiveTask", "signal" => signal}, extra)

  defp drawn!(ctx, attrs) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, Map.merge(%{"trigger" => "manual"}, attrs))

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp run!(ctx, row, title \\ "Subota") do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => title})
    Engine.run(instance.id)
  end

  defp reload(%ValueProcess{id: id}), do: Repo.get!(ValueProcess, id)

  defp runs_of(%{id: id}),
    do: Repo.all(from(i in ValueProcess, where: i.app_process_id == ^id, order_by: i.id))

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  defp settle!(passes \\ 10) do
    if passes > 0 and Engine.run_due() > 0, do: settle!(passes - 1)
  end

  test "wakes the runs waiting for it, with what it carries, and only those", ctx do
    waiter =
      drawn!(ctx, %{
        "name" => "Pakovanje",
        "graph" =>
          chain([
            receive_step("subota"),
            message("javi", "{{title}}: {{prijem.mesto}} ({{prijem.from}})")
          ])
      })

    other = drawn!(ctx, %{"name" => "Drugo", "graph" => chain([receive_step("nedelja")])})

    sender =
      drawn!(ctx, %{
        "name" => "Dan preuzimanja",
        "graph" => chain([send_step("subota", [%{"name" => "mesto", "value" => "u dvorištu"}])])
      })

    a = run!(ctx, waiter, "Milica")
    b = run!(ctx, waiter, "Jovan")
    elsewhere = run!(ctx, other)
    assert %ValueProcess{status: :waiting, element: "prijem", wake_at: nil} = a

    assert %ValueProcess{status: :done} = run!(ctx, sender)

    assert %{"mesto" => "u dvorištu", "from" => "Dan preuzimanja", "signal" => "subota"} =
             reload(a).results["prijem"]

    settle!()

    assert %ValueProcess{status: :done, triggered_by_id: nil} = reload(a)
    assert %ValueProcess{status: :done} = reload(b)
    assert %ValueProcess{status: :waiting} = reload(elsewhere)

    assert Enum.sort(chat(ctx.group)) == [
             "Jovan: u dvorištu (Dan preuzimanja)",
             "Milica: u dvorištu (Dan preuzimanja)"
           ]
  end

  test "is not kept for a run that comes to wait later", ctx do
    sender = drawn!(ctx, %{"name" => "Zvono", "graph" => chain([send_step("subota")])})
    waiter = drawn!(ctx, %{"name" => "Čeka", "graph" => chain([receive_step("subota")])})

    run!(ctx, sender)
    assert %ValueProcess{status: :waiting} = run!(ctx, waiter)
    settle!()
    assert [%ValueProcess{status: :waiting}] = runs_of(waiter)
  end

  test "reaches a run on the same subject only, when it waits for that", ctx do
    waiter =
      drawn!(ctx, %{
        "trigger" => "value",
        "alt_id" => nil,
        "collection" => "molbe",
        "name" => "Čeka uplatu",
        "graph" => chain([receive_step("placeno", %{"same_subject" => true})])
      })

    sender = drawn!(ctx, %{"name" => "Uplata", "graph" => chain([send_step("placeno")])})

    {:ok, first, _} = AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{})

    {:ok, second, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{})

    settle!()

    [a, b] = runs_of(waiter)
    assert a.value_id == first.id and b.value_id == second.id

    # A payment on the first request: a run of another process, on that value.
    {:ok, payment} =
      Repo.transaction(fn ->
        Engine.start_drawn_on(sender, value_id: first.id, depth: 1)
      end)

    Engine.run(payment.id)
    settle!()

    assert %ValueProcess{status: :done} = reload(a)
    assert %ValueProcess{status: :waiting} = reload(b)

    # A signal sent on no subject reaches none of them.
    nowhere = drawn!(ctx, %{"name" => "Svima", "graph" => chain([send_step("placeno")])})
    run!(ctx, nowhere)
    settle!()
    assert %ValueProcess{status: :waiting} = reload(b)
  end

  test "starts the processes that start on it, one level deeper", ctx do
    listener =
      drawn!(ctx, %{
        "trigger" => "signal",
        "trigger_config" => %{"name" => " Subota "},
        "name" => "Podsetnik",
        "graph" => chain([message("javi", "Sutra je {{dan}} ({{from}})")])
      })

    assert listener.trigger_config == %{"name" => "subota"}

    off =
      drawn!(ctx, %{
        "trigger" => "signal",
        "trigger_config" => %{"name" => "subota"},
        "name" => "Ugašen",
        "graph" => chain([message("javi", "Ne bi trebalo")])
      })

    {:ok, _off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, off.id)

    sender =
      drawn!(ctx, %{
        "name" => "Raspored",
        "graph" => chain([send_step("subota", [%{"name" => "dan", "value" => "{{title}}"}])])
      })

    run!(ctx, sender, "subota")
    settle!()

    assert [%ValueProcess{status: :done, depth: 1} = run] = runs_of(listener)
    assert run.data["dan"] == "subota"
    assert runs_of(off) == []
    assert chat(ctx.group) == ["Sutra je subota (Raspored)"]

    assert DrawnProcesses.fields_for(ctx.group, "signal", nil, nil, %{"name" => "subota"}) ==
             ["dan", "from"]
  end

  test "a process starting on the signal it sends stops three processes deep", ctx do
    row =
      drawn!(ctx, %{
        "trigger" => "signal",
        "trigger_config" => %{"name" => "opet"},
        "name" => "Opet",
        "graph" => chain([send_step("opet")])
      })

    run!(ctx, drawn!(ctx, %{"name" => "Prvi", "graph" => chain([send_step("opet")])}))
    settle!()

    assert Enum.map(runs_of(row), &{&1.depth, &1.status}) == [{1, :done}, {2, :done}, {3, :done}]
  end

  test "a wait gives up at its deadline", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        receive_step("subota", %{"deadline" => "PT1H"}),
        message("stiglo", "Stiglo"),
        message("rok", "Nije stiglo"),
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "prijem"},
        %{"from" => "prijem", "to" => "stiglo"},
        %{"from" => "prijem", "to" => "rok", "deadline" => true},
        %{"from" => "stiglo", "to" => "kraj"},
        %{"from" => "rok", "to" => "kraj"}
      ]
    }

    waiter = drawn!(ctx, %{"name" => "Čeka", "graph" => graph})
    run = run!(ctx, waiter)
    assert DateTime.diff(run.wake_at, DateTime.utc_now(), :minute) in 59..60

    run
    |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()

    assert %ValueProcess{status: :done} = Engine.run(run.id)
    assert chat(ctx.group) == ["Nije stiglo"]
  end

  test "an app's own process neither sends nor waits for one", ctx do
    for step <- [send_step("subota"), receive_step("subota")] do
      assert {:error, {:invalid_process, _collection, path, :invalid}} =
               AppData.save_config(
                 ctx.owner,
                 ctx.group,
                 nil,
                 %{
                   "rules" => %{
                     "molbe" => %{"process" => %{"name" => "Prijem", "graph" => chain([step])}}
                   }
                 },
                 AppData.get_config(ctx.group, nil).lock_version
               )

      assert path in ["process.graph.nodes.1.action", "process.graph.nodes.1.type"]
    end
  end
end
