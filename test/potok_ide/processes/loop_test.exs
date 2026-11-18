defmodule PotokIde.Processes.LoopTest do
  @moduledoc """
  The loop of a process drawn in Potok: a step that goes through a list, an
  item at a time, with a body that comes back to it; and the step that adds
  to a list.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{
    Check,
    Engine,
    Graph,
    GraphEdit,
    GroupEntities,
    Scope,
    Triggers,
    ValueProcess
  }

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp assign(id, target, value, op \\ "set"),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "assign",
      "target" => target,
      "op" => op,
      "value" => value
    }

  defp loop(id, list, item), do: %{"id" => id, "type" => "loop", "list" => list, "item" => item}

  defp variable(name, type, more \\ %{}),
    do: Map.merge(%{"name" => name, "type" => type}, more)

  defp row(steps), do: steps |> Enum.map(& &1["id"]) |> Enum.chunk_every(2, 1, :discard)

  # start → `before` → the loop, through `body` and back → `later` → kraj.
  defp looped(before, loop, body, later, variables \\ []) do
    first = %{"id" => "start", "type" => "startEvent"}
    last = %{"id" => "kraj", "type" => "endEvent"}
    [into | _] = body

    flows =
      for([from, to] <- row([first] ++ before ++ [loop]), do: %{"from" => from, "to" => to}) ++
        [%{"from" => loop["id"], "to" => into["id"], "each" => true}] ++
        for([from, to] <- row(body ++ [loop]), do: %{"from" => from, "to" => to}) ++
        for([from, to] <- row([loop] ++ later ++ [last]), do: %{"from" => from, "to" => to})

    %{
      "v" => 2,
      "nodes" => [first] ++ before ++ [loop] ++ body ++ later ++ [last],
      "flows" => flows,
      "variables" => variables
    }
  end

  @entities %{
    "7" => %{
      "name" => "Nalog",
      "attributes" => [
        %{"name" => "naziv", "type" => "text", "list" => false, "required" => false},
        %{"name" => "stavke", "type" => "text", "list" => true, "required" => false}
      ]
    }
  }

  defp check(graph, entities \\ @entities) do
    with {:ok, graph} <- Graph.normalize(graph, drawn: true) do
      Check.run(graph, %{entry: Triggers.entry("manual"), entities: entities})
    end
  end

  defp numbers, do: [variable("brojevi", "number", %{"list" => true})]

  defp simple(list \\ "brojevi", item \\ "broj"),
    do: looped([], loop("petlja", list, item), [message("poruka", "{{broj}}")], [], numbers())

  describe "Graph.normalize/2" do
    test "keeps a loop with its list, its item and its two ways on" do
      graph =
        looped(
          [],
          Map.put(loop("petlja", "  brojevi ", " broj "), "visak", true),
          [message("poruka", "{{broj}}")],
          [],
          numbers()
        )

      assert {:ok, %{"nodes" => nodes, "flows" => flows}} = Graph.normalize(graph, drawn: true)

      assert Enum.at(nodes, 1) == %{
               "id" => "petlja",
               "type" => "loop",
               "list" => "brojevi",
               "item" => "broj"
             }

      assert %{"from" => "petlja", "to" => "poruka", "each" => true} in flows
      assert %{"from" => "petlja", "to" => "kraj"} in flows
    end

    test "an item has a name of its own, which an expression may use" do
      for {item, reason} <- [
            {"broj stana", :invalid},
            {"1a", :invalid},
            {"group", :invalid},
            {"empty", :invalid},
            {"", :invalid},
            {"poruka", :taken},
            {"petlja", :taken}
          ] do
        assert Graph.normalize(simple("brojevi", item), drawn: true) ==
                 {:error, {"nodes.1.item", reason}},
               item
      end

      # A variable cannot share it either.
      assert Graph.normalize(simple("brojevi", "brojevi"), drawn: true) ==
               {:error, {"variables.0.name", :taken}}

      assert Graph.normalize(
               update_in(
                 simple()["nodes"],
                 &List.update_at(&1, 1, fn loop -> %{loop | "list" => 5} end)
               ),
               drawn: true
             ) ==
               {:error, {"nodes.1.list", :invalid}}
    end

    test "two loops do not share the name of their item" do
      graph =
        looped(
          [],
          loop("prva", "brojevi", "broj"),
          [message("poruka", "{{broj}}")],
          [loop("druga", "brojevi", "broj"), message("jos", "x")],
          numbers()
        )

      # The second loop here has no body; its item is refused before that.
      assert Graph.normalize(graph, drawn: true) == {:error, {"nodes.3.item", :taken}}
    end

    test "a loop goes into its body by one flow and on by one plain flow" do
      graph = simple()

      no_body = update_in(graph["flows"], &Enum.reject(&1, fn f -> f["each"] end))
      assert Graph.normalize(no_body, drawn: true) == {:error, {"nodes.1", :loop_flows}}

      two_ways = update_in(graph["flows"], &(&1 ++ [%{"from" => "petlja", "to" => "kraj"}]))
      assert Graph.normalize(two_ways, drawn: true) == {:error, {"nodes.1", :loop_flows}}

      # Only a loop has a body.
      marked =
        update_in(graph["flows"], fn flows ->
          Enum.map(flows, &if(&1["from"] == "poruka", do: Map.put(&1, "each", true), else: &1))
        end)

      assert Graph.normalize(marked, drawn: true) == {:error, {"nodes.2", :one_flow}}
    end

    test "the body of a loop is closed" do
      graph = simple()

      empty =
        update_in(graph["flows"], fn flows ->
          Enum.map(flows, &if(&1["each"], do: %{&1 | "to" => "petlja"}, else: &1))
        end)

      assert {:error, {_path, reason}} = Graph.normalize(empty, drawn: true)
      assert reason in [:loop_empty, :unreachable]

      # A body that reaches an end by itself leaves the loop standing.
      open =
        update_in(graph["flows"], fn flows ->
          Enum.map(flows, &if(&1["from"] == "poruka", do: %{&1 | "to" => "kraj"}, else: &1))
        end)

      assert Graph.normalize(open, drawn: true) == {:error, {"nodes.1", :loop_open}}

      # Nothing but the loop leads into its body.
      entered =
        looped(
          [%{"id" => "uslov", "type" => "exclusiveGateway"}],
          loop("petlja", "brojevi", "broj"),
          [message("poruka", "{{broj}}")],
          [],
          numbers()
        )

      entered =
        update_in(entered["flows"], fn flows ->
          Enum.map(flows, fn
            %{"from" => "uslov"} = flow -> Map.put(flow, "default", true)
            flow -> flow
          end) ++ [%{"from" => "uslov", "to" => "poruka", "condition" => %{"expr" => "true"}}]
        end)

      assert Graph.normalize(entered, drawn: true) == {:error, {"nodes.2", :loop_entered}}
    end

    test "only a drawing in today's language goes through lists" do
      first = Map.drop(simple(), ["v", "variables"])
      assert Graph.normalize(first, drawn: true) == {:error, {"nodes.1.type", :invalid}}
      assert {:error, _reason} = Graph.normalize(first)
      assert {:error, _reason} = Graph.normalize(simple())
    end

    test "body/2 names the steps of a loop's body, a loop inside it with its own" do
      inner = loop("unutra", "nalog.stavke", "stavka")

      graph = %{
        "nodes" => [loop("spolja", "nalozi", "nalog"), inner, message("poruka", "x")],
        "flows" => [
          %{"from" => "spolja", "to" => "unutra", "each" => true},
          %{"from" => "unutra", "to" => "poruka", "each" => true},
          %{"from" => "poruka", "to" => "unutra"},
          %{"from" => "unutra", "to" => "spolja"},
          %{"from" => "spolja", "to" => "kraj"}
        ]
      }

      assert Graph.body(graph, "spolja") == ["poruka", "unutra"]
      assert Graph.body(graph, "unutra") == ["poruka"]
      assert Graph.body(graph, "poruka") == []
    end
  end

  describe "Check" do
    test "an item is of the type the list holds, and the loop says where it stands" do
      {:ok, graph} =
        check(
          looped(
            [],
            loop("petlja", "brojevi", "broj"),
            [message("poruka", "{{broj * 2}} ({{petlja.index}} od {{petlja.count}})")],
            [message("posle", "{{petlja.count}}")],
            numbers()
          )
        )

      assert %{"of" => %{"type" => "number"}} = Graph.node(graph, "petlja")

      names = Scope.names(graph)
      assert names["broj"] == :number
      assert names["petlja"] == {:record, %{"index" => :number, "count" => :number}, false}

      # A kept graph is read the same way again.
      assert {:ok, ^graph} = check(graph)
    end

    test "a loop inside another goes through what the outer item holds" do
      nested = fn nodes ->
        %{
          "v" => 2,
          "nodes" => nodes,
          "flows" => [
            %{"from" => "start", "to" => "spolja"},
            %{"from" => "spolja", "to" => "unutra", "each" => true},
            %{"from" => "unutra", "to" => "poruka", "each" => true},
            %{"from" => "poruka", "to" => "unutra"},
            %{"from" => "unutra", "to" => "spolja"},
            %{"from" => "spolja", "to" => "kraj"}
          ],
          "variables" => [variable("nalozi", "entity", %{"entity" => 7, "list" => true})]
        }
      end

      steps = [
        %{"id" => "start", "type" => "startEvent"},
        loop("spolja", "nalozi", "nalog"),
        loop("unutra", "nalog.stavke", "stavka"),
        message("poruka", "{{nalog.naziv}}: {{upper(stavka)}}"),
        %{"id" => "kraj", "type" => "endEvent"}
      ]

      # In whatever order the drawing lists them.
      for nodes <- [steps, Enum.reverse(steps)] do
        assert {:ok, graph} = check(nested.(nodes))
        assert Scope.names(graph)["nalog"] == {:entity, 7}
        assert Scope.names(graph)["stavka"] == :text
        assert Map.keys(graph["types"]) == ["7"]
      end
    end

    test "a loop goes through a list" do
      for {list, reason} <- [
            {"", :no_list},
            {"   ", :no_list},
            {"ukupno", {:mismatch, :list, :number}},
            {"nema", {:unknown_name, "nema"}},
            {"brojevi +", {:syntax, 9}}
          ] do
        graph =
          looped(
            [],
            loop("petlja", list, "broj"),
            [message("poruka", "x")],
            [],
            numbers() ++ [variable("ukupno", "number")]
          )

        assert {:error, {"nodes.1.list", ^reason}} = check(graph), list
      end
    end

    test "what the body says about the item is checked by its type" do
      graph =
        looped(
          [],
          loop("petlja", "brojevi", "broj"),
          [message("poruka", "{{upper(broj)}}")],
          [],
          numbers()
        )

      assert {:error, {"nodes.2.text", {:mismatch, :text, :number}}} = check(graph)

      # An item is handed out, not kept: a step cannot set it.
      graph =
        looped(
          [],
          loop("petlja", "brojevi", "broj"),
          [assign("postavi", "broj", "1")],
          [],
          numbers()
        )

      assert check(graph) == {:error, {"nodes.2.target", {:not_a_variable, "broj"}}}
    end

    test "a list that is not known yet is gone through as it comes" do
      graph =
        looped(
          [],
          loop("petlja", "group.stavke", "stavka"),
          [message("poruka", "{{stavka}}")],
          []
        )

      assert {:ok, graph} = check(graph)
      assert Scope.names(graph)["stavka"] == :any
    end

    test "items/2 reads what it can of a drawing in the making" do
      {:ok, graph} =
        Graph.normalize(
          looped([], loop("petlja", "nema", "broj"), [message("poruka", "x")], [], numbers()),
          drawn: true
        )

      assert {:error, {"nodes.1.list", {:unknown_name, "nema"}}} = Check.items(graph)
      assert {:ok, loose} = Check.items(graph, loose: true)
      assert Scope.names(loose)["broj"] == :any
    end

    test "a step adds to a list what the list holds" do
      variables =
        numbers() ++ [variable("ukupno", "number"), variable("opisi", "text", %{"list" => true})]

      body = fn step ->
        looped([step], loop("petlja", "brojevi", "broj"), [message("p", "x")], [], variables)
      end

      assert {:ok, _graph} = check(body.(assign("dodaj", "brojevi", "ukupno + 1", "append")))
      assert {:ok, _graph} = check(body.(assign("dodaj", "opisi", "Broj {{ukupno}}", "append")))

      assert check(body.(assign("dodaj", "brojevi", "\"tri\"", "append"))) ==
               {:error, {"nodes.1.value", {:mismatch, :number, :text}}}

      assert check(body.(assign("dodaj", "ukupno", "1", "append"))) ==
               {:error, {"nodes.1.target", {:mismatch, :list, :number}}}

      # A list is set whole to a list, or to nothing.
      assert {:ok, _graph} = check(body.(assign("isprazni", "brojevi", "empty")))
    end
  end

  describe "GraphEdit" do
    defp defaults, do: %{text: "Poruka", loop_item: "stavka", loop_list: "brojevi"}

    test "a new loop comes with a body of one step that leads back to it" do
      graph = Map.put(GraphEdit.new(), "variables", numbers())
      {:ok, graph} = GraphEdit.insert(graph, "f1", "loop", defaults())

      assert Graph.node(graph, "loop_1") == %{
               "id" => "loop_1",
               "type" => "loop",
               "list" => "brojevi",
               "item" => "stavka"
             }

      assert %{"action" => "message", "text" => "Poruka"} = Graph.node(graph, "message_1")

      assert Enum.map(graph["flows"], &Map.delete(&1, "key")) == [
               %{"from" => "start", "to" => "loop_1"},
               %{"from" => "loop_1", "to" => "message_1", "each" => true},
               %{"from" => "message_1", "to" => "loop_1"},
               %{"from" => "loop_1", "to" => "end"}
             ]

      assert {:ok, _graph} = check(graph)
    end

    test "its item gets a name nothing else has" do
      graph = Map.put(GraphEdit.new(), "variables", [variable("stavka", "text")])
      {:ok, graph} = GraphEdit.insert(graph, "f1", "loop", defaults())
      assert %{"item" => "stavka_2"} = Graph.node(graph, "loop_1")

      {:ok, graph} = GraphEdit.insert(graph, "f1", "loop", defaults())
      assert %{"item" => "stavka_3"} = Graph.node(graph, "loop_2")

      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "loop", %{text: "Poruka"})
      assert %{"item" => "item", "list" => ""} = Graph.node(graph, "loop_1")
    end

    test "a step goes into the body, and the last step of a body stays" do
      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "loop", defaults())
      each = Enum.find(graph["flows"], & &1["each"])

      assert GraphEdit.delete_node(graph, "message_1") == {:error, :last_in_loop}

      {:ok, graph} = GraphEdit.insert(graph, each["key"], "timer", defaults())

      assert %{"from" => "loop_1", "to" => "timer_1", "each" => true} =
               GraphEdit.flow(graph, each["key"])

      assert Graph.body(graph, "loop_1") == ["message_1", "timer_1"]

      # One of two may go: the other takes its place.
      assert {:ok, without, ["timer_1"]} = GraphEdit.delete_node(graph, "timer_1")
      assert Graph.body(without, "loop_1") == ["message_1"]

      assert {:ok, without, ["message_1"]} = GraphEdit.delete_node(graph, "message_1")
      assert Graph.body(without, "loop_1") == ["timer_1"]
    end

    test "a loop goes with its body, and what came before leads on" do
      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "loop", defaults())
      each = Enum.find(graph["flows"], & &1["each"])
      {:ok, graph} = GraphEdit.insert(graph, each["key"], "timer", defaults())

      assert {:ok, graph, removed} = GraphEdit.delete_node(graph, "loop_1")
      assert Enum.sort(removed) == ["loop_1", "message_1", "timer_1"]
      assert Enum.map(graph["nodes"], & &1["id"]) == ["start", "end"]
      assert [%{"from" => "start", "to" => "end"}] = graph["flows"]
    end

    test "a flow drawn from a loop moves where it goes on, not its body" do
      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "loop", defaults())
      {:ok, graph} = GraphEdit.retarget(graph, "f1", :new_end)
      # f1 now leads to a new end, and the loop is left for a flow to reach.
      {:ok, graph} = GraphEdit.retarget(graph, "f1", "loop_1")

      {:ok, graph} = GraphEdit.connect(graph, "loop_1", "end_1")

      assert %{"to" => "message_1"} = Enum.find(graph["flows"], & &1["each"])

      assert [%{"to" => "end_1"}] =
               Enum.filter(
                 graph["flows"],
                 &(&1["from"] == "loop_1" and not Map.has_key?(&1, "each"))
               )

      # The way into the body is needed.
      each = Enum.find(graph["flows"], & &1["each"])
      assert GraphEdit.delete_flow(graph, each["key"]) == {:error, :needed}
    end

    test "the list and the item of a loop are what its editor changes" do
      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "loop", defaults())

      {:ok, graph} =
        GraphEdit.update_node(graph, "loop_1", %{
          "list" => "nalozi",
          "item" => "nalog",
          "type" => "timer",
          "label" => "Svaki nalog"
        })

      assert Graph.node(graph, "loop_1") == %{
               "id" => "loop_1",
               "type" => "loop",
               "list" => "nalozi",
               "item" => "nalog",
               "label" => "Svaki nalog"
             }
    end
  end

  describe "a run" do
    setup do
      {_owner_account, owner} = account_with_profile!("petlja#{unique()}")
      group = group_with_members!(owner, [], %{})
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      group = Social.get_group!(group.id)
      access = Access.for_profile(owner, group)

      {:ok, nalog} =
        GroupEntities.create(group, access, %{
          "name" => "Nalog",
          "attributes" => [
            %{"name" => "naziv", "type" => "text"},
            %{"name" => "stavke", "type" => "text", "list" => true}
          ]
        })

      %{owner: owner, group: group, nalog: nalog.id}
    end

    defp draw!(ctx, graph) do
      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Proces",
          "graph" => graph
        })

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      row
    end

    # A run that has not taken a step yet, with what its variables hold.
    defp started!(ctx, row, vars \\ %{}) do
      {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => "lift"})
      instance |> Ecto.Changeset.change(vars: vars) |> Repo.update!()
    end

    # Pass after pass, as the scheduler takes a long run.
    defp finish(id, passes \\ 20)
    defp finish(id, 0), do: Repo.get!(ValueProcess, id)

    defp finish(id, passes) do
      case Engine.run(id) do
        %ValueProcess{status: :running} -> finish(id, passes - 1)
        _stopped_or_held -> Repo.get!(ValueProcess, id)
      end
    end

    defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

    defp adding(values) do
      for {value, i} <- Enum.with_index(values),
          do: assign("dodaj_#{i}", "brojevi", value, "append")
    end

    test "takes the body once for each item, and goes on after the last", ctx do
      row =
        draw!(
          ctx,
          looped(
            adding(["10", "20 + 1", "length(start.title)"]),
            loop("petlja", "brojevi", "broj"),
            [message("poruka", "{{petlja.index}}/{{petlja.count}}: {{broj * 2}}")],
            [message("posle", "kraj: {{petlja.count}}, {{broj}}|")],
            numbers()
          )
        )

      assert %ValueProcess{status: :done, vars: vars, results: results} =
               finish(started!(ctx, row).id)

      assert chat(ctx.group) == ["1/3: 20", "2/3: 42", "3/3: 8", "kraj: 3, |"]

      # The item is handed out while its turn lasts; the list stays.
      assert vars == %{"brojevi" => ["10", "21", "4"]}
      assert results["petlja"] == %{"index" => 3, "count" => 3}
    end

    test "an empty list goes straight on", ctx do
      row =
        draw!(
          ctx,
          looped(
            [],
            loop("petlja", "brojevi", "broj"),
            [message("poruka", "{{broj}}")],
            [message("posle", "nista: {{petlja.count}}")],
            numbers()
          )
        )

      assert %ValueProcess{status: :done} = finish(started!(ctx, row).id)
      assert chat(ctx.group) == ["nista: 0"]
    end

    test "reads its list once: what the body adds takes no turn", ctx do
      row =
        draw!(
          ctx,
          looped(
            adding(["1", "2"]),
            loop("petlja", "brojevi", "broj"),
            [assign("jos", "brojevi", "broj * 10", "append")],
            [message("posle", "{{join(brojevi, \" \")}}")],
            numbers()
          )
        )

      assert %ValueProcess{status: :done} = finish(started!(ctx, row).id)
      assert chat(ctx.group) == ["1 2 10 20"]

      # Taken again from the start, it reads the list as it then is.
      assert %ValueProcess{status: :done, results: %{"petlja" => %{"count" => 2}}} =
               finish(started!(ctx, row).id)
    end

    test "a long list takes several passes, and counts nothing it keeps to itself", ctx do
      row =
        draw!(
          ctx,
          looped(
            [],
            loop("petlja", "brojevi", "broj"),
            [assign("saberi", "ukupno", "ukupno + broj")],
            [message("posle", "{{ukupno}} od {{petlja.count}}")],
            numbers() ++ [variable("ukupno", "number", %{"initial" => "0"})]
          )
        )

      instance = started!(ctx, row, %{"brojevi" => Enum.map(1..200, &to_string/1)})

      # After 100 elements it gives way, due at once, for the next pass.
      assert %ValueProcess{status: :running, steps: 100, wake_at: %DateTime{}} =
               Engine.run(instance.id)

      assert %ValueProcess{status: :done, steps: steps} = finish(instance.id)
      assert steps > 400
      assert chat(ctx.group) == ["20100 od 200"]
    end

    test "a list holds 200 items at most", ctx do
      row =
        draw!(
          ctx,
          looped([], loop("petlja", "brojevi", "broj"), [message("poruka", "x")], [], numbers())
        )

      instance = started!(ctx, row, %{"brojevi" => Enum.map(1..201, &to_string/1)})

      assert %ValueProcess{
               status: :failed,
               error: %{"element" => "petlja", "reason" => "too_many_items"}
             } = finish(instance.id)

      assert chat(ctx.group) == []

      # And a step adds no more to a full one.
      row =
        draw!(
          ctx,
          looped(
            [assign("dodaj", "brojevi", "1", "append")],
            loop("petlja", "brojevi", "broj"),
            [assign("nista", "brojevi", "brojevi")],
            [],
            numbers()
          )
        )

      instance = started!(ctx, row, %{"brojevi" => Enum.map(1..200, &to_string/1)})

      assert %ValueProcess{
               status: :failed,
               error: %{"element" => "dodaj", "reason" => "too_many_items"}
             } = finish(instance.id)
    end

    test "the steps that write are held to the process's share", ctx do
      row =
        draw!(
          ctx,
          looped(
            [],
            loop("petlja", "brojevi", "broj"),
            [message("poruka", "{{broj}}")],
            [],
            numbers()
          )
        )

      # All but five of its share of the minute are taken already.
      {share, minute} = PotokIde.RateLimit.limit(:process_step)
      turn = fn -> Integer.floor_div(System.system_time(:millisecond), minute) end
      began = turn.()
      for _ <- 1..(share - 5), do: PotokIde.RateLimit.hit(:process_step, row.id)

      instance = started!(ctx, row, %{"brojevi" => Enum.map(1..10, &to_string/1)})
      held = finish(instance.id)

      # Five messages go out; the rest wait where they stand, for the next
      # minute, and the passes leave them out until then. A minute that
      # turned while the test ran says nothing.
      if turn.() == began do
        assert %ValueProcess{status: :running, element: "poruka"} = held
        assert chat(ctx.group) == ["1", "2", "3", "4", "5"]
        assert DateTime.after?(held.wake_at, DateTime.utc_now())
        assert Engine.run_due() == 0
      end
    end

    test "a body may wait: the loop stands where it was", ctx do
      row =
        draw!(
          ctx,
          %{
            "v" => 2,
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              assign("a", "brojevi", "1", "append"),
              assign("b", "brojevi", "2", "append"),
              loop("petlja", "brojevi", "broj"),
              %{
                "id" => "odluka",
                "type" => "userTask",
                "role" => "admin",
                "outcomes" => ["Da", "Ne"]
              },
              message("poruka", "{{broj}}: {{odluka.outcome}}"),
              %{"id" => "kraj", "type" => "endEvent"}
            ],
            "flows" => [
              %{"from" => "start", "to" => "a"},
              %{"from" => "a", "to" => "b"},
              %{"from" => "b", "to" => "petlja"},
              %{"from" => "petlja", "to" => "odluka", "each" => true},
              %{"from" => "odluka", "to" => "poruka", "outcome" => "Da"},
              %{"from" => "odluka", "to" => "poruka", "outcome" => "Ne"},
              %{"from" => "poruka", "to" => "petlja"},
              %{"from" => "petlja", "to" => "kraj"}
            ],
            "variables" => numbers()
          }
        )

      id = started!(ctx, row).id

      assert %ValueProcess{status: :waiting, element: "odluka", vars: %{"broj" => "1"}} =
               finish(id)

      {:ok, _instance} = Engine.complete_task(ctx.owner, id, "odluka", "Da")

      assert %ValueProcess{status: :waiting, element: "odluka", vars: %{"broj" => "2"}} =
               finish(id)

      {:ok, _instance} = Engine.complete_task(ctx.owner, id, "odluka", "Ne")
      assert %ValueProcess{status: :done} = finish(id)
      assert chat(ctx.group) == ["1: Da", "2: Ne"]
    end

    test "a loop inside a loop goes through what the outer item holds", ctx do
      row =
        draw!(
          ctx,
          %{
            "v" => 2,
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              assign("a1", "nalog.naziv", "A"),
              assign("a2", "nalog.stavke", "x", "append"),
              assign("a3", "nalog.stavke", "y", "append"),
              assign("a4", "nalozi", "nalog", "append"),
              assign("b1", "nalog.naziv", "B"),
              assign("b2", "nalog.stavke", "empty"),
              assign("b3", "nalog.stavke", "z", "append"),
              assign("b4", "nalozi", "nalog", "append"),
              loop("spolja", "nalozi", "n"),
              loop("unutra", "n.stavke", "s"),
              message("poruka", "{{n.naziv}}: {{s}} ({{unutra.index}}/{{unutra.count}})"),
              message("posle", "{{n.naziv}} gotov, {{spolja.index}}/{{spolja.count}}"),
              %{"id" => "kraj", "type" => "endEvent"}
            ],
            "flows" => [
              %{"from" => "start", "to" => "a1"},
              %{"from" => "a1", "to" => "a2"},
              %{"from" => "a2", "to" => "a3"},
              %{"from" => "a3", "to" => "a4"},
              %{"from" => "a4", "to" => "b1"},
              %{"from" => "b1", "to" => "b2"},
              %{"from" => "b2", "to" => "b3"},
              %{"from" => "b3", "to" => "b4"},
              %{"from" => "b4", "to" => "spolja"},
              %{"from" => "spolja", "to" => "unutra", "each" => true},
              %{"from" => "unutra", "to" => "poruka", "each" => true},
              %{"from" => "poruka", "to" => "unutra"},
              %{"from" => "unutra", "to" => "posle"},
              %{"from" => "posle", "to" => "spolja"},
              %{"from" => "spolja", "to" => "kraj"}
            ],
            "variables" => [
              variable("nalog", "entity", %{"entity" => ctx.nalog}),
              variable("nalozi", "entity", %{"entity" => ctx.nalog, "list" => true})
            ]
          }
        )

      assert %ValueProcess{status: :done, vars: vars} = finish(started!(ctx, row).id)

      assert chat(ctx.group) == [
               "A: x (1/2)",
               "A: y (2/2)",
               "A gotov, 1/2",
               "B: z (1/1)",
               "B gotov, 2/2"
             ]

      assert Map.keys(vars) == ["nalog", "nalozi"]
      assert [%{"naziv" => "A", "stavke" => ["x", "y"]}, %{"naziv" => "B"}] = vars["nalozi"]
    end
  end
end
