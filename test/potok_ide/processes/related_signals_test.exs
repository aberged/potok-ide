defmodule PotokIde.Processes.RelatedSignalsTest do
  @moduledoc """
  A signal reaches the groups above and below its group where the receiver
  asks for it: a wait or a start that hears those groups (`related`). Never a
  group beside, never a receiver that did not ask, and what it carries is
  taken as the entity the receiver expects, by shape.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupEntities, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppProcess, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_account, owner} = account_with_profile!("rs#{unique()}")

    group = fn parent, name ->
      group =
        group_with_members!(owner, [], %{:parent => parent, "name" => "#{name}-#{unique()}"})

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      Social.get_group!(group.id)
    end

    top = group.(nil, "zadruga")
    middle = group.(top, "selo")
    bottom = group.(middle, "domacinstvo")
    beside = group.(top, "susedno-selo")

    %{owner: owner, top: top, middle: middle, bottom: bottom, beside: beside}
  end

  defp chain(steps) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        steps ++ [%{"id" => "kraj", "type" => "endEvent"}]

    flows =
      nodes
      |> Enum.map(& &1["id"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to} end)

    %{"v" => 2, "nodes" => nodes, "flows" => flows}
  end

  defp send_step(name, fields, extra),
    do:
      Map.merge(
        %{
          "id" => "posalji",
          "type" => "serviceTask",
          "action" => "signal",
          "name" => name,
          "fields" => fields
        },
        extra
      )

  defp receive_step(signal, extra),
    do: Map.merge(%{"id" => "prijem", "type" => "receiveTask", "signal" => signal}, extra)

  defp drawn!(ctx, group, attrs) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, group, Map.merge(%{"trigger" => "manual"}, attrs))

    {:ok, row} = DrawnProcesses.activate(ctx.owner, group, row.id)
    row
  end

  defp run!(ctx, group, row) do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, group, row.id, %{"title" => "Berba"})
    Engine.run(instance.id)
  end

  defp reload(%ValueProcess{id: id}), do: Repo.get!(ValueProcess, id)

  defp runs_of(%AppProcess{id: id}),
    do: Repo.all(from(i in ValueProcess, where: i.app_process_id == ^id, order_by: i.id))

  defp waiter!(ctx, group, extra \\ %{}) do
    row =
      drawn!(ctx, group, %{
        "name" => "Čeka berbu",
        "graph" => chain([receive_step("berba", extra)])
      })

    run!(ctx, group, row)
  end

  defp sender!(ctx, group, fields \\ [%{"name" => "kg", "value" => "12"}], extra \\ %{}) do
    drawn!(ctx, group, %{
      "name" => "Berba počinje",
      "graph" => chain([send_step("berba", fields, extra)])
    })
  end

  test "wakes a waiting run above and below that hears them, and no other", ctx do
    above = waiter!(ctx, ctx.top, %{"related" => true})
    above_deaf = waiter!(ctx, ctx.top)
    below = waiter!(ctx, ctx.bottom, %{"related" => true})
    beside = waiter!(ctx, ctx.beside, %{"related" => true})

    assert %ValueProcess{status: :waiting, related_signal: "berba"} = above
    assert %ValueProcess{related_signal: nil} = above_deaf

    assert %ValueProcess{status: :done} = run!(ctx, ctx.middle, sender!(ctx, ctx.middle))

    assert %{"kg" => "12", "from" => "Berba počinje", "signal" => "berba"} =
             reload(above).results["prijem"]

    assert reload(below).results["prijem"]["kg"] == "12"
    refute reload(above_deaf).results["prijem"]
    refute reload(beside).results["prijem"]
  end

  test "a woken run moves on and stops being found by the signal", ctx do
    above = waiter!(ctx, ctx.top, %{"related" => true})
    run!(ctx, ctx.middle, sender!(ctx, ctx.middle))

    Engine.run(above.id)
    assert %ValueProcess{status: :done, related_signal: nil} = reload(above)
  end

  test "starts a process above that hears the groups below, on no subject and by nobody", ctx do
    hearing =
      drawn!(ctx, ctx.top, %{
        "name" => "Prijem berbe",
        "trigger" => "signal",
        "trigger_config" => %{"name" => "berba", "related" => true},
        "graph" => chain([])
      })

    deaf =
      drawn!(ctx, ctx.bottom, %{
        "name" => "Gluvi",
        "trigger" => "signal",
        "trigger_config" => %{"name" => "berba"},
        "graph" => chain([])
      })

    assert hearing.hears_related
    refute deaf.hears_related

    run!(ctx, ctx.middle, sender!(ctx, ctx.middle))

    assert [
             %ValueProcess{
               depth: 1,
               value_id: nil,
               subject_group_id: nil,
               started_by_id: nil,
               triggered_by_id: nil,
               data: %{"kg" => "12", "signal" => "berba"}
             }
           ] = runs_of(hearing)

    assert runs_of(deaf) == []
  end

  test "takes what a signal carries as the entity a receiver expects, by shape", ctx do
    {:ok, crop} =
      GroupEntities.create(ctx.top, Access.for_profile(ctx.owner, ctx.top), %{
        "name" => "Berba",
        "attributes" => [%{"name" => "kg", "type" => "number", "required" => true}]
      })

    {:ok, other} =
      GroupEntities.create(ctx.top, Access.for_profile(ctx.owner, ctx.top), %{
        "name" => "Mleko",
        "attributes" => [%{"name" => "litara", "type" => "number", "required" => true}]
      })

    {:ok, yield} =
      GroupEntities.create(ctx.middle, Access.for_profile(ctx.owner, ctx.middle), %{
        "name" => "Prinos",
        "attributes" => [%{"name" => "kg", "type" => "number"}]
      })

    fits = waiter!(ctx, ctx.top, %{"related" => true, "entity" => crop.id})
    does_not = waiter!(ctx, ctx.top, %{"related" => true, "entity" => other.id})

    sender =
      sender!(ctx, ctx.middle, [%{"name" => "kg", "value" => "12"}], %{"entity" => yield.id})

    assert %ValueProcess{status: :done} = run!(ctx, ctx.middle, sender)

    # A number is kept as JSON keeps a decimal (`Types.dump/1`).
    assert %{"kg" => "12", "from" => "Berba počinje"} = reload(fits).results["prijem"]
    refute reload(does_not).results["prijem"]
  end

  test "a wait cannot hear the groups around and want the same subject", ctx do
    assert {:error, {:invalid_graph, "nodes.1.related", :related_same_subject}} =
             DrawnProcesses.create(ctx.owner, ctx.top, %{
               "trigger" => "manual",
               "name" => "Ne može",
               "graph" =>
                 chain([receive_step("berba", %{"related" => true, "same_subject" => true})])
             })
  end
end
