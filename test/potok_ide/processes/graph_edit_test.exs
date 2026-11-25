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
    signal: "subota",
    variable: "ukupno",
    poll_question: "Slažemo li se?",
    poll_answers: ["Da", "Ne"]
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
    {:ok, saved} = Graph.normalize(GraphEdit.new(), drawn: true)
    graph = GraphEdit.with_keys(saved)
    assert [%{"key" => "f1"}] = graph["flows"]
    assert {:ok, %{"flows" => [flow]}} = Graph.normalize(graph, drawn: true)
    refute Map.has_key?(flow, "key")
  end

  test "a drawing is in today's language, and keeps what the graph keeps beside its steps" do
    assert %{"v" => 2} = GraphEdit.new()

    graph = GraphEdit.new() |> Map.merge(%{"zone" => "Europe/Belgrade", "entry" => %{}})
    assert %{"v" => 2, "zone" => "Europe/Belgrade", "entry" => %{}} = GraphEdit.with_keys(graph)

    {:ok, graph} = GraphEdit.insert(GraphEdit.with_keys(graph), "f1", "message", @defaults)
    assert %{"v" => 2, "zone" => "Europe/Belgrade"} = graph
  end

  test "every kind of step goes into a flow and leaves where it led" do
    for kind <- GraphEdit.kinds() do
      graph = insert!(GraphEdit.new(), "f1", kind)
      # A loop comes with the first step of its body, a poll with the
      # condition that asks how it ended.
      assert length(graph["nodes"]) == if(kind in ["loop", "poll"], do: 4, else: 3), kind
    end
  end

  # What the condition after the poll of `graph` asks.
  defp asked(graph) do
    assert [%{"condition" => %{"expr" => asked}} | _] = Graph.out(graph, "gateway_1")
    asked
  end

  test "a poll that only asks goes on to a condition that asks whether its first answer won" do
    graph = insert!(GraphEdit.new(), "f1", "poll")

    assert [%{"to" => "gateway_1"}] = Graph.out(graph, "poll_1")

    assert [%{"condition" => %{"expr" => ~s(poll_1.winner = "Da")}}, %{"default" => true}] =
             Graph.out(graph, "gateway_1")
  end

  test "that condition goes by what the poll asks, until someone writes their own" do
    graph = insert!(GraphEdit.new(), "f1", "poll")

    {:ok, graph} =
      GraphEdit.update_node(graph, "poll_1", %{"answers" => [~s(Za „kućni red"), "Protiv"]})

    assert asked(graph) == ~S(poll_1.winner = "Za \„kućni red\"")
    valid!(graph)

    # With no answers for a moment, as they are being typed.
    {:ok, graph} = GraphEdit.update_node(graph, "poll_1", %{"answers" => []})
    {:ok, graph} = GraphEdit.update_node(graph, "poll_1", %{"answers" => ["Da", "Ne"]})
    assert asked(graph) == ~s(poll_1.winner = "Da")

    # A decision on a role approves or not, in answers of its own.
    {:ok, graph} =
      GraphEdit.update_node(graph, "poll_1", %{"effect" => "grant", "role" => "admin"})

    assert asked(graph) == "poll_1.passed"
    {:ok, graph} = GraphEdit.update_node(graph, "poll_1", %{"effect" => "none"})
    assert asked(graph) == ~s(poll_1.winner = "Da")

    [%{"key" => key} | _] = Graph.out(graph, "gateway_1")

    {:ok, graph} =
      GraphEdit.update_condition(graph, key, %{"expr" => ~s(poll_1.winner = "Ne")})

    {:ok, graph} = GraphEdit.update_node(graph, "poll_1", %{"answers" => ["Jeste", "Nije"]})
    assert asked(graph) == ~s(poll_1.winner = "Ne")
  end

  test "a decision leaves by each outcome, a condition by one and by default" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    assert ["Odobri", "Odbij"] == graph |> Graph.out("task_1") |> Enum.map(& &1["outcome"])

    graph = insert!(GraphEdit.new(), "f1", "gateway")
    out = Graph.out(graph, "gateway_1")
    # A new condition holds until its editor writes what it asks.
    assert [%{"condition" => %{"expr" => "true"}}, %{"default" => true}] = out

    {:ok, graph} =
      GraphEdit.insert(GraphEdit.new(), "f1", "gateway", Map.put(@defaults, :condition, "a > 1"))

    assert [%{"condition" => %{"expr" => "a > 1"}}, _default] = Graph.out(graph, "gateway_1")
  end

  test "branches go where their siblings go, a condition's before its default" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.add_branch(graph, "task_1", @defaults)
    {:ok, graph} = GraphEdit.add_branch(graph, "task_1", @defaults)
    valid!(graph)
    assert Graph.node(graph, "task_1")["outcomes"] == ["Odobri", "Odbij", "Ishod", "Ishod 2"]

    graph = insert!(GraphEdit.new(), "f1", "gateway")
    {:ok, graph} = GraphEdit.add_branch(graph, "gateway_1", @defaults)
    valid!(graph)

    assert [%{"condition" => _}, %{"condition" => _}, %{"default" => true}] =
             Graph.out(graph, "gateway_1")
  end

  test "a deadline reminds and comes back, and goes again with what only it reached" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.set_deadline(graph, "task_1", "P7D", %{text: "Čeka odluku"})
    valid!(graph)
    assert %{"deadline" => "P7D"} = Graph.node(graph, "task_1")
    assert "push_1" in ids(graph)
    assert Enum.any?(Graph.out(graph, "push_1"), &(&1["to"] == "task_1"))

    {:ok, graph} = GraphEdit.set_deadline(graph, "task_1", "P3D")
    assert %{"deadline" => "P3D"} = Graph.node(graph, "task_1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "task_1", nil)
    valid!(graph)
    refute "push_1" in ids(graph)
  end

  test "a call's deadline goes where the call goes on, and goes when it stops waiting" do
    graph = insert!(GraphEdit.new(), "f1", "call")

    assert %{"process" => 7, "wait" => true, "fields" => %{"kvar" => ""}} =
             Graph.node(graph, "call_1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "call_1", "P7D")
    valid!(graph)
    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] = Graph.out(graph, "call_1")

    # Drawing an arrow from it moves its way on, not its deadline.
    graph = insert!(graph, first_key(graph), "message")
    {:ok, graph} = GraphEdit.connect(graph, "call_1", "end")
    valid!(graph)
    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] = Graph.out(graph, "call_1")

    {:ok, graph} = GraphEdit.update_node(graph, "call_1", %{"wait" => false, "role" => "x"})
    valid!(graph)
    assert [%{"to" => "end"}] = Graph.out(graph, "call_1")
    refute Map.has_key?(Graph.node(graph, "call_1"), "deadline")
    refute Map.has_key?(Graph.node(graph, "call_1"), "role")
  end

  test "a wait for a signal gets a deadline where it goes on" do
    graph = insert!(GraphEdit.new(), "f1", "receive")
    assert %{"signal" => "subota", "same_subject" => false} = Graph.node(graph, "receive_1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "receive_1", "P1D")
    valid!(graph)

    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] =
             Graph.out(graph, "receive_1")

    {:ok, graph} = GraphEdit.set_deadline(graph, "receive_1", nil)
    assert [%{"to" => "end"}] = Graph.out(valid!(graph), "receive_1")
  end

  test "a form asks whoever started the run, or a role, and gets a deadline where it goes on" do
    graph = insert!(GraphEdit.new(), "f1", "form")

    assert Graph.node(graph, "form_1") == %{
             "id" => "form_1",
             "type" => "formTask",
             "by" => "starter"
           }

    {:ok, graph} =
      GraphEdit.insert(GraphEdit.new(), "f1", "form", Map.put(@defaults, :form_entity, 12))

    assert %{"entity" => 12, "by" => "starter"} = Graph.node(graph, "form_1")

    {:ok, graph} =
      GraphEdit.update_node(graph, "form_1", %{
        "by" => "role",
        "role" => "savet",
        "entity" => 14,
        "outcomes" => ["Da"]
      })

    assert Graph.node(valid!(graph), "form_1") ==
             %{
               "id" => "form_1",
               "type" => "formTask",
               "by" => "role",
               "role" => "savet",
               "entity" => 14
             }

    # One whoever started the run fills in names no role, and may name no entity yet.
    {:ok, graph} =
      GraphEdit.update_node(graph, "form_1", %{"by" => "starter", "role" => nil, "entity" => nil})

    assert Graph.node(valid!(graph), "form_1") ==
             %{"id" => "form_1", "type" => "formTask", "by" => "starter"}

    {:ok, graph} = GraphEdit.set_deadline(graph, "form_1", "P2D")
    valid!(graph)
    assert [%{"to" => "end"}, %{"to" => "end", "deadline" => true}] = Graph.out(graph, "form_1")
    refute "push_1" in ids(graph)

    {:ok, graph} = GraphEdit.set_deadline(graph, "form_1", nil)
    assert [%{"to" => "end"}] = Graph.out(valid!(graph), "form_1")
  end

  test "an outcome is renamed with its flow, and the last one stays" do
    graph = insert!(GraphEdit.new(), "f1", "task")
    {:ok, graph} = GraphEdit.rename_outcome(graph, "task_1", "Odbij", "Vrati")
    valid!(graph)
    assert {:error, :duplicate} = GraphEdit.rename_outcome(graph, "task_1", "Vrati", "Odobri")

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
    assert "end_1" in ids(graph)

    assert {:error, :to_start} = GraphEdit.retarget(graph, odbij["key"], "start")
    assert {:error, :self} = GraphEdit.retarget(graph, odbij["key"], "task_1")
  end

  test "connecting two steps draws the flow each kind can have" do
    graph = GraphEdit.new() |> insert!("f1", "message") |> insert!("f1", "task")
    # start → task_1 → message_1 → end
    {:ok, graph} = GraphEdit.connect(graph, "task_1", "end", @defaults)
    valid!(graph)

    assert Enum.any?(
             Graph.out(graph, "task_1"),
             &(&1["to"] == "end" and &1["outcome"] == "Ishod")
           )

    {:ok, graph} = GraphEdit.connect(graph, "message_1", "task_1")
    assert [%{"to" => "task_1"}] = Graph.out(graph, "message_1")

    assert {:error, :from_end} = GraphEdit.connect(graph, "end", "task_1")
    assert {:error, :to_start} = GraphEdit.connect(graph, "task_1", "start")
  end

  test "a deleted step gives its place to what follows, and takes what only it reached" do
    graph =
      GraphEdit.new()
      |> insert!("f1", "message")
      |> insert!("f1", "task")

    odbij = Enum.find(graph["flows"], &(&1["outcome"] == "Odbij"))
    {:ok, graph} = GraphEdit.retarget(graph, odbij["key"], :new_end)
    {:ok, graph} = GraphEdit.insert(graph, odbij["key"], "subgroup", @defaults)

    {:ok, after_message, ["message_1"]} = GraphEdit.delete_node(graph, "message_1")
    valid!(after_message)

    {:ok, after_task, removed} = GraphEdit.delete_node(graph, "task_1")
    valid!(after_task)
    assert Enum.sort(removed) == ["end_1", "subgroup_1", "task_1"]

    assert {:error, :start} = GraphEdit.delete_node(graph, "start")
    assert {:error, :last_end} = GraphEdit.delete_node(GraphEdit.new(), "end")
  end

  test "a message into a deleted sub-group goes to the app's group" do
    graph = GraphEdit.new() |> insert!("f1", "message") |> insert!("f1", "subgroup")
    {:ok, graph} = GraphEdit.update_node(graph, "message_1", %{"in" => "subgroup_1"})
    valid!(graph)

    {:ok, graph, _removed} = GraphEdit.delete_node(graph, "subgroup_1")
    assert %{"in" => "app"} = Graph.node(valid!(graph), "message_1")
  end

  test "a sub-group names roles to inherit by only while it inherits" do
    graph = insert!(GraphEdit.new(), "f1", "subgroup")

    {:ok, graph} =
      GraphEdit.update_node(graph, "subgroup_1", %{"inherits" => true, "inherit_roles" => []})

    node = Graph.node(valid!(graph), "subgroup_1")
    assert node["inherits"] == true
    refute Map.has_key?(node, "inherit_roles")

    {:ok, graph} = GraphEdit.update_node(graph, "subgroup_1", %{"inherit_roles" => ["savet"]})

    assert %{"inherits" => true, "inherit_roles" => ["savet"]} =
             Graph.node(valid!(graph), "subgroup_1")

    {:ok, graph} = GraphEdit.update_node(graph, "subgroup_1", %{"inherits" => false})
    node = Graph.node(valid!(graph), "subgroup_1")
    refute Map.has_key?(node, "inherits")
    refute Map.has_key?(node, "inherit_roles")
  end

  test "a step takes only what its kind has, and a blank label is none" do
    graph = insert!(GraphEdit.new(), "f1", "message")

    {:ok, graph} =
      GraphEdit.update_node(graph, "message_1", %{
        "label" => " Najava ",
        "text" => "Nova",
        "role" => "x"
      })

    assert %{"label" => "Najava", "text" => "Nova"} = node = Graph.node(graph, "message_1")
    refute Map.has_key?(node, "role")

    {:ok, graph} = GraphEdit.update_node(graph, "message_1", %{"label" => "  "})
    refute Map.has_key?(Graph.node(graph, "message_1"), "label")
  end

  test "a condition asks an expression, and only a condition's flow takes one" do
    graph = insert!(GraphEdit.new(), "f1", "gateway")
    [condition, default] = Graph.out(graph, "gateway_1")

    {:ok, graph} =
      GraphEdit.update_condition(graph, condition["key"], %{"expr" => "  start.broj > 3 "})

    assert %{"condition" => %{"expr" => "start.broj > 3"}} =
             GraphEdit.flow(valid!(graph), condition["key"])

    assert {:error, :not_a_condition} =
             GraphEdit.update_condition(graph, default["key"], %{"expr" => "true"})

    assert {:error, :not_a_condition} =
             GraphEdit.update_condition(graph, condition["key"], %{"field" => "broj", "op" => "="})
  end
end
