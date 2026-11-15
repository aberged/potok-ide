defmodule PotokIde.Social.DrawnProcessesTest do
  @moduledoc """
  Processes an editor draws in Potok: kept apart from the app's config, so
  no save of the app reaches them, run beside the app's own process on the
  same collection, and finished by the people of their roles on the group's
  page rather than in the app.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Processes
  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, AppProcess, AppProcesses, DrawnProcesses, Profile}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("dp#{unique()}")
    {member_account, member} = account_with_profile!("dp#{unique()}")

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
    group = Social.get_group!(group.id)

    save_rules!(owner, group, %{"molbe" => %{}})

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: group,
      savet: savet.key
    }
  end

  defp save_rules!(editor, group, rules) do
    revision =
      case AppData.get_config(group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    {:ok, config} = AppData.save_config(editor, group, nil, %{"rules" => rules}, revision)
    config
  end

  # A request comes in and the council decides it.
  defp odluka(savet) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "odluka",
          "type" => "userTask",
          "label" => "Savet odlučuje",
          "role" => savet,
          "outcomes" => ["odobri", "odbij"]
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "odluka"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odobri"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odbij"}
      ]
    }
  end

  defp message_graph do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "primljeno",
          "type" => "serviceTask",
          "action" => "message",
          "text" => "Stigla je molba: {{naslov}}"
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "primljeno"},
        %{"from" => "primljeno", "to" => "kraj"}
      ]
    }
  end

  defp subgroup_graph do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "predmet",
          "type" => "serviceTask",
          "action" => "subgroup",
          "name" => "{{naslov}}"
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "predmet"},
        %{"from" => "predmet", "to" => "kraj"}
      ]
    }
  end

  defp draw!(ctx, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "alt_id" => nil,
          "collection" => "molbe",
          "name" => "Savet",
          "graph" => odluka(ctx.savet)
        },
        attrs
      )

    {:ok, row} = DrawnProcesses.create(ctx.owner, ctx.group, attrs)
    row
  end

  defp drawn_on!(ctx, attrs \\ %{}) do
    row = draw!(ctx, attrs)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp send!(ctx, data \\ %{"naslov" => "Kanalizacija"}) do
    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", data)

    value
  end

  defp instances(value), do: Repo.all(from(i in ValueProcess, where: i.value_id == ^value.id))

  describe "drawing" do
    test "makes a process that is off, with a profile of its own outside the group", ctx do
      row = draw!(ctx, %{"layout" => %{"nodes" => %{"odluka" => [10.4, -20], "nema" => [1, 1]}}})

      assert %AppProcess{drawn: true, active: false, collection: "molbe", name: "Savet"} = row
      assert row.owner_profile_id == ctx.owner.id
      assert %Profile{kind: :process} = row.profile
      refute Social.member_of_group?(row.profile, ctx.group)
      assert row.layout == %{"nodes" => %{"odluka" => [10, -20]}}

      assert [%{"label" => "Savet odlučuje"}] =
               Enum.filter(row.graph["nodes"], &(&1["id"] == "odluka"))
    end

    test "is for the app's editors, on a collection of one of the group's apps", ctx do
      attrs = %{
        "alt_id" => nil,
        "collection" => "molbe",
        "name" => "Savet",
        "graph" => odluka(ctx.savet)
      }

      assert {:error, :not_permitted} = DrawnProcesses.create(ctx.member, ctx.group, attrs)

      assert {:error, :unknown_collection} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{attrs | "collection" => "nema"})

      assert {:error, :not_an_app} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{attrs | "alt_id" => -1})

      assert {:error, :invalid_name} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{attrs | "name" => " "})

      assert {:error, {:invalid_graph, "nodes.1.role", :unknown_role}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{attrs | "graph" => odluka("nema")})

      broken = Map.update!(odluka(ctx.savet), "flows", &Enum.drop(&1, -1))

      assert {:error, {:invalid_graph, "nodes.1.outcomes", :no_flow}} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{attrs | "graph" => broken})
    end

    test "offers the collections of the app's rules and of its values", ctx do
      assert DrawnProcesses.collections(ctx.group, nil) == ["molbe"]
      assert [%{alt_id: nil}] = DrawnProcesses.apps(ctx.group)
    end

    test "keeps at most ten on one app", ctx do
      for _ <- 1..DrawnProcesses.max_per_app(), do: draw!(ctx)

      assert {:error, :too_many} =
               DrawnProcesses.create(ctx.owner, ctx.group, %{
                 "alt_id" => nil,
                 "collection" => "molbe",
                 "name" => "Jedanaesti",
                 "graph" => odluka(ctx.savet)
               })
    end

    test "changes only from the revision the editor started from", ctx do
      row = draw!(ctx)
      attrs = %{"name" => "Savet MZ", "graph" => odluka(ctx.savet)}

      assert {:ok, changed} =
               DrawnProcesses.update(ctx.owner, ctx.group, row.id, attrs, row.lock_version)

      assert changed.name == "Savet MZ"
      assert changed.lock_version == row.lock_version + 1

      assert {:error, {:conflict, %AppProcess{name: "Savet MZ"}}} =
               DrawnProcesses.update(ctx.owner, ctx.group, row.id, attrs, row.lock_version)
    end
  end

  describe "switched on" do
    test "joins the app's group and says what its own graph may not do", ctx do
      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_subgroups,
          :neutral
        )

      row = drawn_on!(ctx, %{"graph" => subgroup_graph()})

      assert row.active
      assert Social.member_of_group?(row.profile, ctx.group)
      assert %{"missing" => ["create_subgroups"]} = AppProcesses.warning(row, ctx.group)
      assert AppProcesses.warnings(ctx.group, nil) == %{}
    end

    test "starts an instance of its own beside the app's process on the same collection", ctx do
      save_rules!(ctx.owner, ctx.group, %{
        "molbe" => %{"process" => %{"name" => "Prijem", "graph" => message_graph()}}
      })

      drawn = drawn_on!(ctx)
      value = send!(ctx)

      assert [_, _] = found = instances(value)
      assert Enum.any?(found, &(&1.app_process_id == drawn.id and &1.element == "start"))
    end

    test "starts nothing while it is off", ctx do
      draw!(ctx)
      assert instances(send!(ctx)) == []
    end

    test "stays on whatever the app saves, a rule without a process included", ctx do
      drawn = drawn_on!(ctx)

      save_rules!(ctx.owner, ctx.group, %{
        "molbe" => %{"process" => %{"name" => "Prijem", "graph" => message_graph()}}
      })

      save_rules!(ctx.owner, ctx.group, %{"molbe" => %{}})

      assert %AppProcess{active: true} = Repo.get!(AppProcess, drawn.id)
      assert [%{app_process_id: id}] = instances(send!(ctx))
      assert id == drawn.id
    end

    test "keeps the graph an instance started with when the drawing changes", ctx do
      drawn = drawn_on!(ctx)
      value = send!(ctx)

      {:ok, _} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          drawn.id,
          %{"name" => "Savet", "graph" => message_graph()},
          drawn.lock_version
        )

      [instance] = instances(value)
      assert Enum.any?(instance.graph["nodes"], &(&1["id"] == "odluka"))
    end
  end

  describe "switched off or deleted" do
    test "cancels what runs or waits and leaves the group", ctx do
      drawn = drawn_on!(ctx)
      value = send!(ctx)

      {:ok, off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, drawn.id)

      refute off.active
      refute Social.member_of_group?(off.profile, ctx.group)
      assert [%ValueProcess{status: :cancelled}] = instances(value)
    end

    test "takes its instances along, and its profile once nothing it wrote is left", ctx do
      drawn = drawn_on!(ctx)
      value = send!(ctx)

      {:ok, _} = DrawnProcesses.delete(ctx.owner, ctx.group, drawn.id)

      assert instances(value) == []
      assert Repo.get(AppProcess, drawn.id) == nil
      assert AppProcesses.sweep() >= 1
      assert Repo.get(Profile, drawn.profile_id) == nil
    end
  end

  describe "the app" do
    test "neither lists nor finishes a drawn process's instances", ctx do
      drawn_on!(ctx)
      value = send!(ctx)
      [instance] = instances(value)
      Engine.run(instance.id)
      access = Access.for_profile(ctx.owner, ctx.group)

      assert Processes.list(ctx.owner, ctx.group, nil, access, "molbe") == []

      assert {:error, :not_found} =
               Processes.complete_task(
                 ctx.owner,
                 ctx.group,
                 nil,
                 access,
                 instance.id,
                 "odluka",
                 "odobri",
                 nil
               )

      assert {:ok, %{element: "kraj", log: [%{outcome: "odobri"}]}} =
               Processes.complete_task(
                 ctx.owner,
                 ctx.group,
                 :any,
                 access,
                 instance.id,
                 "odluka",
                 "odobri",
                 nil
               )
    end

    test "hears nothing of a drawn process's instances moving", ctx do
      drawn_on!(ctx)
      value = send!(ctx)
      AppData.subscribe(ctx.group)
      [instance] = instances(value)

      Engine.run(instance.id)

      assert_receive {:app_value, _group_id, :process, %{drawn: true}}
    end
  end

  describe "tasks" do
    test "wait for the people of the task's role, with the value they may read", ctx do
      drawn_on!(ctx)
      value = send!(ctx, %{"naslov" => "Kanalizacija", "a" => %{"q1" => "Da"}})
      [instance] = instances(value)
      Engine.run(instance.id)

      owner_access = Access.for_profile(ctx.owner, ctx.group)
      member_access = Access.for_profile(ctx.member, ctx.group)

      assert [task] = Processes.tasks_for(ctx.owner, ctx.group, owner_access)
      assert task.id == instance.id
      assert task.label == "Savet odlučuje"
      assert task.outcomes == ["odobri", "odbij"]
      assert task.author.id == ctx.member.id
      assert {"a.q1", "Da"} in task.data
      assert {"naslov", "Kanalizacija"} in task.data

      assert Processes.tasks_for(ctx.member, ctx.group, member_access) == []
    end
  end

  test "reads a value's data in rows a person can read" do
    assert Processes.data_rows(%{"b" => [1, 2], "a" => %{"x" => true, "y" => nil}}) == [
             {"a.x", "true"},
             {"b", "1, 2"}
           ]
  end
end
