defmodule PotokIde.Processes.CallResultsTest do
  @moduledoc """
  A process that others call may hand an entity of its group back (`Vraća`):
  each of its ends fills it in, and the caller reads it under the call's id,
  in its own group or in another.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupEntities, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppProcess, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_account, owner} = account_with_profile!("cr#{unique()}")

    group = fn parent, name ->
      group =
        group_with_members!(owner, [], %{:parent => parent, "name" => "#{name}-#{unique()}"})

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      Social.get_group!(group.id)
    end

    top = group.(nil, "top")
    low = group.(top, "low")

    {:ok, offer} =
      GroupEntities.create(top, Access.for_profile(owner, top), %{
        "name" => "Ponuda",
        "attributes" => [
          %{"name" => "iznos", "type" => "number", "required" => true},
          %{"name" => "rok", "type" => "date"},
          %{"name" => "napomena", "type" => "text"}
        ]
      })

    %{owner: owner, top: top, low: low, offer: offer.id}
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp chain(steps, last, variables \\ []) do
    nodes = [%{"id" => "start", "type" => "startEvent"}] ++ steps ++ [last]

    flows =
      nodes
      |> Enum.map(& &1["id"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to} end)

    %{"v" => 2, "nodes" => nodes, "flows" => flows, "variables" => variables}
  end

  defp end_with(values, label \\ "Prihvaćeno"),
    do: %{"id" => "kraj", "type" => "endEvent", "label" => label, "values" => values}

  defp plain_end, do: %{"id" => "kraj", "type" => "endEvent"}

  # A process others call, handing a Ponuda back, worked out from `kvar`.
  defp draw_callee(ctx, group, values, attrs \\ %{}) do
    DrawnProcesses.create(
      ctx.owner,
      group,
      Map.merge(
        %{
          "trigger" => "process",
          "name" => "Procena",
          "trigger_config" => %{"fields" => ["kvar"]},
          "return_entity_id" => ctx.offer,
          "is_public" => true,
          "graph" => chain([], end_with(values))
        },
        attrs
      )
    )
  end

  defp callee!(ctx, group, values, attrs \\ %{}) do
    {:ok, row} = draw_callee(ctx, group, values, attrs)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, group, row.id)
    row
  end

  defp draw_caller(ctx, group, callee, steps_after, variables \\ []) do
    call = %{
      "id" => "poziv",
      "type" => "callActivity",
      "process" => callee.id,
      "fields" => %{"kvar" => "{{start.title}}"}
    }

    DrawnProcesses.create(ctx.owner, group, %{
      "trigger" => "manual",
      "name" => "Prijava",
      "graph" => chain([call | steps_after], plain_end(), variables)
    })
  end

  defp caller!(ctx, group, callee, steps_after, variables \\ []) do
    {:ok, row} = draw_caller(ctx, group, callee, steps_after, variables)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, group, row.id)
    row
  end

  defp run_through!(ctx, group, caller, callee, title) do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, group, caller.id, %{"title" => title})
    assert %ValueProcess{status: :waiting} = Engine.run(instance.id)

    [child] =
      Repo.all(from(i in ValueProcess, where: i.app_process_id == ^callee.id, order_by: i.id))

    {Engine.run(child.id), Engine.run(instance.id)}
  end

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  @values %{
    "iznos" => "length(start.kvar) * 10",
    "rok" => "add_days(today(), 3)",
    "napomena" => "Za {{start.kvar}}"
  }

  test "a caller of the same group reads what the end handed back, each as its type", ctx do
    callee = callee!(ctx, ctx.top, @values)
    assert %AppProcess{return_entity_id: offer} = callee
    assert offer == ctx.offer
    assert callee.graph["returns"] == ctx.offer

    caller =
      caller!(ctx, ctx.top, callee, [
        message(
          "javi",
          "{{poziv.napomena}}: {{poziv.iznos + 1}} do {{poziv.rok}} ({{poziv.outcome}})"
        )
      ])

    assert Enum.at(caller.graph["nodes"], 1)["returns"] == ctx.offer

    {child, done} = run_through!(ctx, ctx.top, caller, callee, "lift")
    assert %ValueProcess{status: :done} = child

    rok = Date.utc_today() |> Date.add(3) |> Date.to_iso8601()
    assert child.results["kraj"] == %{"iznos" => "40", "rok" => rok, "napomena" => "Za lift"}

    assert %ValueProcess{status: :done} = done
    # A date reads as the group's language writes it.
    assert [said] = chat(ctx.top)
    assert said =~ ~r/^Za lift: 41 do .+2026\. \(Prihvaćeno\)$/
  end

  test "a caller of another group gets it too, which a process handing nothing back never gave",
       ctx do
    callee = callee!(ctx, ctx.top, @values)
    caller = caller!(ctx, ctx.low, callee, [message("javi", "{{poziv.iznos}} {{poziv.outcome}}")])

    {_child, done} = run_through!(ctx, ctx.low, caller, callee, "voda")
    assert %ValueProcess{status: :done} = done
    assert chat(ctx.low) == ["40 Prihvaćeno"]
  end

  test "what comes back fills a variable of that entity whole", ctx do
    callee = callee!(ctx, ctx.top, @values)

    caller =
      caller!(
        ctx,
        ctx.top,
        callee,
        [
          %{
            "id" => "dodeli",
            "type" => "serviceTask",
            "action" => "assign",
            "target" => "ponuda",
            "value" => "poziv"
          },
          message("javi", "{{ponuda.iznos}}")
        ],
        [%{"name" => "ponuda", "type" => "entity", "entity" => ctx.offer}]
      )

    {_child, done} = run_through!(ctx, ctx.top, caller, callee, "gas")
    assert %ValueProcess{status: :done} = done
    assert chat(ctx.top) == ["30"]
  end

  test "every end must fill in what is required, each value of its type", ctx do
    assert {:error, {:invalid_graph, "nodes.1.values.iznos", :required}} =
             draw_callee(ctx, ctx.top, %{"napomena" => "bez iznosa"})

    assert {:error, {:invalid_graph, "nodes.1.values.iznos", {:mismatch, :number, :text}}} =
             draw_callee(ctx, ctx.top, %{"iznos" => "start.kvar"})

    assert {:error, {:invalid_trigger, "returns", :invalid}} =
             draw_callee(ctx, ctx.top, @values, %{"trigger" => "manual"})
  end

  test "a caller reads only what comes back, while one handing nothing back stays open", ctx do
    callee = callee!(ctx, ctx.top, @values)

    assert {:error, {:invalid_graph, "nodes.2.text", {:unknown_attribute, "nema"}}} =
             draw_caller(ctx, ctx.top, callee, [message("javi", "{{poziv.nema}}")])

    {:ok, plain} =
      DrawnProcesses.create(ctx.owner, ctx.top, %{
        "trigger" => "process",
        "name" => "Obično",
        "trigger_config" => %{"fields" => ["kvar"]},
        "graph" => chain([], plain_end())
      })

    assert {:ok, _caller} = draw_caller(ctx, ctx.top, plain, [message("javi", "{{poziv.nema}}")])
  end

  test "a required value that turns out empty fails the run it was called in", ctx do
    callee = callee!(ctx, ctx.top, %{"iznos" => "if(start.kvar == \"x\", empty, 5)"})
    caller = caller!(ctx, ctx.top, callee, [message("javi", "{{poziv.iznos}}")])

    {child, _nothing_to_do} = run_through!(ctx, ctx.top, caller, callee, "x")
    assert %ValueProcess{status: :failed, error: %{"element" => "kraj"}} = child

    # The caller waits on, as for any run it called that failed: an editor
    # may take that one up again.
    assert [%ValueProcess{status: :waiting}] =
             Repo.all(from(i in ValueProcess, where: i.app_process_id == ^caller.id))

    assert chat(ctx.top) == []
  end

  test "a caller is stale once the process it calls hands back something else", ctx do
    callee = callee!(ctx, ctx.top, @values)
    caller = caller!(ctx, ctx.top, callee, [message("javi", "{{poziv.iznos}}")])
    refute DrawnProcesses.stale?(caller, ctx.top)

    {:ok, _callee} =
      DrawnProcesses.update(
        ctx.owner,
        ctx.top,
        callee.id,
        %{
          "name" => callee.name,
          "graph" => chain([], plain_end()),
          "return_entity_id" => nil
        },
        callee.lock_version
      )

    assert DrawnProcesses.stale?(Repo.get!(AppProcess, caller.id), ctx.top)
  end
end
