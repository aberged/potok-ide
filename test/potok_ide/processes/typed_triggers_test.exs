defmodule PotokIde.Processes.TypedTriggersTest do
  @moduledoc """
  What sets a process drawn in Potok going has a type: a process may take an
  entity of its group, which a caller hands it attribute by attribute, a
  Start button asks for in a form, and a signal carries, with the entity
  those who wait for it expect.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{
    Check,
    Engine,
    Graph,
    GroupEntities,
    Scope,
    Triggers,
    Types,
    ValueProcess
  }

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppProcess, AppProcesses, DrawnProcesses}

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

  defp call(id, process, fields, more \\ %{}),
    do:
      Map.merge(
        %{"id" => id, "type" => "callActivity", "process" => process, "fields" => fields},
        more
      )

  defp signal(id, name, entity, fields) do
    %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "signal",
      "name" => name,
      "fields" => for({field, value} <- fields, do: %{"name" => field, "value" => value})
    }
    |> then(&if(entity, do: Map.put(&1, "entity", entity), else: &1))
  end

  defp wait(id, name, entity),
    do:
      %{"id" => id, "type" => "receiveTask", "signal" => name}
      |> then(&if(entity, do: Map.put(&1, "entity", entity), else: &1))

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
    "9" => %{
      "name" => "Uplata",
      "attributes" => [
        %{"name" => "iznos", "type" => "number", "list" => false, "required" => true}
      ]
    }
  }

  defp check(graph, env) do
    with {:ok, graph} <- Graph.normalize(graph, drawn: true) do
      Check.run(graph, Map.merge(%{trigger: "manual", config: %{}, entities: @entities}, env))
    end
  end

  describe "types" do
    test "an entity takes what holds each of its attributes" do
      start = {:record, %{"broj" => :number, "from" => :text}, false}
      assert Types.fits?(start, {:entity, 8}, @entities)
      assert Types.fits?({:list, start}, {:list, {:entity, 8}}, @entities)
      refute Types.fits?({:record, %{"from" => :text}, false}, {:entity, 8}, @entities)
      refute Types.fits?({:record, %{"broj" => :text}, false}, {:entity, 8}, @entities)
      refute Types.fits?(start, {:entity, 99}, @entities)
      assert Types.fits?(:number, :number, @entities)
      refute Types.fits?(:text, :number, @entities)
    end

    test "a trigger that takes an entity hands over its attributes, each of its type" do
      definition = @entities["7"]
      assert Triggers.typed?("process") and Triggers.typed?("manual")
      assert Triggers.typed?("signal") and Triggers.typed?("value")
      refute Triggers.typed?("message") or Triggers.typed?("schedule")

      attributes = %{"naslov" => :text, "sprat" => :number, "stan" => {:entity, 8}}

      assert Triggers.entry("process", %{}, definition) ==
               {:record, Map.put(attributes, "from", :text), false}

      assert Triggers.entry("manual", %{}, definition) ==
               {:record, Map.put(attributes, "author", :text), false}

      assert Triggers.entry("signal", %{}, definition) ==
               {:record, Map.merge(attributes, %{"from" => :text, "signal" => :text}), false}

      # A value of a collection may hold more than its entity says.
      assert Triggers.entry("value", %{}, definition) == {:record, attributes, true}

      # One that takes no entity hands over what it always did.
      assert Triggers.entry("process", %{"fields" => ["kvar"]}) ==
               {:record, %{"kvar" => :text, "from" => :text}, false}

      assert Triggers.entry("message", %{}, definition) ==
               {:record, %{"text" => :text, "author" => :text}, false}
    end
  end

  describe "Graph.normalize/2" do
    test "a wait and a signal may name the entity the signal carries" do
      graph = chain([signal("javi", "subota", 9, %{"iznos" => "1"}), wait("cekaj", "uplata", 9)])
      assert {:ok, %{"nodes" => nodes}} = Graph.normalize(graph, drawn: true)
      assert %{"entity" => 9} = Enum.at(nodes, 1)
      assert %{"entity" => 9} = Enum.at(nodes, 2)

      {:ok, %{"nodes" => nodes}} =
        Graph.normalize(chain([wait("cekaj", "uplata", nil)]), drawn: true)

      refute Map.has_key?(Enum.at(nodes, 1), "entity")

      for entity <- ["9", 0, -1] do
        graph = chain([Map.put(wait("cekaj", "uplata", nil), "entity", entity)])
        assert Graph.normalize(graph, drawn: true) == {:error, {"nodes.1.entity", :invalid}}
      end
    end
  end

  describe "Check.run/2" do
    test "what the process takes is what its start holds" do
      {:ok, graph} =
        check(
          chain([
            message(
              "poruka",
              "{{start.naslov}} na {{start.sprat + 1}}, stan {{start.stan.broj}}, {{start.from}}"
            )
          ]),
          %{
            trigger: "process",
            entry_entity: 7
          }
        )

      assert Map.keys(graph["types"]) == ["7", "8"]

      assert Scope.names(graph)["start"] ==
               {:record,
                %{"naslov" => :text, "sprat" => :number, "stan" => {:entity, 8}, "from" => :text},
                false}

      assert check(chain([message("poruka", "{{start.title}}")]), %{
               trigger: "process",
               entry_entity: 7
             }) ==
               {:error, {"nodes.1.text", {:unknown_attribute, "title"}}}

      assert check(chain([message("poruka", "{{start.naslov + 1}}")]), %{
               trigger: "process",
               entry_entity: 7
             }) ==
               {:error, {"nodes.1.text", {:mismatch, :number, :text}}}
    end

    test "what it takes goes into a variable of that entity whole" do
      graph =
        chain([assign("kopija", "prijava", "start"), assign("uzmi_stan", "stan", "start.stan")], [
          %{"name" => "prijava", "type" => "entity", "entity" => 7},
          %{"name" => "stan", "type" => "entity", "entity" => 8}
        ])

      assert {:ok, _graph} = check(graph, %{trigger: "process", entry_entity: 7})

      assert check(graph, %{trigger: "process", entry_entity: 9}) ==
               {:error,
                {"nodes.1.value",
                 {:mismatch, {:entity, 7},
                  {:record, %{"iznos" => :number, "from" => :text}, false}}}}
    end

    test "the entity it takes is one the group has, on a trigger that takes one" do
      graph = chain([message("poruka", "Zdravo")])

      assert check(graph, %{trigger: "process", entry_entity: 99}) ==
               {:error, {"entry", :unknown_entity}}

      assert check(graph, %{trigger: "message", entry_entity: 7}) == {:error, {"entry", :invalid}}
      assert {:ok, %{"types" => types}} = check(graph, %{trigger: "process", entry_entity: nil})
      assert types == %{}
    end

    test "a process started by hand takes an entity its form fills in, lists and all" do
      graph = chain([message("poruka", "{{start.iznos}} od {{start.author}}")])
      assert {:ok, _graph} = check(graph, %{trigger: "manual", entry_entity: 9})

      # One that holds another entity: the form asks for that one in a group.
      assert {:ok, _graph} =
               check(chain([message("poruka", "{{start.stan.broj}}")]), %{
                 trigger: "manual",
                 entry_entity: 7
               })

      listed = %{
        "3" => %{
          "name" => "Slike",
          "attributes" => [%{"name" => "slike", "type" => "text", "list" => true}]
        }
      }

      assert {:ok, _graph} =
               check(chain([message("poruka", "{{length(start.slike)}}")]), %{
                 trigger: "manual",
                 entry_entity: 3,
                 entities: listed
               })
    end

    test "a call hands the process it calls what its entity takes" do
      callable = %{
        5 => %{attributes: @entities["7"]["attributes"], types: Map.take(@entities, ["7", "8"])}
      }

      variables = [%{"name" => "stan", "type" => "entity", "entity" => 8}]
      env = %{callable: callable}

      ok =
        call("poziv", 5, %{
          "naslov" => "Kvar: {{start.title}}",
          "sprat" => "length(start.title) + 1",
          "stan" => "stan"
        })

      assert {:ok, _graph} = check(chain([ok], variables), env)

      # What is not required may be left out.
      assert {:ok, _graph} = check(chain([call("poziv", 5, %{"naslov" => "x"})], variables), env)

      for {fields, path, reason} <- [
            {%{"sprat" => "1"}, "naslov", :required},
            {%{"naslov" => " ", "sprat" => "1"}, "naslov", :required},
            {%{"naslov" => "x", "sprat" => "start.title"}, "sprat", {:mismatch, :number, :text}},
            {%{"naslov" => "{{nema}}"}, "naslov", {:unknown_name, "nema"}},
            {%{"naslov" => "x", "stan" => "start.title"}, "stan",
             {:mismatch, {:entity, 8}, :text}},
            {%{"naslov" => "x", "sprat" => "1 +"}, "sprat", {:syntax, 3}}
          ] do
        assert check(chain([call("poziv", 5, fields)], variables), env) ==
                 {:error, {"nodes.1.fields.#{path}", reason}}
      end
    end

    test "a call to a process that takes plain fields hands over texts" do
      env = %{callable: %{5 => %{attributes: [], types: %{}}}}
      assert {:ok, _graph} = check(chain([call("poziv", 5, %{"kvar" => "{{start.title}}"})]), env)

      assert check(chain([call("poziv", 5, %{"kvar" => "{{nema}}"})]), env) ==
               {:error, {"nodes.1.fields.kvar", {:unknown_name, "nema"}}}
    end

    test "a wait brings the attributes of the entity it names" do
      graph =
        chain([
          wait("prijem", "uplata", 9),
          message("poruka", "{{prijem.iznos * 2}} od {{prijem.from}}")
        ])

      assert {:ok, checked} = check(graph, %{})
      assert Map.keys(checked["types"]) == ["9"]

      assert Scope.names(checked)["prijem"] ==
               {:record, %{"iznos" => :number, "from" => :text, "signal" => :text}, false}

      # With no entity it brings whatever came.
      open = chain([wait("prijem", "uplata", nil), message("poruka", "{{prijem.bilo_sta}}")])
      assert {:ok, _graph} = check(open, %{})

      closed = chain([wait("prijem", "uplata", 9), message("poruka", "{{prijem.bilo_sta}}")])
      assert check(closed, %{}) == {:error, {"nodes.2.text", {:unknown_attribute, "bilo_sta"}}}

      assert check(chain([wait("prijem", "uplata", 99)]), %{}) ==
               {:error, {"nodes.1.entity", :unknown_entity}}
    end

    test "a signal is sent with the entity those who wait for it expect" do
      # Nobody waits: any entity, or none.
      assert {:ok, _graph} = check(chain([signal("javi", "uplata", 9, %{"iznos" => "1"})]), %{})

      assert {:ok, _graph} =
               check(chain([signal("javi", "uplata", nil, %{"iznos" => "{{start.title}}"})]), %{})

      # Another process waits for it with an entity.
      waited = %{signals: %{"uplata" => [9]}}

      assert {:ok, _graph} =
               check(chain([signal("javi", "uplata", 9, %{"iznos" => "1"})]), waited)

      assert check(chain([signal("javi", "uplata", nil, %{"iznos" => "1"})]), waited) ==
               {:error, {"nodes.1.entity", :signal_entity}}

      assert check(chain([signal("javi", "uplata", 8, %{"broj" => "1"})]), waited) ==
               {:error, {"nodes.1.entity", :signal_entity}}

      # Another signal is nobody's business.
      assert {:ok, _graph} = check(chain([signal("javi", "drugi", nil, %{})]), waited)

      # A wait of its own counts, and so does its own start.
      own = chain([signal("javi", "uplata", nil, %{}), wait("cekaj", "uplata", 9)])
      assert check(own, %{}) == {:error, {"nodes.1.entity", :signal_entity}}

      assert check(chain([signal("javi", "uplata", nil, %{})]), %{
               trigger: "signal",
               config: %{"name" => "uplata"},
               entry_entity: 9
             }) == {:error, {"nodes.1.entity", :signal_entity}}

      # Those who wait with none take one with none.
      assert {:ok, _graph} =
               check(chain([signal("javi", "uplata", nil, %{})]), %{
                 signals: %{"uplata" => [nil, 9]}
               })
    end

    test "a signal carries the attributes of its entity, each of its type" do
      assert check(chain([signal("javi", "uplata", 9, %{})]), %{}) ==
               {:error, {"nodes.1.fields.iznos", :required}}

      assert check(chain([signal("javi", "uplata", 9, %{"iznos" => "start.title"})]), %{}) ==
               {:error, {"nodes.1.fields.iznos", {:mismatch, :number, :text}}}

      assert check(chain([signal("javi", "uplata", 9, %{"iznos" => "1", "visak" => "x"})]), %{}) ==
               {:error, {"nodes.1.fields", {:unknown_attribute, "visak"}}}

      assert {:ok, _graph} =
               check(
                 chain([signal("javi", "uplata", 9, %{"iznos" => "length(start.title)"})]),
                 %{}
               )
    end
  end

  describe "a drawn process" do
    setup do
      {_owner_account, owner} = account_with_profile!("tt#{unique()}")
      group = group_with_members!(owner, [], %{})
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      group = Social.get_group!(group.id)
      access = Access.for_profile(owner, group)

      {:ok, stan} =
        GroupEntities.create(group, access, %{
          "name" => "Stan",
          "attributes" => [%{"name" => "broj", "type" => "number"}]
        })

      {:ok, kvar} =
        GroupEntities.create(group, access, %{
          "name" => "Kvar",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"},
            %{"name" => "hitno", "type" => "boolean"},
            %{"name" => "dan", "type" => "date"},
            %{"name" => "vrsta", "type" => "choice", "options" => "voda, struja"}
          ]
        })

      {:ok, sa_stanom} =
        GroupEntities.create(group, access, %{
          "name" => "Kvar u stanu",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "stan", "type" => "entity", "entity_id" => stan.id}
          ]
        })

      %{
        owner: owner,
        group: group,
        access: access,
        kvar: kvar.id,
        stan: stan.id,
        sa_stanom: sa_stanom.id
      }
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

    defp start!(ctx, row, attrs \\ %{"title" => "lift"}) do
      {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, attrs)
      Engine.run(instance.id)
    end

    defp runs_of(row),
      do: Repo.all(from(i in ValueProcess, where: i.app_process_id == ^row.id, order_by: i.id))

    defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

    test "keeps the entity it takes, of its own group, on a trigger that takes one", ctx do
      row =
        draw!(ctx, chain([message("poruka", "{{start.naslov}}")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.kvar
        })

      assert row.entry_entity_id == ctx.kvar
      assert Map.keys(row.graph["types"]) == [to_string(ctx.kvar)]

      assert {:error, {:invalid_trigger, "entity", :invalid}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "schedule",
                 "trigger_config" => %{
                   "every" => "day",
                   "time" => "08:00",
                   "time_zone" => "Etc/UTC"
                 },
                 "name" => "Raspored",
                 "graph" => chain([message("poruka", "x")]),
                 "entry_entity_id" => ctx.kvar
               })

      assert {:error, {:invalid_trigger, "entity", :unknown_entity}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "process",
                 "name" => "Tudji",
                 "graph" => chain([message("poruka", "x")]),
                 "entry_entity_id" => 0
               })

      # A Start form asks for an entity that holds another too.
      assert {:ok, %AppProcess{}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Forma",
                 "graph" => chain([message("poruka", "x")]),
                 "entry_entity_id" => ctx.sa_stanom
               })

      # A change keeps it unless it names another, or none.
      attrs = %{"name" => "Proces", "graph" => row.graph}
      {:ok, same} = DrawnProcesses.update(ctx.owner, ctx.group, row.id, attrs, row.lock_version)
      assert same.entry_entity_id == ctx.kvar

      assert {:error, {:invalid_graph, "nodes.1.text", {:unknown_attribute, "naslov"}}} =
               DrawnProcesses.update(
                 ctx.owner,
                 ctx.group,
                 row.id,
                 Map.put(attrs, "entry_entity_id", nil),
                 same.lock_version
               )
    end

    test "an entity a process takes cannot be deleted", ctx do
      draw!(ctx, chain([message("poruka", "x")]), %{
        "trigger" => "process",
        "entry_entity_id" => ctx.kvar
      })

      assert {:error, {:in_use, ["Proces"]}} =
               GroupEntities.delete(ctx.group, ctx.access, ctx.kvar)
    end

    test "a call hands over the entity attribute by attribute, each as its type", ctx do
      callee =
        draw!(
          ctx,
          chain([
            message(
              "javi",
              "{{start.naslov}}: sprat {{start.sprat + 1}}, {{if(start.hitno, \"hitno\", \"nije hitno\")}}, {{start.dan}}, {{start.vrsta}}, zove {{start.from}}"
            )
          ]),
          %{"trigger" => "process", "entry_entity_id" => ctx.kvar, "name" => "Majstor"}
        )

      assert [%{id: id, fields: ~w(naslov sprat hitno dan vrsta), attributes: [_ | _]}] =
               DrawnProcesses.callable(ctx.group)

      assert id == callee.id

      caller =
        draw!(
          ctx,
          chain([
            call("poziv", callee.id, %{
              "naslov" => "Kvar: {{upper(start.title)}}",
              "sprat" => "length(start.title) - 1.5",
              "hitno" => "length(start.title) > 3",
              "dan" => "add_days(today(), 0)",
              "vrsta" => "struja"
            })
          ])
        )

      waiting = start!(ctx, caller)
      assert %ValueProcess{status: :waiting} = waiting

      [child] = runs_of(callee)
      today = Date.to_iso8601(Date.utc_today())

      # Handed over as plain JSON, each value as its type keeps it.
      assert child.data == %{
               "naslov" => "Kvar: LIFT",
               "sprat" => "2.5",
               "hitno" => true,
               "dan" => today,
               "vrsta" => "struja",
               "from" => "Proces"
             }

      assert %ValueProcess{status: :done} = Engine.run(child.id)
      [said] = chat(ctx.group)
      assert said =~ "Kvar: LIFT: sprat 3.5, hitno, "
      assert said =~ ", struja, zove Proces"
    end

    test "a call that does not hand over what is required is refused, and fails if a value turns out empty",
         ctx do
      callee =
        draw!(ctx, chain([message("javi", "{{start.naslov}}")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.kvar,
          "name" => "Majstor"
        })

      assert {:error, {:invalid_graph, "nodes.1.fields.naslov", :required}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Prijava",
                 "graph" => chain([call("poziv", callee.id, %{"sprat" => "1"})])
               })

      # A value of another type than the attribute's is refused the same way.
      assert {:error, {:invalid_graph, "nodes.1.fields.sprat", {:mismatch, :number, :text}}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Prijava",
                 "graph" =>
                   chain([call("poziv", callee.id, %{"naslov" => "x", "sprat" => "start.title"})])
               })

      caller =
        draw!(
          ctx,
          chain([
            call("poziv", callee.id, %{"naslov" => "{{start.text}}", "vrsta" => "{{start.title}}"})
          ])
        )

      # Required, and worked out as nothing.
      assert %ValueProcess{status: :failed, error: %{"reason" => "required"}} =
               start!(ctx, caller, %{"title" => "voda"})

      # A choice that is none of its options.
      assert %ValueProcess{status: :failed, error: %{"reason" => "not_an_option"}} =
               start!(ctx, caller, %{"title" => "gas", "text" => "Curi"})

      assert runs_of(callee) == []
    end

    test "a call hands over an entity that holds another", ctx do
      callee =
        draw!(ctx, chain([message("javi", "{{start.naslov}}, stan {{start.stan.broj}}")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.sa_stanom,
          "name" => "Majstor"
        })

      caller =
        draw!(
          ctx,
          chain(
            [
              assign("broj", "stan.broj", "12"),
              call("poziv", callee.id, %{"naslov" => "{{start.title}}", "stan" => "stan"}, %{
                "wait" => false
              })
            ],
            [%{"name" => "stan", "type" => "entity", "entity" => ctx.stan}]
          )
        )

      assert %ValueProcess{status: :done} = start!(ctx, caller)
      [child] = runs_of(callee)
      assert child.data == %{"naslov" => "lift", "stan" => %{"broj" => "12"}, "from" => "Proces"}
      assert %ValueProcess{status: :done} = Engine.run(child.id)
      assert chat(ctx.group) == ["lift, stan 12"]
    end

    test "a process started by hand takes what its form is filled in with", ctx do
      row =
        draw!(
          ctx,
          chain([
            message(
              "poruka",
              "{{start.naslov}} na {{start.sprat}}. spratu, {{start.dan}}, prijavio {{start.author}}"
            )
          ]),
          %{"entry_entity_id" => ctx.kvar}
        )

      assert {:error, {:invalid_field, "naslov", :required}} =
               DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"sprat" => "3"})

      assert {:error, {:invalid_field, "sprat", :not_a_number}} =
               DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{
                 "naslov" => "Lift",
                 "sprat" => "treći"
               })

      assert {:error, {:invalid_field, "vrsta", :not_an_option}} =
               DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{
                 "naslov" => "Lift",
                 "vrsta" => "gas"
               })

      done =
        start!(ctx, row, %{
          "naslov" => "Lift",
          "sprat" => "3",
          "hitno" => "true",
          "dan" => "2026-11-16",
          "vrsta" => "",
          "visak" => "ne ulazi"
        })

      assert %ValueProcess{status: :done} = done

      assert done.data == %{
               "naslov" => "Lift",
               "sprat" => "3",
               "hitno" => true,
               "dan" => "2026-11-16",
               "vrsta" => nil,
               "author" => ctx.owner.username
             }

      assert chat(ctx.group) == [
               "Lift na 3. spratu, 16. 11. 2026., prijavio #{ctx.owner.username}"
             ]
    end

    test "a signal carries its entity to those who wait for it and those it starts", ctx do
      waiting_process =
        draw!(
          ctx,
          chain([
            wait("prijem", "kvar", ctx.kvar),
            message(
              "poruka",
              "Stiglo: {{prijem.naslov}} ({{prijem.sprat * 2}}) od {{prijem.from}}"
            )
          ]),
          %{"name" => "Ceka"}
        )

      _started_process =
        draw!(
          ctx,
          chain([
            message(
              "poruka",
              "Krenulo: {{start.naslov}} ({{start.sprat + 1}}), signal {{start.signal}}"
            )
          ]),
          %{
            "trigger" => "signal",
            "trigger_config" => %{"name" => "kvar"},
            "entry_entity_id" => ctx.kvar,
            "name" => "Krece"
          }
        )

      sender =
        draw!(
          ctx,
          chain([
            signal("javi", "kvar", ctx.kvar, %{
              "naslov" => "{{start.title}}",
              "sprat" => "length(start.title)"
            })
          ]),
          %{"name" => "Salje"}
        )

      waiting = start!(ctx, waiting_process)
      assert %ValueProcess{status: :waiting, element: "prijem"} = waiting

      assert %ValueProcess{status: :done} = start!(ctx, sender, %{"title" => "lift"})
      Engine.run_due()
      Engine.run_due()

      assert %ValueProcess{status: :done, results: results} = Repo.get!(ValueProcess, waiting.id)

      assert %{"naslov" => "lift", "sprat" => "4", "from" => "Salje", "signal" => "kvar"} =
               results["prijem"]

      assert Enum.sort(chat(ctx.group)) == [
               "Krenulo: lift (5), signal kvar",
               "Stiglo: lift (8) od Salje"
             ]
    end

    test "a signal is sent with the entity those who wait for it expect, or the drawing is refused",
         ctx do
      waits = draw!(ctx, chain([wait("prijem", "kvar", ctx.kvar)]), %{"name" => "Ceka"})

      assert {:error, {:invalid_graph, "nodes.1.entity", :signal_entity}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "manual",
                 "name" => "Salje",
                 "graph" => chain([signal("javi", "kvar", nil, %{"naslov" => "x"})])
               })

      sender =
        draw!(ctx, chain([signal("javi", "kvar", ctx.kvar, %{"naslov" => "x"})]), %{
          "name" => "Salje"
        })

      refute DrawnProcesses.stale?(sender, ctx.group)
      assert DrawnProcesses.signal_entities(ctx.group) == %{"kvar" => [ctx.kvar]}
      assert DrawnProcesses.signal_entities(ctx.group, waits.id) == %{}

      # Whoever waits says what it waits for, and may change its mind.
      {:ok, _waits} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          waits.id,
          %{"name" => "Ceka", "graph" => chain([wait("prijem", "kvar", ctx.stan)])},
          waits.lock_version
        )

      # The sender no longer fits, and its editors are told.
      sender = Repo.get!(AppProcess, sender.id)
      assert DrawnProcesses.stale?(sender, ctx.group)
      assert %{"stale" => true} = AppProcesses.warning(sender, ctx.group)
    end

    test "a drawing whose entity changed is stale until it is saved again", ctx do
      row =
        draw!(ctx, chain([message("poruka", "{{start.naslov}}")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.kvar
        })

      refute DrawnProcesses.stale?(row, ctx.group)
      assert AppProcesses.warning(row, ctx.group) == nil

      entity = GroupEntities.get(ctx.group, ctx.kvar)

      {:ok, _changed} =
        GroupEntities.update(ctx.group, ctx.access, entity, %{
          "attributes" => [
            %{"name" => "naslov", "type" => "text"},
            %{"name" => "soba", "type" => "text"}
          ]
        })

      assert DrawnProcesses.stale?(row, ctx.group)

      assert %{"stale" => true, "missing" => [], "owner_left" => false} =
               AppProcesses.warning(row, ctx.group)

      # It still takes calls as it was saved, with the attributes it had then.
      assert [%{fields: ~w(naslov sprat hitno dan vrsta)}] = DrawnProcesses.callable(ctx.group)

      {:ok, saved} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          row.id,
          %{"name" => "Proces", "graph" => row.graph},
          row.lock_version
        )

      refute DrawnProcesses.stale?(saved, ctx.group)
      assert [%{fields: ~w(naslov soba)}] = DrawnProcesses.callable(ctx.group)
    end

    test "a caller is stale once the process it calls takes something else", ctx do
      callee =
        draw!(ctx, chain([message("javi", "x")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.kvar,
          "name" => "Majstor"
        })

      caller = draw!(ctx, chain([call("poziv", callee.id, %{"naslov" => "x"})]))
      refute DrawnProcesses.stale?(caller, ctx.group)

      {:ok, _callee} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          callee.id,
          %{"name" => "Majstor", "graph" => callee.graph, "entry_entity_id" => ctx.sa_stanom},
          callee.lock_version
        )

      # It names nothing the new entity takes amiss, so it still fits...
      refute DrawnProcesses.stale?(caller, ctx.group)

      {:ok, _callee} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          callee.id,
          %{"name" => "Majstor", "graph" => callee.graph, "entry_entity_id" => ctx.stan},
          Repo.get!(AppProcess, callee.id).lock_version
        )

      # ...until what it hands over is no attribute of what is taken.
      assert {:error, {:invalid_graph, "nodes.1.fields.naslov", :unknown_field}} =
               DrawnProcesses.update(
                 ctx.owner,
                 ctx.group,
                 caller.id,
                 %{"name" => "Proces", "graph" => caller.graph},
                 caller.lock_version
               )
    end

    test "one in the first language still calls a process that takes an entity, with texts",
         ctx do
      callee =
        draw!(ctx, chain([message("javi", "{{start.naslov}} / {{start.sprat + 1}}")]), %{
          "trigger" => "process",
          "entry_entity_id" => ctx.kvar,
          "name" => "Majstor"
        })

      first = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "call-1",
            "type" => "callActivity",
            "process" => callee.id,
            "wait" => false,
            "fields" => %{"naslov" => "{{title}}", "sprat" => "3"}
          },
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "call-1"}, %{"from" => "call-1", "to" => "kraj"}]
      }

      caller = draw!(ctx, first)
      assert %ValueProcess{status: :done} = start!(ctx, caller)
      [child] = runs_of(callee)
      assert %{"naslov" => "lift", "sprat" => "3"} = child.data
      assert %ValueProcess{status: :done} = Engine.run(child.id)
      assert chat(ctx.group) == ["lift / 4"]
    end
  end
end
