defmodule PotokIde.Processes.ExpressionsTest do
  @moduledoc """
  A process drawn in today's language (`"v" => 2`): its texts and conditions
  are expressions over the names it holds, checked when it is saved and run
  on what a run holds; a drawing in the first language is turned into it
  saying the same.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{
    Check,
    Engine,
    Expr,
    Graph,
    GroupField,
    Legacy,
    Scope,
    Triggers,
    ValueProcess
  }

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.DrawnProcesses

  defp unique, do: System.unique_integer([:positive])

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  # start → the steps in a row → end, in today's language.
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

  # A fault by hand goes one way when its title is long, another otherwise.
  defp branching(expression) do
    %{
      "v" => 2,
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "uslov", "type" => "exclusiveGateway"},
        message("dug", "Dug naslov: {{upper(start.title)}}"),
        message("kratak", "Kratak naslov ({{length(start.title)}})"),
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "uslov"},
        %{"from" => "uslov", "to" => "dug", "condition" => %{"expr" => expression}},
        %{"from" => "uslov", "to" => "kratak", "default" => true},
        %{"from" => "dug", "to" => "kraj"},
        %{"from" => "kratak", "to" => "kraj"}
      ]
    }
  end

  describe "Graph.normalize/2" do
    test "only a drawn process speaks today's language" do
      graph = chain([message("poruka", "Zdravo")])
      assert {:ok, %{"v" => 2, "zone" => "Etc/UTC"}} = Graph.normalize(graph, drawn: true)
      assert Graph.normalize(graph) == {:error, {"v", :invalid}}
      assert Graph.normalize(%{graph | "v" => 3}, drawn: true) == {:error, {"v", :invalid}}
    end

    test "an id is a name an expression may use" do
      for id <- ["poruka-1", "Poruka", "1poruka"] do
        assert Graph.normalize(chain([message(id, "Zdravo")]), drawn: true) ==
                 {:error, {"nodes.1.id", :invalid}}
      end

      for id <- Scope.reserved() do
        assert Graph.normalize(chain([message(id, "Zdravo")]), drawn: true) ==
                 {:error, {"nodes.1.id", :reserved}}
      end

      assert {:ok, _graph} = Graph.normalize(chain([message("poruka_1", "Zdravo")]), drawn: true)
    end

    test "a condition is one expression" do
      assert {:ok, %{"flows" => flows}} =
               Graph.normalize(branching("  length(start.title) > 5 "), drawn: true)

      assert %{"condition" => %{"expr" => "length(start.title) > 5"}} = Enum.at(flows, 1)

      # A comparison of the first language is not one.
      old = %{"field" => "title", "op" => "=", "value" => "a"}
      graph = branching("true")
      flows = List.update_at(graph["flows"], 1, &%{&1 | "condition" => old})

      assert Graph.normalize(%{graph | "flows" => flows}, drawn: true) ==
               {:error, {"flows.1.condition", :invalid}}

      assert Graph.normalize(branching(" "), drawn: true) ==
               {:error, {"flows.1.condition", :invalid}}
    end

    test "keeps its time zone, and what was written into it" do
      graph =
        chain([message("poruka", "Zdravo")])
        |> Map.merge(%{
          "zone" => "Europe/Belgrade",
          "entry" => %{"type" => "any"},
          "types" => %{}
        })

      assert {:ok, %{"zone" => "Europe/Belgrade", "entry" => %{"type" => "any"}, "types" => %{}}} =
               Graph.normalize(graph, drawn: true)

      assert Graph.normalize(%{graph | "zone" => "Nigde/Nista"}, drawn: true) ==
               {:error, {"zone", :invalid}}
    end
  end

  describe "Scope" do
    test "names what a graph holds, each with its type" do
      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "odluka", "type" => "userTask"},
          %{"id" => "poziv", "type" => "callActivity", "wait" => true},
          %{"id" => "bez_cekanja", "type" => "callActivity", "wait" => false},
          %{"id" => "prijem", "type" => "receiveTask"},
          message("poruka", "x")
        ],
        "entry" => Triggers.entry("manual") |> PotokIde.Processes.Types.json()
      }

      names = Scope.names(graph)

      assert names["start"] ==
               {:record, %{"title" => :text, "text" => :text, "author" => :text}, false}

      assert {:record, %{"outcome" => :text, "by" => :text, "comment" => :text}, false} =
               names["odluka"]

      assert names["poziv"] == {:record, %{"outcome" => :text}, true}
      assert names["prijem"] == {:record, %{"from" => :text, "signal" => :text}, true}
      assert names["group"] == {:record, %{}, true}
      refute Map.has_key?(names, "bez_cekanja")
      refute Map.has_key?(names, "poruka")
    end

    test "writes a field as an expression names it" do
      assert Scope.path("start", "naslov") == "start.naslov"
      assert Scope.path("group", "broj-kvarova") == ~s|group["broj-kvarova"]|
      assert Scope.path("group", "2024") == ~s|group["2024"]|
      assert Scope.path("start", ~s|na"vod|) == ~S|start["na\"vod"]|

      for field <- ["naslov", "broj-kvarova", ~s|na"vod|, "a\\b"] do
        {:ok, tree} = Expr.parse(Scope.path("start", field))
        assert Expr.eval(tree, %{"start" => %{field => "tu"}}) == {:ok, "tu"}
      end
    end
  end

  describe "Check.run/2" do
    defp check(graph, trigger \\ "manual", config \\ %{}) do
      {:ok, graph} = Graph.normalize(graph, drawn: true)
      Check.run(graph, %{entry: Triggers.entry(trigger, config)})
    end

    test "writes what the trigger hands a run into the graph" do
      assert {:ok, graph} = check(chain([message("poruka", "Kvar: {{start.title}}")]))
      assert graph["types"] == %{}

      assert PotokIde.Processes.Types.of(graph["entry"]) ==
               {:record, %{"title" => :text, "text" => :text, "author" => :text}, false}
    end

    test "names the text that names what is not there" do
      assert check(chain([message("poruka", "Kvar: {{title}}")])) ==
               {:error, {"nodes.1.text", {:unknown_name, "title"}}}

      assert check(chain([message("poruka", "Kvar: {{start.naslov}}")])) ==
               {:error, {"nodes.1.text", {:unknown_attribute, "naslov"}}}

      # Where the expression ends with more due, counted in the whole text.
      assert check(chain([message("poruka", "Kvar: {{start.title +}}")])) ==
               {:error, {"nodes.1.text", {:syntax, 21}}}

      assert check(chain([message("poruka", "{{start.title + 1}}")])) ==
               {:error, {"nodes.1.text", {:mismatch, :number, :text}}}
    end

    test "reads every text of every kind of step" do
      steps = [
        %{
          "id" => "podgrupa",
          "type" => "serviceTask",
          "action" => "subgroup",
          "name" => "{{nema1}}"
        },
        %{
          "id" => "push",
          "type" => "serviceTask",
          "action" => "push",
          "role" => "admin",
          "text" => "{{nema2}}"
        },
        %{
          "id" => "polje",
          "type" => "serviceTask",
          "action" => "set",
          "field" => "x",
          "value" => "{{nema3}}"
        },
        %{
          "id" => "signal",
          "type" => "serviceTask",
          "action" => "signal",
          "name" => "subota",
          "fields" => [
            %{"name" => "a", "value" => "ok"},
            %{"name" => "b", "value" => "{{nema4}}"}
          ]
        },
        %{
          "id" => "poziv",
          "type" => "callActivity",
          "process" => 1,
          "fields" => %{"kvar" => "{{nema5}}"}
        }
      ]

      for {step, i} <- Enum.with_index(steps) do
        key =
          case step do
            %{"action" => "subgroup"} -> "name"
            %{"action" => "push"} -> "text"
            %{"action" => "set"} -> "value"
            %{"action" => "signal"} -> "fields.1.value"
            %{"type" => "callActivity"} -> "fields.kvar"
          end

        assert check(chain([step])) ==
                 {:error, {"nodes.1.#{key}", {:unknown_name, "nema#{i + 1}"}}}
      end
    end

    test "a condition must be true or false" do
      assert {:ok, _graph} = check(branching(~s|start.title = "lift"|))

      assert check(branching("length(start.title)")) ==
               {:error, {"flows.1.condition", {:mismatch, :boolean, :number}}}

      assert check(branching("nema > 1")) ==
               {:error, {"flows.1.condition", {:unknown_name, "nema"}}}
    end

    test "what Potok knows no type of goes anywhere" do
      graph = chain([message("poruka", "{{start.bilo_sta}} {{group.kvarova + 1}} {{start.x.y}}")])
      assert {:ok, _graph} = check(graph, "value")
      assert {:error, {"nodes.1.text", {:unknown_attribute, "bilo_sta"}}} = check(graph, "manual")
    end

    test "a graph in the first language comes back as it is" do
      graph = %{"nodes" => [], "flows" => []}
      assert Check.run(graph, %{entry: :any}) == {:ok, graph}
    end
  end

  describe "Graph.upgrade/1" do
    @first %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "set-1",
          "type" => "serviceTask",
          "action" => "set",
          "field" => "kvarova",
          "op" => "add",
          "value" => "1"
        },
        %{
          "id" => "razgovor",
          "type" => "serviceTask",
          "action" => "subgroup",
          "name" => "Kvar: {{title}}",
          "admins" => ["owner"]
        },
        %{"id" => "task-1", "type" => "userTask", "role" => "admin", "outcomes" => ["Da", "Ne"]},
        %{"id" => "gateway-1", "type" => "exclusiveGateway"},
        %{
          "id" => "message-1",
          "type" => "serviceTask",
          "action" => "message",
          "in" => "razgovor",
          "text" =>
            "{{ task-1.by }} kaže {{task-1.outcome}}: kvar {{group.kvarova}}, {{group.broj-zgrade}}"
        },
        %{
          "id" => "call-1",
          "type" => "callActivity",
          "process" => 7,
          "wait" => true,
          "fields" => %{"kvar" => "{{title}} ({{author}})"}
        },
        %{
          "id" => "group",
          "type" => "serviceTask",
          "action" => "push",
          "role" => "admin",
          "text" => "{{call-1.outcome}}"
        },
        %{
          "id" => "signal-1",
          "type" => "serviceTask",
          "action" => "signal",
          "name" => "gotovo",
          "fields" => [%{"name" => "sta", "value" => "{{title}}"}]
        },
        %{"id" => "end", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "set-1"},
        %{"from" => "set-1", "to" => "razgovor"},
        %{"from" => "razgovor", "to" => "task-1"},
        %{"from" => "task-1", "to" => "gateway-1", "outcome" => "Da"},
        %{"from" => "task-1", "to" => "end", "outcome" => "Ne"},
        %{
          "from" => "gateway-1",
          "to" => "message-1",
          "condition" => %{"field" => "group.kvarova", "op" => ">", "value" => "10"}
        },
        %{
          "from" => "gateway-1",
          "to" => "call-1",
          "condition" => %{"field" => "text", "op" => "empty"}
        },
        %{"from" => "gateway-1", "to" => "group", "default" => true},
        %{"from" => "message-1", "to" => "end"},
        %{"from" => "call-1", "to" => "signal-1"},
        %{"from" => "group", "to" => "end"},
        %{"from" => "signal-1", "to" => "end"}
      ]
    }

    test "ids become names, and what led to them follows" do
      {graph, ids} = Graph.upgrade(@first)

      assert graph["v"] == 2
      assert ids["task-1"] == "task_1"
      assert ids["start"] == "start"
      # A word expressions keep steps aside.
      assert ids["group"] == "group_1"

      assert Enum.map(graph["nodes"], & &1["id"]) ==
               ~w(start set_1 razgovor task_1 gateway_1 message_1 call_1 group_1 signal_1 end)

      assert %{"from" => "task_1", "to" => "gateway_1", "outcome" => "Da"} =
               Enum.at(graph["flows"], 3)

      assert %{"in" => "razgovor"} = Graph.node(graph, "message_1")
    end

    test "two ids that would become one stay two" do
      {_graph, ids} =
        Graph.upgrade(%{
          "nodes" => [
            %{"id" => "start", "type" => "startEvent"},
            %{"id" => "a-1", "type" => "endEvent"},
            %{"id" => "a_1", "type" => "endEvent"}
          ],
          "flows" => []
        })

      assert ids["a-1"] != ids["a_1"]
      assert MapSet.new(Map.values(ids)) |> MapSet.size() == 3
    end

    test "fields are read where today's language keeps them" do
      {graph, _ids} = Graph.upgrade(@first)

      assert Graph.node(graph, "razgovor")["name"] == "Kvar: {{start.title}}"

      assert Graph.node(graph, "message_1")["text"] ==
               ~s|{{task_1.by}} kaže {{task_1.outcome}}: kvar {{group.kvarova}}, {{group["broj-zgrade"]}}|

      assert Graph.node(graph, "call_1")["fields"] == %{
               "kvar" => "{{start.title}} ({{start.author}})"
             }

      assert Graph.node(graph, "group_1")["text"] == "{{call_1.outcome}}"
      assert [%{"value" => "{{start.title}}"}] = Graph.node(graph, "signal_1")["fields"]

      assert %{"condition" => %{"expr" => ~s|group.kvarova > "10"|}} = Enum.at(graph["flows"], 5)
      assert %{"condition" => %{"expr" => "empty(start.text)"}} = Enum.at(graph["flows"], 6)
    end

    test "what it gives is a drawing that can be saved, and one of today stays as it is" do
      {graph, _ids} = Graph.upgrade(@first)
      assert {:ok, normalized} = Graph.normalize(graph, drawn: true)
      assert {:ok, checked} = Check.run(normalized, %{entry: Triggers.entry("manual")})
      assert Graph.upgrade(checked) == {checked, Map.new(checked["nodes"], &{&1["id"], &1["id"]})}
    end

    test "flows keep the keys an editor gave them" do
      keyed =
        update_in(
          @first["flows"],
          &Enum.with_index(&1, fn flow, i -> Map.put(flow, "key", "f#{i}") end)
        )

      {graph, _ids} = Graph.upgrade(keyed)
      assert Enum.map(graph["flows"], & &1["key"]) == Enum.map(0..11, &"f#{&1}")
    end

    test "a text says the same in both languages" do
      # As a run of the first language reads: its fields beside what its
      # waits brought back, and the group's fields under `group`.
      old = %{
        "title" => "Lift",
        "broj" => 12,
        "cena" => 10.5,
        "hitno" => true,
        "broj-zgrade" => "7a",
        "task-1" => %{"outcome" => "Da", "by" => "mika"},
        "group" => %{"kvarova" => "11", "broj-zgrade" => "4"}
      }

      # And as one of today's does: by name.
      new = %{
        "start" => Map.take(old, ~w(title broj cena hitno broj-zgrade)),
        "task_1" => old["task-1"],
        "group" => old["group"]
      }

      texts = [
        "Kvar: {{title}}",
        "  {{title}} / {{broj}} / {{cena}} / {{hitno}} / {{nema}}  ",
        "{{task-1.outcome}} ({{ task-1.by }}), ukupno {{group.kvarova}}",
        "{{broj-zgrade}} i {{group.broj-zgrade}}",
        "{{task-1.nema.dalje}}|{{group}}|{{task-1}}",
        "bez polja"
      ]

      for text <- texts do
        {graph, _ids} =
          Graph.upgrade(%{
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              %{"id" => "task-1", "type" => "userTask"},
              message("poruka", text)
            ],
            "flows" => []
          })

        {:ok, parts} = Expr.template(Graph.node(graph, "poruka")["text"])
        assert Expr.render(parts, new) == {:ok, Legacy.render(text, old)}, text
      end
    end

    test "a condition holds in both languages alike" do
      old = %{
        "title" => " Lift ",
        "broj" => 12,
        "sprat" => "3",
        "prazno" => " ",
        "hitno" => true,
        "group" => %{"kvarova" => "11"}
      }

      new = %{"start" => Map.delete(old, "group"), "group" => old["group"]}

      conditions = [
        {"title", "=", "Lift"},
        {"title", "=", "lift"},
        {"title", "!=", "Lift"},
        {"broj", "=", "12.0"},
        {"broj", "=", 12},
        {"broj", ">", "9"},
        {"broj", "<", 9},
        {"sprat", ">", "10"},
        {"sprat", "<", "10"},
        {"sprat", "=", "3.0"},
        {"group.kvarova", ">", "10"},
        {"group.kvarova", "=", "11"},
        {"hitno", "=", true},
        {"hitno", "=", "true"},
        {"hitno", "!=", false},
        {"nema", "=", ""},
        {"nema", "!=", "x"},
        {"nema", "<", "5"},
        {"title", "=", ~s|Li"ft|}
      ]

      for {field, op, value} <- conditions do
        condition = %{"field" => field, "op" => op, "value" => value}

        {graph, _ids} =
          Graph.upgrade(%{
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              %{"id" => "kraj", "type" => "endEvent"}
            ],
            "flows" => [%{"from" => "start", "to" => "kraj", "condition" => condition}]
          })

        [%{"condition" => %{"expr" => expression}}] = graph["flows"]
        {:ok, tree} = Expr.parse(expression)
        assert Expr.eval(tree, new) == {:ok, Legacy.holds?(condition, old)}, expression
      end

      for field <- ["prazno", "nema", "title"] do
        condition = %{"field" => field, "op" => "empty"}
        {:ok, tree} = Expr.parse("empty(start.#{field})")
        assert Expr.eval(tree, new) == {:ok, Legacy.holds?(condition, old)}, field
      end
    end
  end

  describe "a drawn process" do
    setup do
      {_owner_account, owner} = account_with_profile!("ex#{unique()}")
      group = group_with_members!(owner, [], %{})
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      %{owner: owner, group: Social.get_group!(group.id)}
    end

    defp draw!(ctx, graph, attrs \\ %{}) do
      {:ok, row} =
        DrawnProcesses.create(
          ctx.owner,
          ctx.group,
          Map.merge(%{"trigger" => "manual", "name" => "Proces", "graph" => graph}, attrs)
        )

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      row
    end

    defp start!(ctx, row, title) do
      {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => title})
      Engine.run(instance.id)
    end

    defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

    test "is kept with what its trigger hands it written in", ctx do
      row = draw!(ctx, chain([message("poruka", "Kvar: {{start.title}}")]))

      assert %{"v" => 2, "zone" => "Etc/UTC", "types" => %{}} = row.graph

      assert %{"type" => "record", "fields" => %{"title" => %{"type" => "text"}}} =
               row.graph["entry"]
    end

    test "is refused when it names what it does not have", ctx do
      assert {:error, {:invalid_graph, "nodes.1.text", {:unknown_name, "title"}}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Proces",
                 "graph" => chain([message("poruka", "Kvar: {{title}}")])
               })

      row = draw!(ctx, chain([message("poruka", "Kvar: {{start.title}}")]))

      assert {:error, {:invalid_graph, "flows.1.condition", {:mismatch, :boolean, :text}}} =
               DrawnProcesses.update(
                 ctx.owner,
                 ctx.group,
                 row.id,
                 %{"name" => "Proces", "graph" => branching("start.title")},
                 row.lock_version
               )
    end

    test "is checked against the trigger it has", ctx do
      graph = chain([message("poruka", "{{start.name}}")])

      assert {:error, {:invalid_graph, "nodes.1.text", {:unknown_attribute, "name"}}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Proces",
                 "graph" => graph
               })

      assert {:ok, _row} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "subgroup",
                 "name" => "Proces",
                 "graph" => graph
               })
    end

    test "puts what its expressions give into its texts, and goes the way a condition says",
         ctx do
      row = draw!(ctx, branching("length(start.title) > 5"))

      assert %ValueProcess{status: :done} = start!(ctx, row, "lift")
      assert %ValueProcess{status: :done} = start!(ctx, row, "lift u kvaru")
      assert chat(ctx.group) == ["Kratak naslov (4)", "Dug naslov: LIFT U KVARU"]
    end

    test "counts with the fields of the group, as numbers", ctx do
      Repo.insert!(%GroupField{group_id: ctx.group.id, name: "kvarova", value: "9"})
      Repo.insert!(%GroupField{group_id: ctx.group.id, name: "broj-zgrade", value: "4"})

      row =
        draw!(
          ctx,
          chain([
            message(
              "poruka",
              ~s|Ovo je kvar {{group.kvarova + 1}} u zgradi {{group["broj-zgrade"]}}, {{if(group.kvarova >= 9, "mnogo", "malo")}}.|
            )
          ])
        )

      assert %ValueProcess{status: :done} = start!(ctx, row, "lift")
      assert chat(ctx.group) == ["Ovo je kvar 10 u zgradi 4, mnogo."]
    end

    test "fails where an expression cannot be worked out, with why", ctx do
      row = draw!(ctx, chain([message("poruka", "{{10 / (length(start.title) - 4)}}")]))

      assert %ValueProcess{status: :failed, element: "poruka", error: error} =
               start!(ctx, row, "lift")

      assert error == %{"element" => "poruka", "reason" => "division_by_zero"}

      row = draw!(ctx, chain([message("poruka", "{{group.kvarova + 1}}")]))
      Repo.insert!(%GroupField{group_id: ctx.group.id, name: "kvarova", value: "mnogo"})

      assert %ValueProcess{status: :failed, error: %{"reason" => "not_a_number"}} =
               start!(ctx, row, "lift")
    end

    test "hands a called process its fields, and reads how it ended", ctx do
      callee =
        draw!(ctx, chain([message("javi", "Majstor za: {{start.kvar}}, zove {{start.from}}")]), %{
          "trigger" => "process",
          "trigger_config" => %{"fields" => "kvar"},
          "name" => "Majstor"
        })

      caller =
        draw!(
          ctx,
          chain([
            %{
              "id" => "poziv",
              "type" => "callActivity",
              "process" => callee.id,
              "fields" => %{"kvar" => "{{upper(start.title)}}"}
            },
            message("ishod", "Završeno: {{poziv.outcome}}, {{poziv.kvar}}")
          ])
        )

      waiting = start!(ctx, caller, "lift")
      assert %ValueProcess{status: :waiting, element: "poziv"} = waiting

      [child] = Repo.all(from(i in ValueProcess, where: i.app_process_id == ^callee.id))
      assert child.data == %{"kvar" => "LIFT", "from" => "Proces"}
      assert %ValueProcess{status: :done} = Engine.run(child.id)
      assert %ValueProcess{status: :done} = Engine.run(waiting.id)

      assert chat(ctx.group) == ["Majstor za: LIFT, zove Proces", "Završeno: kraj, LIFT"]
    end

    test "one in the first language is kept and run as it comes", ctx do
      first = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          message("poruka-1", "Kvar: {{title}}"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "poruka-1"},
          %{"from" => "poruka-1", "to" => "kraj"}
        ]
      }

      row = draw!(ctx, first)
      refute Map.has_key?(row.graph, "v")
      assert %ValueProcess{status: :done} = start!(ctx, row, "lift")
      assert chat(ctx.group) == ["Kvar: lift"]
    end

    test "a run keeps the language it started with", ctx do
      first = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"},
          message("poruka", "Kvar: {{title}}"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "cekaj"},
          %{"from" => "cekaj", "to" => "poruka"},
          %{"from" => "poruka", "to" => "kraj"}
        ]
      }

      row = draw!(ctx, first)
      waiting = start!(ctx, row, "lift")
      assert %ValueProcess{status: :waiting, element: "cekaj"} = waiting

      {upgraded, _ids} = Graph.upgrade(first)

      {:ok, _row} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          row.id,
          %{"name" => "Proces", "graph" => upgraded},
          row.lock_version
        )

      waiting
      |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
      |> Repo.update!()

      # The run under way ends in the language it started with, and a new
      # one starts in the drawing's new one.
      assert %ValueProcess{status: :done, graph: old} = Engine.run(waiting.id)
      refute Map.has_key?(old, "v")
      assert chat(ctx.group) == ["Kvar: lift"]

      assert %ValueProcess{status: :waiting, graph: %{"v" => 2}} =
               start!(ctx, Repo.reload!(row), "struja")
    end
  end
end
