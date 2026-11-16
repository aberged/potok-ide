defmodule PotokIde.Processes.CallsTest do
  @moduledoc """
  A process drawn in Potok calls another: the run it starts gets the fields
  the call hands over, the caller waits for it and goes on by what it ended
  with, a deadline gives up on it, cancelling goes down the chain and a
  loop stops three processes deep.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("call#{unique()}")
    {_member_account, member} = account_with_profile!("call#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, _role} = Social.assign_group_member_role(owner, group, owner.id, savet.key)
    group = Social.get_group!(group.id)

    %{owner: owner, member: member, group: group, savet: savet.key}
  end

  # The repairman: the council agrees on a time, or there is none.
  defp majstor(savet) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "termin",
          "type" => "userTask",
          "role" => savet,
          "outcomes" => ["Dogovoreno", "Nema termina"]
        },
        %{"id" => "ok", "type" => "endEvent", "label" => "Dogovoreno"},
        %{"id" => "ne", "type" => "endEvent", "label" => "Nema termina"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "termin"},
        %{"from" => "termin", "to" => "ok", "outcome" => "Dogovoreno"},
        %{"from" => "termin", "to" => "ne", "outcome" => "Nema termina"}
      ]
    }
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp call(process_id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "majstor",
        "type" => "callActivity",
        "process" => process_id,
        "fields" => %{"kvar" => "{{title}}"}
      },
      extra
    )
  end

  # A fault comes in by hand, the repairman is called, and the chat hears
  # what came of it.
  defp prijava(call) do
    deadline? = Map.has_key?(call, "deadline")

    %{
      "nodes" =>
        [
          %{"id" => "start", "type" => "startEvent"},
          call,
          %{"id" => "ishod", "type" => "exclusiveGateway"},
          message("dolazi", "Majstor dolazi za {{majstor.kvar}} ({{majstor.termin.comment}})"),
          message("nema", "Nema majstora za {{title}}"),
          %{"id" => "kraj", "type" => "endEvent"}
        ] ++ if(deadline?, do: [message("rok", "Majstor se nije javio")], else: []),
      "flows" =>
        [
          %{"from" => "start", "to" => "majstor"},
          %{"from" => "majstor", "to" => "ishod"},
          %{
            "from" => "ishod",
            "to" => "dolazi",
            "condition" => %{"field" => "majstor.outcome", "op" => "=", "value" => "Dogovoreno"}
          },
          %{"from" => "ishod", "to" => "nema", "default" => true},
          %{"from" => "dolazi", "to" => "kraj"},
          %{"from" => "nema", "to" => "kraj"}
        ] ++
          if(deadline?,
            do: [
              %{"from" => "majstor", "to" => "rok", "deadline" => true},
              %{"from" => "rok", "to" => "kraj"}
            ],
            else: []
          )
    }
  end

  defp callee!(ctx, attrs \\ %{}) do
    {:ok, row} =
      DrawnProcesses.create(
        ctx.owner,
        ctx.group,
        Map.merge(
          %{
            "trigger" => "process",
            "trigger_config" => %{"fields" => "kvar"},
            "name" => "Majstor",
            "graph" => majstor(ctx.savet)
          },
          attrs
        )
      )

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp caller!(ctx, graph) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => "Prijava",
        "graph" => graph
      })

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp start!(ctx, row, title \\ "lift") do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => title})
    Engine.run(instance.id)
  end

  defp runs_of(%{id: id}),
    do: Repo.all(from(i in ValueProcess, where: i.app_process_id == ^id, order_by: i.id))

  defp reload(%ValueProcess{id: id}), do: Repo.get!(ValueProcess, id)

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  defp due_now!(instance) do
    instance
    |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()
  end

  # Takes forward whatever runs, until nothing does.
  defp settle!(passes \\ 10) do
    if passes > 0 and Engine.run_due() > 0, do: settle!(passes - 1)
  end

  describe "a call that waits" do
    test "starts the process with the fields it takes, and goes on by what it ended with",
         ctx do
      callee = callee!(ctx)
      caller = start!(ctx, caller!(ctx, prijava(call(callee.id))))

      assert %ValueProcess{status: :waiting, element: "majstor", wake_at: nil} = caller
      [child] = runs_of(callee)
      assert caller.awaiting_id == child.id
      assert child.depth == 1
      assert child.data == %{"kvar" => "lift", "from" => "Prijava"}
      assert child.started_by_id == ctx.owner.id

      Engine.run(child.id)

      assert {:ok, _moved} =
               Engine.complete_task(ctx.owner, child.id, "termin", "Dogovoreno", "utorak")

      assert %ValueProcess{status: :done} = Engine.run(child.id)

      woken = reload(caller)
      assert woken.awaiting_id == nil
      assert %{"outcome" => "Dogovoreno", "kvar" => "lift"} = woken.results["majstor"]
      assert woken.results["majstor"]["termin"]["by"] == ctx.owner.username

      assert %ValueProcess{status: :done} = Engine.run(caller.id)
      assert chat(ctx.group) == ["Majstor dolazi za lift (utorak)"]
    end

    test "goes on by the other branch when the process ended elsewhere", ctx do
      callee = callee!(ctx)
      caller = start!(ctx, caller!(ctx, prijava(call(callee.id))))
      [child] = runs_of(callee)
      Engine.run(child.id)
      {:ok, _moved} = Engine.complete_task(ctx.owner, child.id, "termin", "Nema termina")
      Engine.run(child.id)

      assert %ValueProcess{status: :done} = Engine.run(caller.id)
      assert chat(ctx.group) == ["Nema majstora za lift"]
    end

    test "gives up at its deadline and cancels the process it called", ctx do
      callee = callee!(ctx)
      caller = start!(ctx, caller!(ctx, prijava(call(callee.id, %{"deadline" => "PT1H"}))))
      assert DateTime.diff(caller.wake_at, DateTime.utc_now(), :minute) in 59..60

      [child] = runs_of(callee)
      Engine.run(child.id)
      due_now!(caller)

      assert %ValueProcess{status: :done, triggered_by_id: nil} = Engine.run(caller.id)
      assert chat(ctx.group) == ["Majstor se nije javio"]
      assert %ValueProcess{status: :cancelled} = reload(child)

      assert {:error, :not_waiting} =
               Engine.complete_task(ctx.owner, child.id, "termin", "Dogovoreno")
    end
  end

  describe "a call that does not wait" do
    test "starts the process and goes on at once", ctx do
      callee = callee!(ctx)
      graph = prijava(call(callee.id, %{"wait" => false}))
      caller = start!(ctx, caller!(ctx, graph))

      assert %ValueProcess{status: :done, awaiting_id: nil} = caller
      assert chat(ctx.group) == ["Nema majstora za lift"]

      [child] = runs_of(callee)
      Engine.run(child.id)
      {:ok, _moved} = Engine.complete_task(ctx.owner, child.id, "termin", "Dogovoreno")
      assert %ValueProcess{status: :done} = Engine.run(child.id)
      assert %ValueProcess{status: :done, results: %{}} = reload(caller)
    end
  end

  describe "cancelling" do
    test "the process called fails the caller, which calls anew when taken up again", ctx do
      callee = callee!(ctx)
      caller = start!(ctx, caller!(ctx, prijava(call(callee.id))))
      [child] = runs_of(callee)

      child |> Ecto.Changeset.change(status: :failed) |> Repo.update!()
      assert %ValueProcess{status: :waiting} = reload(caller)

      assert {:ok, %ValueProcess{status: :cancelled}} = Engine.cancel(child.id)

      assert %ValueProcess{status: :failed, error: %{"reason" => "call_cancelled"}} =
               reload(caller)

      {:ok, _retried} = Engine.retry(caller.id)
      again = Engine.run(caller.id)

      assert %ValueProcess{status: :waiting} = again
      assert [_old, new] = runs_of(callee)
      assert again.awaiting_id == new.id
    end

    test "the caller cancels the process it waits for", ctx do
      callee = callee!(ctx)
      caller = start!(ctx, caller!(ctx, prijava(call(callee.id))))
      [child] = runs_of(callee)

      assert {:ok, %ValueProcess{status: :cancelled}} = Engine.cancel(caller.id)
      assert %ValueProcess{status: :cancelled} = reload(child)
    end

    test "switching the called process off fails who waits, and the calls after", ctx do
      callee = callee!(ctx)
      row = caller!(ctx, prijava(call(callee.id)))
      caller = start!(ctx, row)

      {:ok, _off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, callee.id)

      assert %ValueProcess{status: :failed, error: %{"reason" => "call_cancelled"}} =
               reload(caller)

      assert %ValueProcess{status: :failed, error: %{"reason" => "call_inactive"}} =
               start!(ctx, row, "voda")
    end
  end

  describe "limits" do
    test "a process calling itself stops three processes deep", ctx do
      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "process",
          "name" => "Opet",
          "graph" => majstor(ctx.savet)
        })

      opet = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "opet", "type" => "callActivity", "process" => row.id},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "opet"}, %{"from" => "opet", "to" => "kraj"}]
      }

      {:ok, row} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          row.id,
          %{"name" => "Opet", "graph" => opet},
          row.lock_version
        )

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

      start!(ctx, caller!(ctx, put_in(opet, ["nodes", Access.at(1), "process"], row.id)))
      settle!()

      runs = runs_of(row)
      assert Enum.map(runs, & &1.depth) == [1, 2, 3]
      assert %ValueProcess{status: :failed, error: %{"reason" => "too_deep"}} = List.last(runs)
    end

    test "a call reaches only the group's processes that take calls, with their fields",
         ctx do
      callee = callee!(ctx)

      {:ok, manual} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Ručni",
          "graph" => majstor(ctx.savet)
        })

      draw = fn graph ->
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Prijava",
          "graph" => graph
        })
      end

      assert {:error, {:invalid_graph, "nodes.1.process", :unknown_process}} =
               draw.(prijava(call(manual.id)))

      assert {:error, {:invalid_graph, "nodes.1.fields.boja", :unknown_field}} =
               draw.(prijava(call(callee.id, %{"fields" => %{"boja" => "crvena"}})))

      assert {:error, {:invalid_graph, "nodes.1.deadline", :invalid}} =
               draw.(prijava(call(callee.id, %{"wait" => false, "deadline" => "PT1H"})))

      # A graph changed behind Potok's back fails where it calls.
      row = caller!(ctx, prijava(call(callee.id)))

      row
      |> Ecto.Changeset.change(graph: prijava(call(manual.id)))
      |> Repo.update!()

      assert %ValueProcess{status: :failed, error: %{"reason" => "call_unknown"}} =
               start!(ctx, row)
    end

    test "a process another one calls is not deleted", ctx do
      callee = callee!(ctx)
      caller = caller!(ctx, prijava(call(callee.id)))

      assert {:error, {:in_use, "Prijava"}} =
               DrawnProcesses.delete(ctx.owner, ctx.group, callee.id)

      {:ok, _gone} = DrawnProcesses.delete(ctx.owner, ctx.group, caller.id)
      assert {:ok, _gone} = DrawnProcesses.delete(ctx.owner, ctx.group, callee.id)
    end

    test "an app's own process may not call", ctx do
      callee = callee!(ctx)

      assert {:error, {:invalid_process, _collection, "process.graph.nodes.1.type", :invalid}} =
               AppData.save_config(
                 ctx.owner,
                 ctx.group,
                 nil,
                 %{
                   "rules" => %{
                     "molbe" => %{
                       "process" => %{"name" => "Prijem", "graph" => prijava(call(callee.id))}
                     }
                   }
                 },
                 0
               )
    end
  end

  describe "results" do
    test "a decision is read later, and never hides a field the run was given", ctx do
      task = fn id ->
        %{"id" => id, "type" => "userTask", "role" => ctx.savet, "outcomes" => ["Da"]}
      end

      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          task.("odluka"),
          task.("title"),
          message("javi", "{{title}}: {{odluka.outcome}} ({{odluka.by}}) {{title.outcome}}"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "odluka"},
          %{"from" => "odluka", "to" => "title", "outcome" => "Da"},
          %{"from" => "title", "to" => "javi", "outcome" => "Da"},
          %{"from" => "javi", "to" => "kraj"}
        ]
      }

      instance = start!(ctx, caller!(ctx, graph))
      {:ok, _moved} = Engine.complete_task(ctx.owner, instance.id, "odluka", "Da")
      Engine.run(instance.id)
      {:ok, _moved} = Engine.complete_task(ctx.owner, instance.id, "title", "Da")
      Engine.run(instance.id)

      assert chat(ctx.group) == ["lift: Da (#{ctx.owner.username})"]
    end
  end
end
