defmodule PotokIde.Processes.GroupFieldsTest do
  @moduledoc """
  The fields the processes drawn in a group keep for each other: a step sets
  one or adds to it, every drawn process of the group reads it, and the
  app's editors see and delete them.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupField, GroupFields, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("gf#{unique()}")
    {_member_account, member} = account_with_profile!("gf#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    %{owner: owner, member: member, group: Social.get_group!(group.id)}
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp set(id, field, op, value),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "set",
      "field" => field,
      "op" => op,
      "value" => value
    }

  # start → the steps in a row → end.
  defp chain(steps) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        steps ++ [%{"id" => "kraj", "type" => "endEvent"}]

    ids = Enum.map(nodes, & &1["id"])

    %{
      "nodes" => nodes,
      "flows" =>
        ids
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> %{"from" => a, "to" => b} end)
    }
  end

  defp drawn!(ctx, name, graph) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => name,
        "graph" => graph
      })

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp run!(ctx, row, title \\ "Lift") do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => title})
    Engine.run(instance.id)
  end

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  test "a step counts, another process reads it in a text and a condition", ctx do
    counter = drawn!(ctx, "Prijava", chain([set("broj", "kvarova", "add", "1")]))

    reader =
      drawn!(ctx, "Izveštaj", %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "mnogo", "type" => "exclusiveGateway"},
          message("hitno", "Već {{group.kvarova}} kvara, zovemo upravnika."),
          message("mirno", "Kvarova: {{group.kvarova}}"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "mnogo"},
          %{
            "from" => "mnogo",
            "to" => "hitno",
            "condition" => %{"field" => "group.kvarova", "op" => ">", "value" => 2}
          },
          %{"from" => "mnogo", "to" => "mirno", "default" => true},
          %{"from" => "hitno", "to" => "kraj"},
          %{"from" => "mirno", "to" => "kraj"}
        ]
      })

    for _ <- 1..2, do: assert(%ValueProcess{status: :done} = run!(ctx, counter))
    run!(ctx, reader)
    run!(ctx, counter)
    run!(ctx, reader)

    assert chat(ctx.group) == ["Kvarova: 2", "Već 3 kvara, zovemo upravnika."]

    assert [%GroupField{name: "kvarova", value: "3", app_process_id: id}] =
             GroupFields.list(ctx.group)

    assert id == counter.id
  end

  test "a step sets a text from what started the run", ctx do
    row = drawn!(ctx, "Poslednji", chain([set("poslednji", "poslednji", "set", "{{title}}")]))
    run!(ctx, row, "Svetlo u ulazu")

    assert %{"poslednji" => "Svetlo u ulazu"} = GroupFields.for_process(row.id)
  end

  test "adding keeps whole numbers whole, and takes no text", ctx do
    row = drawn!(ctx, "Kasa", chain([set("uplata", "kasa", "add", "{{title}}")]))

    run!(ctx, row, "1,5")
    run!(ctx, row, "2.5")
    assert %{"kasa" => "4"} = GroupFields.for_process(row.id)

    assert %ValueProcess{status: :failed, error: %{"reason" => "not_a_number"}} =
             run!(ctx, row, "mnogo")

    assert {:error, {:invalid_graph, "nodes.1.value", :not_a_number}} =
             DrawnProcesses.create(ctx.owner, ctx.group, %{
               "trigger" => "manual",
               "name" => "Loše",
               "graph" => chain([set("uplata", "kasa", "add", "mnogo")])
             })
  end

  test "a group keeps at most 50 fields, and its editors delete them", ctx do
    row = drawn!(ctx, "Polja", chain([set("novo", "polje", "set", "x")]))

    for i <- 1..50,
        do: Repo.insert!(%GroupField{group_id: ctx.group.id, name: "f#{i}", value: ""})

    assert %ValueProcess{status: :failed, error: %{"reason" => "too_many_fields"}} =
             run!(ctx, row)

    field = Repo.get_by!(GroupField, group_id: ctx.group.id, name: "f1")

    assert {:error, :not_permitted} =
             GroupFields.delete(ctx.group, Access.for_profile(ctx.member, ctx.group), field.id)

    assert {:ok, _gone} =
             GroupFields.delete(ctx.group, Access.for_profile(ctx.owner, ctx.group), field.id)

    {:ok, _retried} = Engine.retry(Repo.get_by!(ValueProcess, app_process_id: row.id).id)

    assert %ValueProcess{status: :done} =
             Engine.run(Repo.get_by!(ValueProcess, app_process_id: row.id).id)
  end

  test "a value is cut at 1000 characters", ctx do
    row = drawn!(ctx, "Dugo", chain([set("dugo", "dugo", "set", "{{title}}")]))
    {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => "x"})

    instance
    |> Ecto.Changeset.change(data: %{"title" => String.duplicate("a", 1_200)})
    |> Repo.update!()

    Engine.run(instance.id)
    assert String.length(GroupFields.for_process(row.id)["dugo"]) == 1_000
  end

  test "an app's own process neither sets nor reads them", ctx do
    assert {:error, {:invalid_process, _collection, "process.graph.nodes.1.action", :invalid}} =
             AppData.save_config(
               ctx.owner,
               ctx.group,
               nil,
               %{
                 "rules" => %{
                   "molbe" => %{
                     "process" => %{
                       "name" => "Prijem",
                       "graph" => chain([set("broj", "kvarova", "add", "1")])
                     }
                   }
                 }
               },
               0
             )
  end
end
