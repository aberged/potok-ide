defmodule PotokIde.Processes.GraphEditTest do
  @moduledoc """
  Drawing a process in Potok: every change keeps a graph an instance can
  finish, so an editor on a phone rarely meets an error.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Processes.{Graph, GraphEdit}

  @defaults %{
    text: "Stigla je molba.",
    name: "Molba",
    role: "admin",
    outcomes: ["Odobri", "Odbij"],
    outcome: "Ishod",
    field: "naslov",
    process: 7,
    call_fields: %{"kvar" => ""},
    group_field: "polje",
    signal: "subota"
  }

  defp valid!(graph) do
    assert {:ok, _normalized} = Graph.normalize(graph, drawn: true)
    graph
  end

  defp first_key(graph), do: hd(graph["flows"])["key"]
  defp ids(graph), do: Enum.map(graph["nodes"], & &1["id"])

  defp insert!(graph, key, kind) do
    {:ok, graph} = GraphEdit.insert(graph, key, kind, @defaults)
    valid!(graph)
  end

  test "a new drawing only starts and ends, and is already whole" do
    graph = valid!(GraphEdit.new())
    assert ids(graph) == ["start", "end"]
  end

  test "keys come with a saved graph and go when it is saved" do
    graph = GraphEdit.new() |> Graph.normalize() |> elem(1) |> GraphEdit.with_keys()
    assert [%{"key" => "f1"}] = graph["flows"]
    assert {:ok, %{"flows" => [flow]}} = Graph.normalize(graph)
    refute Map.has_key?(flow, "key")
  end

  test "every kind of step goes into a flow and leaves where it led" do
    for kind <- GraphEdit.kinds() do
      graph = insert!(GraphEdit.new(), "f1", kind)
      assert length(graph["nodes"]) == 3, kind
    end
  end

  test "a decision leaves by each outcome, a condition by one and by default" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    assert ["Odobri", "Odbij"] == graph |> Graph.out("task-1") |> Enum.map(& &1["outcome"])

    graph = insert!(GraphEdit.new(), "f1", "gateway")
    out = Graph.out(graph, "gateway-1")
    assert [%{"condition" => %{"field" => "naslov"}}, %{"default" => true}] = out
  end

  test "branches go where their siblings go, a condition's before its default" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.add_branch(graph, "task-1", @defaults)
    {:ok, graph} = GraphEdit.add_branch(graph, "task-1", @defaults)
    valid!(graph)
    assert Graph.node(graph, "task-1")["outcomes"] == ["Odobri", "Odbij", "Ishod", "Ishod 2"]

    graph = insert!(GraphEdit.new(), "f1", "gateway")
    {:ok, graph} = GraphEdit.add_branch(graph, "gateway-1", @defaults)
    valid!(graph)

    assert [%{"condition" => _}, %{"condition" => _}, %{"default" => true}] =
             Graph.out(graph, "gateway-1")
  end

  test "a deadline reminds and comes back, and goes again with what only it reached" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.set_deadline(graph, "task-1", "P7D", %{text: "Čeka odluku"})
    valid!(graph)
    assert %{"deadline" => "P7D"} = Graph.node(graph, "task-1")
    assert "push-1" in ids(graph)
    assert Enum.any?(Graph.out(graph, "push-1"), &(&1["to"] == "task-1"))

    {:ok, graph} = GraphEdit.set_deadline(graph, "task-1", "P3D")
    assert %{"deadline" => "P3D"} = Graph.node(graph, "task-1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "task-1", nil)
    valid!(graph)
    refute "push-1" in ids(graph)
  end

  test "a call's deadline goes where the call goes on, and goes when it stops waiting" do
    graph = insert!(GraphEdit.new(), "f1", "call")

    assert %{"process" => 7, "wait" => true, "fields" => %{"kvar" => ""}} =
             Graph.node(graph, "call-1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "call-1", "P7D")
    valid!(graph)
    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] = Graph.out(graph, "call-1")

    # Drawing an arrow from it moves its way on, not its deadline.
    graph = insert!(graph, first_key(graph), "message")
    {:ok, graph} = GraphEdit.connect(graph, "call-1", "end")
    valid!(graph)
    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] = Graph.out(graph, "call-1")

    {:ok, graph} = GraphEdit.update_node(graph, "call-1", %{"wait" => false, "role" => "x"})
    valid!(graph)
    assert [%{"to" => "end"}] = Graph.out(graph, "call-1")
    refute Map.has_key?(Graph.node(graph, "call-1"), "deadline")
    refute Map.has_key?(Graph.node(graph, "call-1"), "role")
  end

  test "a wait for a signal gets a deadline where it goes on" do
    graph = insert!(GraphEdit.new(), "f1", "receive")
    assert %{"signal" => "subota", "same_subject" => false} = Graph.node(graph, "receive-1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "receive-1", "P1D")
    valid!(graph)

    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] =
             Graph.out(graph, "receive-1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "receive-1", nil)
    assert [%{"to" => "end"}] = Graph.out(valid!(graph), "receive-1")
  end

  test "an outcome is renamed with its flow, and the last one stays" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.rename_outcome(graph, "task-1", "Odbij", "Vrati")
    valid!(graph)
    assert {:error, :duplicate} = GraphEdit.rename_outcome(graph, "task-1", "Vrati", "Odobri")

    vrati = Enum.find(graph["flows"], &(&1["outcome"] == "Vrati"))
    {:ok, graph} = GraphEdit.delete_flow(graph, vrati["key"])
    valid!(graph)

    odobri = Enum.find(graph["flows"], &(&1["outcome"] == "Odobri"))
    assert {:error, :last_branch} = GraphEdit.delete_flow(graph, odobri["key"])
    assert {:error, :needed} = GraphEdit.delete_flow(graph, first_key(graph))
  end

  test "flows are sent elsewhere, to a new end too, but never back to the start" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    odbij = Enum.find(graph["flows"], &(&1["outcome"] == "Odbij"))

    {:ok, graph} = GraphEdit.retarget(graph, odbij["key"], :new_end)
    valid!(graph)
    assert "end-1" in ids(graph)

    assert {:error, :to_start} = GraphEdit.retarget(graph, odbij["key"], "start")
    assert {:error, :self} = GraphEdit.retarget(graph, odbij["key"], "task-1")
  end

  test "connecting two steps draws the flow each kind can have" do
    graph = GraphEdit.new() |> insert!("f1", "message") |> insert!("f1", "task")
    # start → task-1 → message-1 → end
    {:ok, graph} = GraphEdit.connect(graph, "task-1", "end", @defaults)
    valid!(graph)

    assert Enum.any?(
             Graph.out(graph, "task-1"),
             &(&1["to"] == "end" and &1["outcome"] == "Ishod")
           )

    {:ok, graph} = GraphEdit.connect(graph, "message-1", "task-1")
    assert [%{"to" => "task-1"}] = Graph.out(graph, "message-1")

    assert {:error, :from_end} = GraphEdit.connect(graph, "end", "task-1")
    assert {:error, :to_start} = GraphEdit.connect(graph, "task-1", "start")
  end

  test "a deleted step gives its place to what follows, and takes what only it reached" do
    graph =
      GraphEdit.new()
      |> insert!("f1", "message")
      |> insert!("f1", "task")

    odbij = Enum.find(graph["flows"], &(&1["outcome"] == "Odbij"))
    {:ok, graph} = GraphEdit.retarget(graph, odbij["key"], :new_end)
    {:ok, graph} = GraphEdit.insert(graph, odbij["key"], "subgroup", @defaults)

    {:ok, after_message, ["message-1"]} = GraphEdit.delete_node(graph, "message-1")
    valid!(after_message)

    {:ok, after_task, removed} = GraphEdit.delete_node(graph, "task-1")
    valid!(after_task)
    assert Enum.sort(removed) == ["end-1", "subgroup-1", "task-1"]

    assert {:error, :start} = GraphEdit.delete_node(graph, "start")
    assert {:error, :last_end} = GraphEdit.delete_node(GraphEdit.new(), "end")
  end

  test "a message into a deleted sub-group goes to the app's group" do
    graph = GraphEdit.new() |> insert!("f1", "message") |> insert!("f1", "subgroup")
    {:ok, graph} = GraphEdit.update_node(graph, "message-1", %{"in" => "subgroup-1"})
    valid!(graph)

    {:ok, graph, _removed} = GraphEdit.delete_node(graph, "subgroup-1")
    assert %{"in" => "app"} = Graph.node(valid!(graph), "message-1")
  end

  test "a step takes only what its kind has, and a blank label is none" do
    graph = insert!(GraphEdit.new(), "f1", "message")

    {:ok, graph} =
      GraphEdit.update_node(graph, "message-1", %{
        "label" => " Najava ",
        "text" => "Nova",
        "role" => "x"
      })

    assert %{"label" => "Najava", "text" => "Nova"} = node = Graph.node(graph, "message-1")
    refute Map.has_key?(node, "role")

    {:ok, graph} = GraphEdit.update_node(graph, "message-1", %{"label" => "  "})
    refute Map.has_key?(Graph.node(graph, "message-1"), "label")
  end

  test "a condition compares a field, or asks whether it is empty" do
    graph = insert!(GraphEdit.new(), "f1", "gateway")
    key = hd(Graph.out(graph, "gateway-1"))["key"]

    {:ok, graph} =
      GraphEdit.update_condition(graph, key, %{"field" => "broj", "op" => ">", "value" => "3"})

    assert %{"condition" => %{"field" => "broj", "op" => ">", "value" => "3"}} =
             GraphEdit.flow(valid!(graph), key)

    {:ok, graph} =
      GraphEdit.update_condition(graph, key, %{"field" => "broj", "op" => "empty", "value" => "3"})

    assert %{"condition" => %{"op" => "empty"} = condition} = GraphEdit.flow(valid!(graph), key)
    refute Map.has_key?(condition, "value")
  end
end
