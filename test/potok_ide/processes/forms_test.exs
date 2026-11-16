defmodule PotokIde.Processes.FormsTest do
  @moduledoc """
  A form in a process drawn in Potok: a step that waits for a person to fill
  in an entity, whoever started the run or someone of a role, and hands the
  steps that follow what was filled in, each attribute as its type.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes
  alias PotokIde.Processes.{Check, Engine, Graph, GroupEntities, Scope, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  defp form(id, entity, more \\ %{}),
    do: Map.merge(%{"id" => id, "type" => "formTask", "entity" => entity}, more)

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

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
      "name" => "Kvar",
      "attributes" => [
        %{"name" => "naslov", "type" => "text", "list" => false, "required" => true},
        %{"name" => "sprat", "type" => "number", "list" => false, "required" => false}
      ]
    },
    "8" => %{
      "name" => "Obilazak",
      "attributes" => [
        %{"name" => "kvarovi", "type" => "text", "list" => true, "required" => false}
      ]
    }
  }

  defp check(graph, env \\ %{}) do
    with {:ok, graph} <- Graph.normalize(graph, drawn: true) do
      Check.run(graph, Map.merge(%{trigger: "message", config: %{}, entities: @entities}, env))
    end
  end

  describe "Graph.normalize/2" do
    test "keeps a form: its entity, who fills it in and its deadline" do
      graph =
        chain([form("prijava", 7), form("pregled", 7, %{"by" => "role", "role" => "savet"})])

      assert {:ok, %{"nodes" => [_start, prijava, pregled, _end]}} =
               Graph.normalize(graph, drawn: true)

      assert prijava == %{
               "id" => "prijava",
               "type" => "formTask",
               "entity" => 7,
               "by" => "starter"
             }

      assert pregled["role"] == "savet"

      # Only a form of a role names one.
      assert {:ok, %{"nodes" => [_start, kept, _end]}} =
               Graph.normalize(chain([form("prijava", 7, %{"role" => "savet"})]), drawn: true)

      refute Map.has_key?(kept, "role")

      assert Graph.role_refs(graph) == [{"nodes.2.role", "savet"}]
    end

    test "refuses one that is not right" do
      assert {:error, {"nodes.1.by", :invalid}} =
               Graph.normalize(chain([form("prijava", 7, %{"by" => "everyone"})]), drawn: true)

      assert {:error, {"nodes.1.role", :invalid}} =
               Graph.normalize(chain([form("prijava", 7, %{"by" => "role"})]), drawn: true)

      assert {:error, {"nodes.1.entity", :invalid}} =
               Graph.normalize(chain([form("prijava", "sedam")]), drawn: true)

      # Its deadline has a way on of its own.
      assert {:error, {"nodes.1.deadline", :no_flow}} =
               Graph.normalize(chain([form("prijava", 7, %{"deadline" => "PT1H"})]), drawn: true)
    end

    test "only a drawing of today asks a form" do
      first = chain([form("prijava", 7)]) |> Map.delete("v") |> Map.delete("variables")

      assert {:error, {"nodes.1.type", :invalid}} = Graph.normalize(first, drawn: true)
      assert {:error, {"nodes.1.type", :invalid}} = Graph.normalize(first)
    end
  end

  describe "Check.run/2" do
    test "a form brings the attributes of its entity, each of its type" do
      graph =
        chain([
          form("prijava", 7),
          message("poruka", "{{prijava.naslov}} {{prijava.sprat + 1}} {{prijava.author}}")
        ])

      assert {:ok, checked} = check(graph)
      assert Map.keys(checked["types"]) == ["7"]

      assert Scope.names(checked)["prijava"] ==
               {:record, %{"naslov" => :text, "sprat" => :number, "author" => :text}, false}

      assert {:error, {"nodes.2.text", {:unknown_attribute, "stan"}}} =
               check(chain([form("prijava", 7), message("poruka", "{{prijava.stan}}")]))
    end

    test "a form's answers fit a variable that holds its entity" do
      variables = [%{"name" => "kvar", "type" => "entity", "entity" => 7}]

      set = %{
        "id" => "pamti",
        "type" => "serviceTask",
        "action" => "assign",
        "target" => "kvar",
        "value" => "prijava"
      }

      assert {:ok, _checked} = check(chain([form("prijava", 7), set], variables))
    end

    test "a form names an entity the group has, of plain attributes" do
      assert {:error, {"nodes.1.entity", :no_entity}} =
               check(chain([%{"id" => "prijava", "type" => "formTask"}]))

      assert {:error, {"nodes.1.entity", :unknown_entity}} = check(chain([form("prijava", 99)]))
      assert {:error, {"nodes.1.entity", :not_flat}} = check(chain([form("prijava", 8)]))
    end

    test "nobody starts a scheduled process, so its form asks a role" do
      assert {:error, {"nodes.1.by", :no_starter}} =
               check(chain([form("prijava", 7)]), %{trigger: "schedule"})

      assert {:ok, _checked} =
               check(chain([form("prijava", 7, %{"by" => "role", "role" => "savet"})]), %{
                 trigger: "schedule"
               })
    end
  end

  describe "a run" do
    setup do
      {_owner_account, owner} = account_with_profile!("fo#{unique()}")
      {_member_account, member} = account_with_profile!("fo#{unique()}")

      group =
        group_with_members!(owner, [member], %{
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat
        })

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      group = Social.get_group!(group.id)

      {:ok, kvar} =
        GroupEntities.create(group, Access.for_profile(owner, group), %{
          "name" => "Kvar",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"},
            %{"name" => "hitno", "type" => "boolean"}
          ]
        })

      %{owner: owner, member: member, group: group, kvar: kvar.id}
    end

    defp draw!(ctx, graph, attrs \\ %{}) do
      {:ok, row} =
        DrawnProcesses.create(
          ctx.owner,
          ctx.group,
          Map.merge(
            %{
              "trigger" => "message",
              "trigger_config" => %{"words" => "kvar"},
              "name" => "Prijava kvara",
              "graph" => graph
            },
            attrs
          )
        )

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      row
    end

    defp post!(profile, group, content) do
      {:ok, value} =
        Social.create_value(profile, group, %{"content" => content, "content_format" => :markdown})

      value
    end

    # The run a message with the word started, taken as far as it goes.
    defp reported!(ctx, row, text \\ "kvar u liftu") do
      post!(ctx.member, ctx.group, text)

      [run] =
        Repo.all(
          from(i in ValueProcess, where: i.app_process_id == ^row.id, order_by: [desc: i.id])
        )
        |> Enum.take(1)

      Engine.run(run.id)
    end

    defp access(ctx, profile), do: Access.for_profile(profile, ctx.group)

    defp fill(ctx, profile, run, answers, element \\ "prijava") do
      Processes.complete_form(
        profile,
        ctx.group,
        access(ctx, profile),
        run.id,
        element,
        answers,
        "Europe/Belgrade"
      )
    end

    defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

    defp flush do
      receive do
        {:app_value, _group_id, _event, _payload} -> flush()
      after
        0 -> :ok
      end
    end

    test "waits for whoever started it, and nobody else", ctx do
      AppData.subscribe(ctx.group)

      row =
        draw!(
          ctx,
          chain([
            form("prijava", ctx.kvar),
            message(
              "poruka",
              "{{prijava.naslov}}, sprat {{prijava.sprat + 1}}, javlja {{prijava.author}}"
            )
          ])
        )

      run = reported!(ctx, row)
      member_id = ctx.member.id

      assert %ValueProcess{status: :waiting, element: "prijava", asks_role: nil} = run
      assert run.asks_profile_id == member_id
      assert_receive {:app_value, _group, :process, %{asks: %{profile_id: ^member_id, role: nil}}}

      assert [task] = Processes.tasks_for(ctx.member, ctx.group, access(ctx, ctx.member))
      assert %{form?: true, by_viewer?: true, kind: :message, outcomes: []} = task
      assert Enum.map(task.attributes, & &1["name"]) == ~w(naslov sprat hitno)
      assert Processes.waiting_count(ctx.member, ctx.group, access(ctx, ctx.member)) == 1

      assert Processes.form_task(ctx.member, ctx.group, access(ctx, ctx.member), run.id).id ==
               run.id

      # The owner holds every role, and still it is not theirs.
      assert Processes.tasks_for(ctx.owner, ctx.group, access(ctx, ctx.owner)) == []
      assert Processes.waiting_count(ctx.owner, ctx.group, access(ctx, ctx.owner)) == 0
      assert Processes.form_task(ctx.owner, ctx.group, access(ctx, ctx.owner), run.id) == nil

      assert {:error, :not_permitted} = fill(ctx, ctx.owner, run, %{"naslov" => "Lift"})
      assert {:error, :not_waiting} = fill(ctx, ctx.member, run, %{"naslov" => "Lift"}, "poruka")
    end

    test "takes what was filled in as the entity's types say", ctx do
      row =
        draw!(
          ctx,
          chain([
            form("prijava", ctx.kvar),
            message(
              "poruka",
              "{{prijava.naslov}}, sprat {{prijava.sprat + 1}}, javlja {{prijava.author}}"
            )
          ])
        )

      run = reported!(ctx, row)

      assert {:error, {:invalid_field, "naslov", :required}} =
               fill(ctx, ctx.member, run, %{"naslov" => "   ", "sprat" => "3"})

      assert {:error, {:invalid_field, "sprat", :not_a_number}} =
               fill(ctx, ctx.member, run, %{"naslov" => "Lift", "sprat" => "treći"})

      assert {:ok, _presented} =
               fill(ctx, ctx.member, run, %{
                 "naslov" => "  Lift stoji  ",
                 "sprat" => "3",
                 "hitno" => "true",
                 "drugo" => "ne pita se"
               })

      done = Engine.run(run.id)
      assert done.status == :done

      assert done.results["prijava"] == %{
               "naslov" => "Lift stoji",
               "sprat" => "3",
               "hitno" => true,
               "author" => ctx.member.username
             }

      assert [%{"form" => true, "element" => "prijava", "by" => by}] = done.log
      assert by == ctx.member.id
      assert "Lift stoji, sprat 4, javlja #{ctx.member.username}" in chat(ctx.group)

      assert Processes.tasks_for(ctx.member, ctx.group, access(ctx, ctx.member)) == []
      assert Processes.waiting_count(ctx.member, ctx.group, access(ctx, ctx.member)) == 0
      assert {:error, :not_waiting} = fill(ctx, ctx.member, run, %{"naslov" => "Opet"})
    end

    test "of a role waits for its people", ctx do
      row =
        draw!(
          ctx,
          chain([
            form("prijava", ctx.kvar, %{"by" => "role", "role" => "admin"}),
            message("poruka", "{{prijava.naslov}}")
          ])
        )

      run = reported!(ctx, row)

      assert %ValueProcess{status: :waiting, asks_role: "admin", asks_profile_id: nil} = run

      assert [%{form?: true, by_viewer?: false}] =
               Processes.tasks_for(ctx.owner, ctx.group, access(ctx, ctx.owner))

      assert Processes.tasks_for(ctx.member, ctx.group, access(ctx, ctx.member)) == []
      assert {:error, :not_permitted} = fill(ctx, ctx.member, run, %{"naslov" => "Lift"})
      assert {:ok, _presented} = fill(ctx, ctx.owner, run, %{"naslov" => "Lift"})

      assert Engine.run(run.id).results["prijava"]["author"] == ctx.owner.username
    end

    test "fills a variable that holds its entity", ctx do
      variables = [%{"name" => "kvar", "type" => "entity", "entity" => ctx.kvar}]

      set = %{
        "id" => "pamti",
        "type" => "serviceTask",
        "action" => "assign",
        "target" => "kvar",
        "value" => "prijava"
      }

      row =
        draw!(
          ctx,
          chain(
            [form("prijava", ctx.kvar), set, message("poruka", "Zapamćen {{kvar.naslov}}")],
            variables
          )
        )

      run = reported!(ctx, row)

      assert {:ok, _presented} =
               fill(ctx, ctx.member, run, %{"naslov" => "Bojler", "sprat" => "2"})

      done = Engine.run(run.id)
      assert done.vars["kvar"] == %{"naslov" => "Bojler", "sprat" => "2", "hitno" => nil}
      assert "Zapamćen Bojler" in chat(ctx.group)
    end

    test "asks anew each time the run comes back to it", ctx do
      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          form("prijava", ctx.kvar),
          %{"id" => "uslov", "type" => "exclusiveGateway"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "prijava"},
          %{"from" => "prijava", "to" => "uslov"},
          %{
            "from" => "uslov",
            "to" => "prijava",
            "condition" => %{"expr" => "prijava.sprat > 20"}
          },
          %{"from" => "uslov", "to" => "kraj", "default" => true}
        ]
      }

      run = reported!(ctx, draw!(ctx, graph))

      assert {:ok, _presented} =
               fill(ctx, ctx.member, run, %{"naslov" => "Lift", "sprat" => "40"})

      again = Engine.run(run.id)
      assert %ValueProcess{status: :waiting, element: "prijava"} = again
      refute Map.has_key?(again.results, "prijava")

      # The one who filled it in set the run going again: it is theirs at once.
      assert [%{by_viewer?: true}] =
               Processes.tasks_for(ctx.member, ctx.group, access(ctx, ctx.member))

      assert {:ok, _presented} = fill(ctx, ctx.member, run, %{"naslov" => "Lift", "sprat" => "4"})
      assert Engine.run(run.id).status == :done
    end

    test "goes on by its deadline, and tells whom it asked", ctx do
      AppData.subscribe(ctx.group)

      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          form("prijava", ctx.kvar, %{"deadline" => "PT1H"}),
          %{"id" => "pauza", "type" => "timer", "duration" => "PT1H"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "prijava"},
          %{"from" => "prijava", "to" => "kraj"},
          %{"from" => "prijava", "to" => "pauza", "deadline" => true},
          %{"from" => "pauza", "to" => "kraj"}
        ]
      }

      run = reported!(ctx, draw!(ctx, graph))
      assert %DateTime{} = run.wake_at
      member_id = ctx.member.id

      from(i in ValueProcess, where: i.id == ^run.id)
      |> Repo.update_all(set: [wake_at: ~U[2020-01-01 00:00:00Z]])

      flush()
      late = Engine.run(run.id)

      # It waits on the timer now, which asks nobody; whoever the form asked
      # heard that it asks no more.
      assert %ValueProcess{status: :waiting, element: "pauza", asks_profile_id: nil} = late
      assert_receive {:app_value, _group, :process, %{asks: %{profile_id: ^member_id}}}
      assert Processes.waiting_count(ctx.member, ctx.group, access(ctx, ctx.member)) == 0
      assert {:error, :not_waiting} = fill(ctx, ctx.member, run, %{"naslov" => "Kasno"})
    end

    test "that asks whoever started it fails where nobody did", ctx do
      row = draw!(ctx, chain([form("prijava", ctx.kvar)]))

      run = Engine.start_drawn_on(row, data: %{"text" => "kvar", "author" => "niko"})
      failed = Engine.run(run.id)

      assert %ValueProcess{status: :failed, error: %{"reason" => "no_starter"}} = failed
    end

    test "is not drawn on a schedule for whoever started it", ctx do
      assert {:error, {:invalid_graph, "nodes.1.by", :no_starter}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "trigger" => "schedule",
                 "trigger_config" => %{
                   "every" => "day",
                   "time" => "08:00",
                   "time_zone" => "Etc/UTC"
                 },
                 "name" => "Jutarnji obilazak",
                 "graph" => chain([form("prijava", ctx.kvar)])
               })
    end

    test "a decision keeps the role it asks, as a form does", ctx do
      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "odluka",
            "type" => "userTask",
            "role" => "admin",
            "outcomes" => ["Primljeno"]
          },
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "odluka"},
          %{"from" => "odluka", "to" => "kraj", "outcome" => "Primljeno"}
        ]
      }

      run = reported!(ctx, draw!(ctx, graph))

      assert %ValueProcess{status: :waiting, asks_role: "admin", asks_profile_id: nil} = run
      assert Processes.waiting_count(ctx.owner, ctx.group, access(ctx, ctx.owner)) == 1
      assert Processes.waiting_count(ctx.member, ctx.group, access(ctx, ctx.member)) == 0

      assert [%{form?: false, attributes: nil, outcomes: ["Primljeno"]}] =
               Processes.tasks_for(ctx.owner, ctx.group, access(ctx, ctx.owner))
    end
  end
end
