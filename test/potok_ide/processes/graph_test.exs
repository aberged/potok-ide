defmodule PotokIde.Processes.GraphTest do
  @moduledoc """
  The graph of an app's process is checked when the rules are saved, so an
  instance never starts with a graph it cannot finish.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Processes.Graph

  # The plan's example: a request comes in, the chat hears of it, it gets a
  # sub-group, and the council decides, reminded every seven days.
  defp molbe do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "primljeno",
          "type" => "serviceTask",
          "action" => "message",
          "in" => "app",
          "text" => "Stigla je molba: {{naslov}}"
        },
        %{
          "id" => "predmet",
          "type" => "serviceTask",
          "action" => "subgroup",
          "name" => "Molba: {{naslov}}",
          "admins" => ["triggered_by", "savet"]
        },
        %{
          "id" => "odluka",
          "type" => "userTask",
          "role" => "savet",
          "outcomes" => ["odobri", "odbij"],
          "deadline" => "P7D"
        },
        %{
          "id" => "podsetnik",
          "type" => "serviceTask",
          "action" => "push",
          "role" => "savet",
          "text" => "Molba {{naslov}} čeka odluku"
        },
        %{
          "id" => "odobreno",
          "type" => "serviceTask",
          "action" => "message",
          "in" => "predmet",
          "text" => "Molba je odobrena."
        },
        %{
          "id" => "odbijeno",
          "type" => "serviceTask",
          "action" => "message",
          "in" => "predmet",
          "text" => "Molba je odbijena."
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "primljeno"},
        %{"from" => "primljeno", "to" => "predmet"},
        %{"from" => "predmet", "to" => "odluka"},
        %{"from" => "odluka", "to" => "odobreno", "outcome" => "odobri"},
        %{"from" => "odluka", "to" => "odbijeno", "outcome" => "odbij"},
        %{"from" => "odluka", "to" => "podsetnik", "deadline" => true},
        %{"from" => "podsetnik", "to" => "odluka"},
        %{"from" => "odobreno", "to" => "kraj"},
        %{"from" => "odbijeno", "to" => "kraj"}
      ]
    }
  end

  defp linear(middle) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        middle,
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => middle["id"]},
        %{"from" => middle["id"], "to" => "kraj"}
      ]
    }
  end

  defp update_node(graph, id, fun) do
    Map.update!(graph, "nodes", fn nodes ->
      Enum.map(nodes, fn node -> if node["id"] == id, do: fun.(node), else: node end)
    end)
  end

  defp drop_flow(graph, from, to) do
    Map.update!(graph, "flows", &Enum.reject(&1, fn f -> f["from"] == from and f["to"] == to end))
  end

  describe "normalize/1" do
    test "takes the example whole, with the defaults filled in and nothing unknown kept" do
      graph =
        molbe()
        |> update_node("start", &Map.put(&1, "color", "red"))
        |> update_node("predmet", &Map.delete(&1, "admins"))

      assert {:ok, %{"nodes" => nodes, "flows" => flows}} = Graph.normalize(graph)
      assert length(nodes) == 8 and length(flows) == 9
      assert %{"id" => "start", "type" => "startEvent"} = hd(nodes)
      refute Map.has_key?(hd(nodes), "color")

      assert %{"admins" => ["owner", "triggered_by"]} =
               Enum.find(nodes, &(&1["id"] == "predmet"))
    end

    test "needs one start, an end, and elements that are known" do
      assert {:error, {"nodes", :empty}} = Graph.normalize(%{"nodes" => [], "flows" => []})
      assert {:error, {"", :invalid}} = Graph.normalize(%{"nodes" => "x"})

      no_end = linear(%{"id" => "a", "type" => "timer", "duration" => "PT1H"})
      no_end = Map.update!(no_end, "nodes", &Enum.reject(&1, fn n -> n["type"] == "endEvent" end))
      assert {:error, {"flows.1.to", :unknown}} = Graph.normalize(no_end)

      two_starts =
        Map.update!(molbe(), "nodes", &(&1 ++ [%{"id" => "start2", "type" => "startEvent"}]))

      assert {:error, {"nodes.8", :second_start}} = Graph.normalize(two_starts)

      assert {:error, {"nodes.1.type", :invalid}} =
               Graph.normalize(linear(%{"id" => "a", "type" => "scriptTask"}))

      assert {:error, {"nodes.1.id", :invalid}} =
               Graph.normalize(linear(%{"id" => "Prvi korak", "type" => "endEvent"}))

      dup = update_node(molbe(), "kraj", &Map.put(&1, "id", "start"))
      assert {:error, {"nodes.7.id", :duplicate}} = Graph.normalize(dup)
    end

    test "every outcome and the deadline of a task have their flow" do
      assert {:error, {"nodes.3.outcomes", :no_flow}} =
               molbe() |> drop_flow("odluka", "odbijeno") |> Graph.normalize()

      assert {:error, {"nodes.3.deadline", :no_flow}} =
               molbe() |> update_node("odluka", &Map.delete(&1, "deadline")) |> Graph.normalize()

      assert {:error, {"nodes.3.outcomes", :duplicate}} =
               molbe()
               |> update_node("odluka", &Map.put(&1, "outcomes", ["da", "da"]))
               |> Graph.normalize()
    end

    test "a gateway has a default flow, and conditions on the others" do
      gateway = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "iznos", "type" => "exclusiveGateway"},
          %{"id" => "kraj", "type" => "endEvent"},
          %{"id" => "veliko", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "iznos"},
          %{
            "from" => "iznos",
            "to" => "veliko",
            "condition" => %{"field" => "iznos", "op" => ">", "value" => 1000}
          },
          %{"from" => "iznos", "to" => "kraj", "default" => true}
        ]
      }

      assert {:ok, _graph} = Graph.normalize(gateway)

      no_default = drop_flow(gateway, "iznos", "kraj")
      assert {:error, {"nodes.1", :no_default}} = Graph.normalize(no_default)

      bad_op =
        put_in(gateway, ["flows", Access.at(1), "condition", "op"], "contains")

      assert {:error, {"flows.1.condition", :invalid}} = Graph.normalize(bad_op)
    end

    test "every element can be reached and can reach an end" do
      lonely =
        Map.update!(molbe(), "nodes", &(&1 ++ [%{"id" => "zaboravljen", "type" => "endEvent"}]))

      assert {:error, {"nodes.8", :unreachable}} = Graph.normalize(lonely)

      # A reminder that only leads back to itself never ends.
      loop =
        molbe()
        |> drop_flow("podsetnik", "odluka")
        |> Map.update!("flows", &(&1 ++ [%{"from" => "podsetnik", "to" => "podsetnik"}]))

      assert {:error, {"nodes.4", :dead_end}} = Graph.normalize(loop)
    end

    test "checks durations, texts and where a message goes" do
      for duration <- ["P0D", "PT30S", "P2Y", "tri dana", "P"] do
        assert {:error, {"nodes.1.duration", :invalid}} =
                 Graph.normalize(
                   linear(%{"id" => "cekaj", "type" => "timer", "duration" => duration})
                 )
      end

      assert {:ok, _graph} =
               Graph.normalize(
                 linear(%{"id" => "cekaj", "type" => "timer", "duration" => "PT1M"})
               )

      long = %{
        "id" => "a",
        "type" => "serviceTask",
        "action" => "push",
        "role" => "x",
        "text" => String.duplicate("a", 241)
      }

      assert {:error, {"nodes.1.text", :invalid}} = Graph.normalize(linear(long))

      assert {:error, {"nodes.5.in", :unknown}} =
               molbe()
               |> update_node("odobreno", &Map.put(&1, "in", "primljeno"))
               |> Graph.normalize()
    end

    test "flows leave each element as it allows" do
      assert {:error, {"nodes.0", :one_flow}} =
               molbe()
               |> Map.update!("flows", &(&1 ++ [%{"from" => "start", "to" => "kraj"}]))
               |> Graph.normalize()

      assert {:error, {"nodes.3", :plain_flow}} =
               molbe()
               |> Map.update!("flows", &(&1 ++ [%{"from" => "odluka", "to" => "kraj"}]))
               |> Graph.normalize()

      assert {:error, {"flows.9", :invalid}} =
               molbe()
               |> Map.update!(
                 "flows",
                 &(&1 ++
                     [%{"from" => "odluka", "to" => "kraj", "outcome" => "x", "default" => true}])
               )
               |> Graph.normalize()
    end
  end

  describe "a call" do
    defp calling(call, extra_flows \\ []) do
      %{
        "nodes" =>
          [
            %{"id" => "start", "type" => "startEvent"},
            Map.merge(%{"id" => "poziv", "type" => "callActivity", "process" => 7}, call),
            %{"id" => "kraj", "type" => "endEvent"}
          ] ++ if(extra_flows == [], do: [], else: [%{"id" => "rok", "type" => "endEvent"}]),
        "flows" =>
          [%{"from" => "start", "to" => "poziv"}, %{"from" => "poziv", "to" => "kraj"}] ++
            extra_flows
      }
    end

    test "is only for a process drawn in Potok, waiting unless told not to" do
      assert {:error, {"nodes.1.type", :invalid}} = Graph.normalize(calling(%{}))

      assert {:ok, %{"nodes" => [_, call | _]}} =
               Graph.normalize(calling(%{"fields" => %{"kvar" => " {{title}} "}}), drawn: true)

      assert call == %{
               "id" => "poziv",
               "type" => "callActivity",
               "process" => 7,
               "wait" => true,
               "fields" => %{"kvar" => "{{title}}"}
             }
    end

    test "names a process, the fields it hands over, and a deadline only while it waits" do
      for {call, path} <- [
            {%{"process" => "7"}, "nodes.1.process"},
            {%{"process" => 0}, "nodes.1.process"},
            {%{"wait" => "da"}, "nodes.1.wait"},
            {%{"fields" => %{"dve reči" => ""}}, "nodes.1.fields.dve reči"},
            {%{"fields" => %{"kvar" => 1}}, "nodes.1.fields.kvar"},
            {%{"fields" => Map.new(1..11, &{"f#{&1}", ""})}, "nodes.1.fields"},
            {%{"wait" => false, "deadline" => "PT1H"}, "nodes.1.deadline"}
          ] do
        assert {:error, {^path, :invalid}} = Graph.normalize(calling(call), drawn: true)
      end
    end

    test "goes on by one flow, and by a second when its deadline passes" do
      deadline = [%{"from" => "poziv", "to" => "rok", "deadline" => true}]

      assert {:ok, _graph} =
               Graph.normalize(calling(%{"deadline" => "P1D"}, deadline), drawn: true)

      assert {:error, {"nodes.1.deadline", :no_flow}} =
               Graph.normalize(calling(%{"deadline" => "P1D"}), drawn: true)

      assert {:error, {"nodes.1.deadline", :no_flow}} =
               Graph.normalize(calling(%{}, deadline), drawn: true)

      assert {:error, {"nodes.1", :one_flow}} =
               Graph.normalize(calling(%{}, [%{"from" => "poziv", "to" => "rok"}]), drawn: true)
    end

    test "reaches only processes that take calls, with the fields they take" do
      {:ok, graph} = Graph.normalize(calling(%{"fields" => %{"kvar" => "x"}}), drawn: true)

      assert Graph.process_refs(graph) == [{"nodes.1", 7, ["kvar"]}]
      assert Graph.unknown_process(graph, %{7 => ["kvar", "sprat"]}) == nil
      assert Graph.unknown_process(graph, %{7 => []}) == {"nodes.1.fields.kvar", :unknown_field}

      assert Graph.unknown_process(graph, %{8 => ["kvar"]}) ==
               {"nodes.1.process", :unknown_process}
    end
  end

  test "a group's field is set, or added to with a number or a field, only when drawn" do
    graph = fn set ->
      %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          Map.merge(%{"id" => "polje", "type" => "serviceTask", "action" => "set"}, set),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "polje"}, %{"from" => "polje", "to" => "kraj"}]
      }
    end

    ok = %{"field" => "kvarova", "op" => "add", "value" => " 1 "}

    assert {:error, {"nodes.1.action", :invalid}} = Graph.normalize(graph.(ok))
    assert {:ok, %{"nodes" => [_, set, _]}} = Graph.normalize(graph.(ok), drawn: true)
    assert set["value"] == "1"

    assert {:ok, %{"nodes" => [_, %{"op" => "set", "value" => ""}, _]}} =
             Graph.normalize(graph.(%{"field" => "zadnji", "value" => ""}), drawn: true)

    assert {:ok, _graph} =
             Graph.normalize(graph.(%{ok | "value" => "{{iznos}}"}), drawn: true)

    for {set, path, reason} <- [
          {%{ok | "field" => "dve reči"}, "nodes.1.field", :invalid},
          {%{ok | "field" => "group.x"}, "nodes.1.field", :invalid},
          {%{ok | "op" => "times"}, "nodes.1.op", :invalid},
          {%{ok | "value" => String.duplicate("1", 1_001)}, "nodes.1.value", :invalid},
          {%{ok | "value" => "puno"}, "nodes.1.value", :not_a_number}
        ] do
      assert {:error, {^path, ^reason}} = Graph.normalize(graph.(set), drawn: true)
    end
  end

  test "names what the actions need and the roles they name" do
    {:ok, graph} = Graph.normalize(molbe())

    assert Graph.permissions(graph) == [:create_subgroups, :mention_roles, :post_values]
    assert Graph.permissions(nil) == []

    assert Graph.role_refs(graph) == [
             {"nodes.2.admins.1", "savet"},
             {"nodes.3.role", "savet"},
             {"nodes.4.role", "savet"}
           ]
  end

  test "keeps a label on any element, trimmed, and drops a blank one" do
    graph =
      molbe()
      |> update_node("odluka", &Map.put(&1, "label", "  Savet odlučuje "))
      |> update_node("kraj", &Map.put(&1, "label", " "))

    assert {:ok, %{"nodes" => nodes}} = Graph.normalize(graph)
    odluka = Enum.find(nodes, &(&1["id"] == "odluka"))
    kraj = Enum.find(nodes, &(&1["id"] == "kraj"))

    assert odluka["label"] == "Savet odlučuje"
    refute Map.has_key?(kraj, "label")
    assert Graph.label(odluka) == "Savet odlučuje"
    assert Graph.label(kraj) == "kraj"

    assert {:error, {"nodes.3.label", :invalid}} =
             molbe()
             |> update_node("odluka", &Map.put(&1, "label", String.duplicate("a", 61)))
             |> Graph.normalize()

    assert {:error, {"nodes.0.label", :invalid}} =
             molbe() |> update_node("start", &Map.put(&1, "label", 7)) |> Graph.normalize()
  end

  test "finds the first role the group does not have" do
    {:ok, graph} = Graph.normalize(molbe())

    assert Graph.unknown_role(graph, MapSet.new(["savet"])) == nil
    assert Graph.unknown_role(graph, MapSet.new(["admin"])) == {"nodes.2.admins.1", :unknown_role}
  end

  test "reads durations in seconds" do
    assert Graph.seconds("PT30M") == 1_800
    assert Graph.seconds("PT1H") == 3_600
    assert Graph.seconds("P3D") == 259_200
    assert Graph.seconds("P1W") == 604_800
    assert Graph.seconds("P1DT2H") == 93_600
    assert Graph.seconds("P") == nil
  end
end
