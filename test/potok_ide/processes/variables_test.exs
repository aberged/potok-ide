defmodule PotokIde.Processes.VariablesTest do
  @moduledoc """
  The variables of a process drawn in Potok: declared in its graph with the
  type of what each holds, set by a step to what an expression gives, and
  kept by every run for itself.
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

  defp assign(id, target, value),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "assign",
      "target" => target,
      "value" => value
    }

  defp variable(name, type, more \\ %{}),
    do: Map.merge(%{"name" => name, "type" => type}, more)

  # start → the steps in a row → end, in today's language.
  defp chain(steps, variables \\ []) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        steps ++ [%{"id" => "kraj", "type" => "endEvent"}]

    flows =
      nodes
      |> Enum.map(& &1["id"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to} end)

    %{"v" => 2, "nodes" => nodes, "flows" => flows, "variables" => variables}
  end

  @entities %{
    "7" => %{
      "name" => "Prijava",
      "attributes" => [
        %{"name" => "naslov", "type" => "text", "list" => false, "required" => true},
        %{"name" => "sprat", "type" => "number", "list" => false, "required" => false},
        %{
          "name" => "stan",
          "type" => "entity",
          "entity" => 8,
          "list" => false,
          "required" => false
        }
      ]
    },
    "8" => %{
      "name" => "Stan",
      "attributes" => [
        %{"name" => "broj", "type" => "number", "list" => false, "required" => false}
      ]
    },
    "9" => %{"name" => "Nevezan", "attributes" => []}
  }

  defp check(graph, entities \\ @entities) do
    with {:ok, graph} <- Graph.normalize(graph, drawn: true) do
      Check.run(graph, %{entry: Triggers.entry("manual"), entities: entities})
    end
  end

  describe "Graph.normalize/2" do
    test "a graph of today always says what it keeps, none when it keeps nothing" do
      graph = Map.delete(chain([message("poruka", "Zdravo")]), "variables")
      assert {:ok, %{"variables" => []}} = Graph.normalize(graph, drawn: true)
    end

    test "keeps each variable with the type of what it holds" do
      graph =
        chain([message("poruka", "Zdravo")], [
          variable("  ukupno ", "number", %{"initial" => " 0 ", "visak" => true}),
          variable("vrsta", "choice", %{"options" => ["voda", "struja"], "initial" => "voda"}),
          variable("prijava", "entity", %{"entity" => 7, "initial" => "x"}),
          variable("slike", "text", %{"list" => true, "initial" => "x"}),
          variable("hitno", "boolean", %{"initial" => ""})
        ])

      assert {:ok, %{"variables" => variables}} = Graph.normalize(graph, drawn: true)

      assert variables == [
               %{"name" => "ukupno", "type" => "number", "list" => false, "initial" => "0"},
               %{
                 "name" => "vrsta",
                 "type" => "choice",
                 "list" => false,
                 "options" => ["voda", "struja"],
                 "initial" => "voda"
               },
               # An entity and a list start empty.
               %{"name" => "prijava", "type" => "entity", "list" => false, "entity" => 7},
               %{"name" => "slike", "type" => "text", "list" => true},
               %{"name" => "hitno", "type" => "boolean", "list" => false}
             ]
    end

    test "a variable has a name of its own, which an expression may use" do
      for {name, reason} <- [
            {"broj stana", :invalid},
            {"1a", :invalid},
            {"a-b", :invalid},
            {"group", :invalid},
            {"empty", :invalid},
            {"from", :invalid},
            {"poruka", :taken},
            {"start", :taken}
          ] do
        graph = chain([message("poruka", "Zdravo")], [variable(name, "text")])
        assert Graph.normalize(graph, drawn: true) == {:error, {"variables.0.name", reason}}, name
      end

      graph =
        chain([message("poruka", "Zdravo")], [variable("a", "text"), variable("a", "number")])

      assert Graph.normalize(graph, drawn: true) == {:error, {"variables.1.name", :taken}}
    end

    test "a variable holds a type Potok knows, whole" do
      for {variable, path} <- [
            {variable("a", "blob"), "variables.0.type"},
            {variable("a", "choice"), "variables.0.options"},
            {variable("a", "choice", %{"options" => ["x", "x"]}), "variables.0.options"},
            {variable("a", "entity"), "variables.0.entity"},
            {variable("a", "entity", %{"entity" => "7"}), "variables.0.entity"},
            {variable("a", "text", %{"list" => "da"}), "variables.0.list"},
            {variable("a", "text", %{"initial" => String.duplicate("x", 1001)}),
             "variables.0.initial"},
            {%{"name" => "a"}, "variables.0"}
          ] do
        graph = chain([message("poruka", "Zdravo")], [variable])
        assert Graph.normalize(graph, drawn: true) == {:error, {path, :invalid}}, path
      end
    end

    test "a drawing keeps 30 variables at most" do
      many = for i <- 1..31, do: variable("v#{i}", "text")
      graph = chain([message("poruka", "Zdravo")], many)
      assert Graph.normalize(graph, drawn: true) == {:error, {"variables", :too_many}}

      assert {:ok, _graph} =
               Graph.normalize(%{graph | "variables" => Enum.take(many, 30)}, drawn: true)
    end

    test "a step that sets names a variable, or an attribute of one" do
      assert {:ok, %{"nodes" => nodes}} =
               Graph.normalize(chain([assign("postavi", " prijava.sprat ", " 3 ")]), drawn: true)

      assert %{"target" => "prijava.sprat", "op" => "set", "value" => "3"} = Enum.at(nodes, 1)

      for target <- ["", "prijava.", "a b", "lista[0]", "a-b", nil] do
        assert Graph.normalize(chain([assign("postavi", target, "3")]), drawn: true) ==
                 {:error, {"nodes.1.target", :invalid}}
      end

      graph = chain([Map.put(assign("postavi", "a", "3"), "op", "obrisi")])
      assert Graph.normalize(graph, drawn: true) == {:error, {"nodes.1.op", :invalid}}
    end

    test "only today's language sets variables" do
      first = chain([assign("postavi", "a", "3")]) |> Map.drop(["v", "variables"])
      assert Graph.normalize(first, drawn: true) == {:error, {"nodes.1.action", :invalid}}
      assert {:error, _reason} = Graph.normalize(first)
    end
  end

  describe "Scope and Check" do
    test "a variable is a name of the process, with its type" do
      {:ok, graph} =
        check(
          chain(
            [
              message(
                "poruka",
                "{{ukupno + prijava.sprat}} {{prijava.stan.broj}} {{length(slike)}}"
              )
            ],
            [
              variable("ukupno", "number"),
              variable("prijava", "entity", %{"entity" => 7}),
              variable("slike", "text", %{"list" => true})
            ]
          )
        )

      names = Scope.names(graph)
      assert names["ukupno"] == :number
      assert names["prijava"] == {:entity, 7}
      assert names["slike"] == {:list, :text}
      assert Scope.scope(graph).variables == ["ukupno", "prijava", "slike"]
    end

    test "the graph keeps the entities its variables hold, and those nest" do
      {:ok, graph} =
        check(
          chain([message("poruka", "Zdravo")], [variable("prijava", "entity", %{"entity" => 7})])
        )

      # Not the one nothing of the process names.
      assert Map.keys(graph["types"]) == ["7", "8"]
      assert graph["types"]["7"] == @entities["7"]

      {:ok, graph} = check(chain([message("poruka", "Zdravo")], [variable("a", "number")]))
      assert graph["types"] == %{}
    end

    test "a variable holds an entity the group has" do
      graph =
        chain([message("poruka", "Zdravo")], [
          variable("a", "text"),
          variable("b", "entity", %{"entity" => 99})
        ])

      assert check(graph) == {:error, {"variables.1.entity", :unknown_entity}}

      # One whose nested entity is gone is as good as gone.
      broken = Map.delete(@entities, "8")
      graph = chain([message("poruka", "Zdravo")], [variable("b", "entity", %{"entity" => 7})])
      assert check(graph, broken) == {:error, {"variables.0.entity", :unknown_entity}}
    end

    test "what a variable starts with gives what it holds" do
      ok = [
        variable("ukupno", "number", %{"initial" => "length(start.title) * 2"}),
        variable("pozdrav", "text", %{"initial" => "Zdravo, {{start.author}} ({{ukupno}})"}),
        variable("dan", "date", %{"initial" => "today()"}),
        variable("vrsta", "choice", %{"options" => ["voda"], "initial" => "voda"})
      ]

      assert {:ok, _graph} = check(chain([message("poruka", "Zdravo")], ok))

      for {variable, reason} <- [
            {variable("a", "number", %{"initial" => "start.title"}), {:mismatch, :number, :text}},
            {variable("a", "number", %{"initial" => "nema + 1"}), {:unknown_name, "nema"}},
            {variable("a", "boolean", %{"initial" => "1 +"}), {:syntax, 3}},
            {variable("a", "text", %{"initial" => "{{nema}}"}), {:unknown_name, "nema"}},
            {variable("a", "date", %{"initial" => "now()"}), {:mismatch, :date, :datetime}}
          ] do
        assert check(chain([message("poruka", "Zdravo")], [variable])) ==
                 {:error, {"variables.0.initial", reason}}
      end
    end

    test "a step sets only what the run keeps for itself" do
      variables = [variable("ukupno", "number"), variable("prijava", "entity", %{"entity" => 7})]

      for target <- ["ukupno", "prijava.sprat", "prijava.stan.broj", "prijava.stan", "prijava"] do
        value = if target in ["prijava.stan", "prijava"], do: "empty", else: "1"
        assert {:ok, _graph} = check(chain([assign("postavi", target, value)], variables)), target
      end

      for {target, reason} <- [
            {"start.title", {:not_a_variable, "start"}},
            {"group.kvarova", {:not_a_variable, "group"}},
            {"nema", {:not_a_variable, "nema"}},
            {"prijava.nema", {:unknown_attribute, "nema"}},
            {"ukupno.x", {:mismatch, :record, :number}}
          ] do
        assert check(chain([assign("postavi", target, "1")], variables)) ==
                 {:error, {"nodes.1.target", reason}}
      end
    end

    test "what a step sets gives what its target holds" do
      variables = [
        variable("ukupno", "number"),
        variable("ime", "text"),
        variable("prijava", "entity", %{"entity" => 7}),
        variable("kopija", "entity", %{"entity" => 7}),
        variable("stan", "entity", %{"entity" => 8})
      ]

      for {target, value} <- [
            {"ukupno", "ukupno + length(start.title)"},
            {"ime", "Kvar: {{start.title}} ({{ukupno}})"},
            {"ime", ""},
            {"prijava.naslov", "{{upper(start.title)}}"},
            {"prijava.stan", "stan"},
            {"kopija", "prijava"},
            {"prijava", "empty"}
          ] do
        assert {:ok, _graph} = check(chain([assign("postavi", target, value)], variables)),
               "#{target} = #{value}"
      end

      for {target, value, reason} <- [
            {"ukupno", "start.title", {:mismatch, :number, :text}},
            {"ukupno", "", {:syntax, 0}},
            {"ukupno", "nema", {:unknown_name, "nema"}},
            {"ime", "{{nema}}", {:unknown_name, "nema"}},
            {"prijava.stan", "prijava", {:mismatch, {:entity, 8}, {:entity, 7}}},
            {"prijava", "ukupno", {:mismatch, {:entity, 7}, :number}}
          ] do
        assert check(chain([assign("postavi", target, value)], variables)) ==
                 {:error, {"nodes.1.value", reason}},
               "#{target} = #{value}"
      end
    end
  end

  describe "GraphEdit" do
    test "a step that sets goes into a flow, on the first variable of the drawing" do
      {:ok, graph} = GraphEdit.insert(GraphEdit.new(), "f1", "assign", %{variable: "ukupno"})

      assert %{"action" => "assign", "target" => "ukupno", "op" => "set", "value" => ""} =
               Graph.node(graph, "assign_1")

      {:ok, graph} =
        GraphEdit.update_node(graph, "assign_1", %{
          "target" => "prijava.sprat",
          "value" => "3",
          "visak" => 1
        })

      assert %{"target" => "prijava.sprat", "value" => "3"} = node = Graph.node(graph, "assign_1")
      refute Map.has_key?(node, "visak")

      graph = GraphEdit.put_variables(graph, [variable("ukupno", "number")])

      assert {:ok, %{"variables" => [%{"name" => "ukupno"}]}} =
               Graph.normalize(graph, drawn: true)
    end
  end

  describe "a run" do
    setup do
      {_owner_account, owner} = account_with_profile!("var#{unique()}")
      group = group_with_members!(owner, [], %{})
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      group = Social.get_group!(group.id)
      access = Access.for_profile(owner, group)

      {:ok, stan} =
        GroupEntities.create(group, access, %{
          "name" => "Stan",
          "attributes" => [%{"name" => "broj", "type" => "number"}]
        })

      {:ok, prijava} =
        GroupEntities.create(group, access, %{
          "name" => "Prijava",
          "attributes" => [
            %{"name" => "naslov", "type" => "text"},
            %{"name" => "sprat", "type" => "number"},
            %{"name" => "vrsta", "type" => "choice", "options" => "voda, struja"},
            %{"name" => "stan", "type" => "entity", "entity_id" => stan.id}
          ]
        })

      %{owner: owner, group: group, prijava: prijava.id, stan: stan.id}
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

    defp start!(ctx, row, title \\ "lift") do
      {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => title})
      Engine.run(instance.id)
    end

    defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

    test "its variables start with what they are given, each after those before it", ctx do
      row =
        draw!(
          ctx,
          chain(
            [message("poruka", "{{pozdrav}} / {{duplo}} / {{hitno}} / {{vrsta}} / {{bez}}|")],
            [
              variable("ukupno", "number", %{"initial" => "length(start.title)"}),
              variable("duplo", "number", %{"initial" => "ukupno * 2.5"}),
              variable("pozdrav", "text", %{
                "initial" => "Kvar {{upper(start.title)}} ({{ukupno}})"
              }),
              variable("hitno", "boolean", %{"initial" => "ukupno > 3"}),
              variable("vrsta", "choice", %{"options" => ["voda", "struja"], "initial" => "voda"}),
              variable("bez", "number")
            ]
          )
        )

      assert %ValueProcess{status: :done, vars: vars} = start!(ctx, row)

      # Kept as plain JSON: a number as its digits.
      assert vars == %{
               "ukupno" => "4",
               "duplo" => "10",
               "pozdrav" => "Kvar LIFT (4)",
               "hitno" => true,
               "vrsta" => "voda"
             }

      # What holds nothing reads as nothing.
      assert chat(ctx.group) == ["Kvar LIFT (4) / 10 / true / voda / |"]
    end

    test "a step sets a variable to what an expression gives, each run its own", ctx do
      row =
        draw!(
          ctx,
          chain(
            [
              assign("jedan", "ukupno", "ukupno + length(start.title)"),
              assign("dva", "ukupno", "ukupno * 2"),
              assign("ime", "opis", "{{start.title}}: {{ukupno}}"),
              message("poruka", "{{opis}}")
            ],
            [variable("ukupno", "number", %{"initial" => "1"}), variable("opis", "text")]
          )
        )

      assert %ValueProcess{status: :done, vars: %{"ukupno" => "10"}} = start!(ctx, row, "lift")
      assert %ValueProcess{status: :done, vars: %{"ukupno" => "14"}} = start!(ctx, row, "struja")
      assert chat(ctx.group) == ["lift: 10", "struja: 14"]
    end

    test "an entity is filled in attribute by attribute, and read the same way", ctx do
      row =
        draw!(
          ctx,
          chain(
            [
              assign("a", "prijava.naslov", "{{upper(start.title)}}"),
              assign("b", "prijava.sprat", "3"),
              assign("c", "prijava.stan.broj", "prijava.sprat * 4"),
              assign("d", "prijava.vrsta", "struja"),
              assign("e", "kopija", "prijava"),
              assign("f", "kopija.sprat", "kopija.sprat + 1"),
              message(
                "poruka",
                "{{prijava.naslov}} sprat {{prijava.sprat}}, stan {{prijava.stan.broj}}, {{prijava.vrsta}}; kopija {{kopija.sprat}}/{{kopija.stan.broj}}"
              )
            ],
            [
              variable("prijava", "entity", %{"entity" => ctx.prijava}),
              variable("kopija", "entity", %{"entity" => ctx.prijava})
            ]
          )
        )

      assert %ValueProcess{status: :done, vars: vars, graph: graph} = start!(ctx, row)

      assert vars["prijava"] == %{
               "naslov" => "LIFT",
               "sprat" => "3",
               "vrsta" => "struja",
               "stan" => %{"broj" => "12"}
             }

      assert vars["kopija"]["sprat"] == "4"
      # The run carries the entities it was saved with.
      assert Map.keys(graph["types"]) |> Enum.sort() ==
               Enum.sort([to_string(ctx.prijava), to_string(ctx.stan)])

      assert chat(ctx.group) == ["LIFT sprat 3, stan 12, struja; kopija 4/12"]
    end

    test "a value its type does not take fails the step, with why", ctx do
      row =
        draw!(
          ctx,
          chain([assign("vrsta", "prijava.vrsta", "{{start.title}}")], [
            variable("prijava", "entity", %{"entity" => ctx.prijava})
          ])
        )

      assert %ValueProcess{
               status: :failed,
               element: "vrsta",
               error: %{"reason" => "not_an_option"}
             } =
               start!(ctx, row, "gas")

      assert %ValueProcess{status: :done} = start!(ctx, row, "voda")

      row =
        draw!(
          ctx,
          chain([message("poruka", "x")], [
            variable("a", "number", %{"initial" => "10 / (length(start.title) - 4)"})
          ])
        )

      assert %ValueProcess{
               status: :failed,
               element: "start",
               error: %{"reason" => "division_by_zero"}
             } = start!(ctx, row)
    end

    test "a run keeps so much and no more", ctx do
      row =
        draw!(
          ctx,
          chain(
            Enum.map(1..8, &assign("a#{&1}", "tekst", "{{tekst}}{{tekst}}")),
            [variable("tekst", "text", %{"initial" => String.duplicate("x", 600)})]
          )
        )

      assert %ValueProcess{status: :failed, error: %{"reason" => "too_much_data"}} =
               start!(ctx, row)
    end

    test "an entity a drawing keeps a variable of cannot be deleted", ctx do
      row =
        draw!(
          ctx,
          chain([message("poruka", "x")], [
            variable("prijava", "entity", %{"entity" => ctx.prijava})
          ])
        )

      access = Access.for_profile(ctx.owner, ctx.group)

      # Neither the one it names nor the one that nests in it.
      assert {:error, {:in_use, ["Proces"]}} =
               GroupEntities.delete(ctx.group, access, ctx.prijava)

      assert {:error, {:in_use, names}} = GroupEntities.delete(ctx.group, access, ctx.stan)
      assert Enum.sort(names) == ["Prijava", "Proces"]

      {:ok, _deleted} = DrawnProcesses.delete(ctx.owner, ctx.group, row.id)
      assert {:ok, _entity} = GroupEntities.delete(ctx.group, access, ctx.prijava)
      assert {:ok, _entity} = GroupEntities.delete(ctx.group, access, ctx.stan)
    end

    test "goes on with the entities it started with after one changed", ctx do
      row =
        draw!(
          ctx,
          chain(
            [
              assign("a", "prijava.sprat", "3"),
              %{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"},
              message("poruka", "sprat {{prijava.sprat + 1}}")
            ],
            [variable("prijava", "entity", %{"entity" => ctx.prijava})]
          )
        )

      waiting = start!(ctx, row)
      assert %ValueProcess{status: :waiting, element: "cekaj"} = waiting

      access = Access.for_profile(ctx.owner, ctx.group)
      entity = GroupEntities.get(ctx.group, ctx.prijava)

      {:ok, _changed} =
        GroupEntities.update(ctx.group, access, entity, %{
          "attributes" => [%{"name" => "naslov", "type" => "text"}]
        })

      waiting
      |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
      |> Repo.update!()

      assert %ValueProcess{status: :done} = Engine.run(waiting.id)
      assert chat(ctx.group) == ["sprat 4"]

      # The drawing no longer fits the entity, and says so when it is saved.
      assert {:error, {:invalid_graph, "nodes.1.target", {:unknown_attribute, "sprat"}}} =
               DrawnProcesses.update(
                 ctx.owner,
                 ctx.group,
                 row.id,
                 %{"name" => "Proces", "graph" => row.graph},
                 row.lock_version
               )
    end
  end
end
