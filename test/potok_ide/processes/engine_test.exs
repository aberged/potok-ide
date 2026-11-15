defmodule PotokIde.Processes.EngineTest do
  @moduledoc """
  An app's process runs: a value starts an instance, its elements write once
  each, people decide its tasks, deadlines and timers wake it, and what fails
  stops for an editor to take up again.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, Group, Value}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("en#{unique()}")
    {member_account, member} = account_with_profile!("en#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, _role} = Social.assign_group_member_role(owner, group, owner.id, savet.key)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: Social.get_group!(group.id),
      savet: savet.key
    }
  end

  # The plan's example: a request comes in, the chat hears of it, it gets a
  # sub-group, and the council decides, reminded every seven days.
  defp molbe(savet) do
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
          "admins" => ["triggered_by", savet]
        },
        %{
          "id" => "odluka",
          "type" => "userTask",
          "role" => savet,
          "outcomes" => ["odobri", "odbij"],
          "deadline" => "P7D"
        },
        %{
          "id" => "podsetnik",
          "type" => "serviceTask",
          "action" => "push",
          "role" => savet,
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

  # start → `middle` elements in a row → end.
  defp chain(middle) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        middle ++ [%{"id" => "kraj", "type" => "endEvent"}]

    ids = Enum.map(nodes, & &1["id"])

    %{
      "nodes" => nodes,
      "flows" =>
        ids
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> %{"from" => a, "to" => b} end)
    }
  end

  defp message(id, text),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "message",
      "in" => "app",
      "text" => text
    }

  defp save!(ctx, graph, extra \\ %{}) do
    revision =
      case AppData.get_config(ctx.group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    rule = Map.merge(%{"process" => %{"name" => "Prijem molbi", "graph" => graph}}, extra)

    {:ok, _config} =
      AppData.save_config(ctx.owner, ctx.group, nil, %{"rules" => %{"molbe" => rule}}, revision)
  end

  defp send!(ctx, data) do
    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", data)

    Repo.get_by!(ValueProcess, value_id: value.id)
  end

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  defp due_now!(instance) do
    instance
    |> Ecto.Changeset.change(wake_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Repo.update!()
  end

  describe "a new value" do
    test "starts one instance, due at once, set off by its author", ctx do
      save!(ctx, molbe(ctx.savet))
      instance = send!(ctx, %{"naslov" => "Kanalizacija"})

      assert %ValueProcess{status: :running, element: "start", steps: 0} = instance
      assert instance.started_by_id == ctx.member.id
      assert instance.triggered_by_id == ctx.member.id
      assert instance.graph["nodes"] |> length() == 8
      assert DateTime.compare(instance.wake_at, DateTime.utc_now()) != :gt
    end

    test "of an anonymous collection starts it set off by nobody", ctx do
      save!(ctx, chain([message("primljeno", "Stigla je molba.")]), %{"anonymous" => true})
      instance = send!(ctx, %{"naslov" => "Tajna"})

      assert instance.started_by_id == nil and instance.triggered_by_id == nil

      Engine.run(instance.id)
      [value] = Social.list_group_values(ctx.group)
      assert value.managed["process"]["triggered_by"] == nil
    end

    test "starts nothing where the process has no graph", ctx do
      {:ok, _config} =
        AppData.save_config(
          ctx.owner,
          ctx.group,
          nil,
          %{"rules" => %{"molbe" => %{"process" => %{"name" => "Prijem"}}}},
          0
        )

      {:ok, _value, _rule} =
        AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{})

      assert Repo.all(ValueProcess) == []
    end
  end

  describe "the example" do
    test "runs from the request to the council's decision, each step once", ctx do
      save!(ctx, molbe(ctx.savet))
      instance = send!(ctx, %{"naslov" => "Kanalizacija"})

      waiting = Engine.run(instance.id)
      assert %ValueProcess{status: :waiting, element: "odluka", steps: 3} = waiting
      assert DateTime.diff(waiting.wake_at, DateTime.utc_now(), :day) in 6..7
      assert chat(ctx.group) == ["Stigla je molba: Kanalizacija"]

      sub = Repo.get!(Group, waiting.groups["predmet"])
      assert sub.name == "Molba: Kanalizacija"
      assert sub.parent_id == ctx.group.id
      assert Social.member_of_group?(ctx.member, sub)
      assert Social.member_of_group?(ctx.owner, sub)

      # Running it again does not do any of it twice.
      assert Engine.run(instance.id) == nil
      assert chat(ctx.group) == ["Stigla je molba: Kanalizacija"]

      assert {:error, :not_permitted} =
               Engine.complete_task(ctx.member, instance.id, "odluka", "odobri")

      assert {:ok, %ValueProcess{status: :running, element: "odobreno"}} =
               Engine.complete_task(ctx.owner, instance.id, "odluka", "odobri", " U redu. ")

      done = Engine.run(instance.id)
      assert %ValueProcess{status: :done, wake_at: nil} = done

      assert [%{"outcome" => "odobri", "by" => by, "comment" => "U redu."}] = done.log
      assert by == ctx.owner.id

      [decision] = Social.list_group_values(sub)
      assert decision.content == "Molba je odobrena."
      assert decision.managed["process"]["triggered_by"] == ctx.owner.id
      assert decision.managed["process"]["element"] == "odobreno"
    end

    test "a task is finished once, on its own element, with an outcome of the graph", ctx do
      save!(ctx, molbe(ctx.savet))
      instance = send!(ctx, %{"naslov" => "Klupa"})
      Engine.run(instance.id)

      assert {:error, :not_waiting} =
               Engine.complete_task(ctx.owner, instance.id, "drugo", "odobri")

      assert {:error, :invalid_outcome} =
               Engine.complete_task(ctx.owner, instance.id, "odluka", "možda")

      assert {:ok, _moved} = Engine.complete_task(ctx.owner, instance.id, "odluka", "odbij")

      assert {:error, :not_waiting} =
               Engine.complete_task(ctx.owner, instance.id, "odluka", "odbij")
    end

    test "a passed deadline reminds the council and waits again, set off by nobody", ctx do
      save!(ctx, molbe(ctx.savet))
      instance = send!(ctx, %{"naslov" => "Rasveta"})
      instance.id |> Engine.run() |> due_now!()

      again = Engine.run(instance.id)

      assert %ValueProcess{status: :waiting, element: "odluka", triggered_by_id: nil} = again
      assert again.steps == 5
      assert DateTime.diff(again.wake_at, DateTime.utc_now(), :day) in 6..7
      assert again.log == []
    end
  end

  describe "elements" do
    test "a timer waits its time, then goes on", ctx do
      save!(ctx, chain([%{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"}]))
      instance = send!(ctx, %{})

      waiting = Engine.run(instance.id)
      assert %ValueProcess{status: :waiting, element: "cekaj"} = waiting
      assert DateTime.diff(waiting.wake_at, DateTime.utc_now(), :minute) in 59..60

      assert Engine.run(instance.id) == nil
      due_now!(waiting)

      assert %ValueProcess{status: :done, triggered_by_id: nil} = Engine.run(instance.id)
    end

    test "a gateway takes the first flow whose condition holds, or its default", ctx do
      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "iznos", "type" => "exclusiveGateway"},
          message("veliko", "Veliki iznos: {{iznos}}"),
          message("malo", "Mali iznos"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "iznos"},
          %{
            "from" => "iznos",
            "to" => "veliko",
            "condition" => %{"field" => "iznos", "op" => ">", "value" => 1000}
          },
          %{"from" => "iznos", "to" => "malo", "default" => true},
          %{"from" => "veliko", "to" => "kraj"},
          %{"from" => "malo", "to" => "kraj"}
        ]
      }

      save!(ctx, graph)
      Engine.run(send!(ctx, %{"iznos" => "5000"}).id)
      Engine.run(send!(ctx, %{"iznos" => 10}).id)

      assert chat(ctx.group) == ["Veliki iznos: 5000", "Mali iznos"]
    end

    test "a loop that never waits stops", ctx do
      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "opet", "type" => "exclusiveGateway"},
          message("javi", "Još jednom"),
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "opet"},
          %{
            "from" => "opet",
            "to" => "javi",
            "condition" => %{"field" => "kraj", "op" => "empty"}
          },
          %{"from" => "opet", "to" => "kraj", "default" => true},
          %{"from" => "javi", "to" => "opet"}
        ]
      }

      save!(ctx, graph)
      instance = send!(ctx, %{})

      assert %ValueProcess{status: :failed, error: %{"reason" => "loop"}} =
               Engine.run(instance.id)
    end
  end

  describe "a failure" do
    test "stops the instance where it failed, for an editor to take up again", ctx do
      save!(ctx, chain([message("primljeno", "Stigla je molba.")]))

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :post_values, :neutral)

      instance = send!(ctx, %{})

      assert %ValueProcess{
               status: :failed,
               element: "primljeno",
               error: %{"element" => "primljeno", "reason" => "not_permitted"}
             } = Engine.run(instance.id)

      assert chat(ctx.group) == []

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :post_values, :allow)

      assert {:ok, %ValueProcess{status: :running, error: nil}} = Engine.retry(instance.id)
      assert %ValueProcess{status: :done} = Engine.run(instance.id)
      assert chat(ctx.group) == ["Stigla je molba."]
      assert {:error, :not_failed} = Engine.retry(instance.id)
    end
  end

  describe "the rule" do
    test "removed, cancels the instances that run or wait", ctx do
      save!(ctx, molbe(ctx.savet))
      waiting = send!(ctx, %{"naslov" => "A"})
      Engine.run(waiting.id)
      fresh = send!(ctx, %{"naslov" => "B"})

      {:ok, _config} =
        AppData.save_config(
          ctx.owner,
          ctx.group,
          nil,
          %{"rules" => %{}},
          AppData.get_config(ctx.group, nil).lock_version
        )

      assert %ValueProcess{status: :cancelled} = Repo.get!(ValueProcess, waiting.id)
      assert %ValueProcess{status: :cancelled} = Repo.get!(ValueProcess, fresh.id)
      assert Engine.run(fresh.id) == nil
    end

    test "changed, leaves the instances under way on the graph they started with", ctx do
      save!(
        ctx,
        chain([
          %{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"},
          message("javi", "Stari tekst")
        ])
      )

      old = send!(ctx, %{})
      old.id |> Engine.run() |> due_now!()

      save!(
        ctx,
        chain([
          %{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"},
          message("javi", "Novi tekst")
        ])
      )

      Engine.run(old.id)

      assert chat(ctx.group) == ["Stari tekst"]
    end
  end

  describe "run_due/1" do
    test "takes up the instances whose time has come, and only those", ctx do
      save!(ctx, chain([%{"id" => "cekaj", "type" => "timer", "duration" => "PT1H"}]))
      a = send!(ctx, %{})
      b = send!(ctx, %{})

      assert Engine.run_due() >= 2
      assert %ValueProcess{status: :waiting} = Repo.get!(ValueProcess, a.id)

      Repo.get!(ValueProcess, b.id) |> due_now!()
      Engine.run_due()

      assert %ValueProcess{status: :waiting} = Repo.get!(ValueProcess, a.id)
      assert %ValueProcess{status: :done} = Repo.get!(ValueProcess, b.id)
    end
  end

  test "the value going takes its instance along", ctx do
    save!(ctx, molbe(ctx.savet))
    instance = send!(ctx, %{"naslov" => "X"})

    {:ok, _value} = AppData.delete(ctx.owner, ctx.group, nil, instance.value_id)

    refute Repo.get(ValueProcess, instance.id)
    refute Repo.get(Value, instance.value_id)
  end
end
