defmodule PotokIde.Processes.VisibilityTest do
  @moduledoc """
  A process that others call is private, for its own group, or public: then
  the processes drawn in the groups above and below its group call it too,
  and the run they start there gets what the call hands over and nothing
  else.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupEntities, Reach, Types, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppProcess, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  # A tree: top → mid → low, and side beside mid.
  setup do
    {_owner_account, owner} = account_with_profile!("vid#{unique()}")
    {_other_account, other} = account_with_profile!("vid#{unique()}")

    group = fn parent, name ->
      group =
        group_with_members!(owner, [], %{:parent => parent, "name" => "#{name}-#{unique()}"})

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      Social.get_group!(group.id)
    end

    top = group.(nil, "top")
    mid = group.(top, "mid")
    low = group.(mid, "low")
    side = group.(top, "side")

    %{owner: owner, other: other, top: top, mid: mid, low: low, side: side}
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp chain(steps, last \\ %{"id" => "kraj", "type" => "endEvent", "label" => "Gotovo"}) do
    nodes = [%{"id" => "start", "type" => "startEvent"}] ++ steps ++ [last]

    flows =
      nodes
      |> Enum.map(& &1["id"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to} end)

    %{"v" => 2, "nodes" => nodes, "flows" => flows}
  end

  # A process others call, which writes what it was handed.
  defp callee!(ctx, group, attrs \\ %{}) do
    {:ok, row} =
      DrawnProcesses.create(
        ctx.owner,
        group,
        Map.merge(
          %{
            "trigger" => "process",
            "name" => "Majstor",
            "trigger_config" => %{"fields" => ["kvar"]},
            "graph" => chain([message("javi", "{{start.kvar}} od {{start.from}}")])
          },
          attrs
        )
      )

    {:ok, row} = DrawnProcesses.activate(ctx.owner, group, row.id)
    row
  end

  defp calling(callee_id, fields \\ %{"kvar" => "{{start.title}}"}) do
    chain([
      %{"id" => "poziv", "type" => "callActivity", "process" => callee_id, "fields" => fields},
      message("posle", "{{poziv.outcome}}/{{poziv.kvar}}")
    ])
  end

  defp caller(ctx, group, callee_id) do
    DrawnProcesses.create(ctx.owner, group, %{
      "trigger" => "manual",
      "name" => "Prijava",
      "graph" => calling(callee_id)
    })
  end

  defp caller!(ctx, group, callee_id) do
    {:ok, row} = caller(ctx, group, callee_id)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, group, row.id)
    row
  end

  defp public!(ctx, group, row) do
    {:ok, row} = DrawnProcesses.set_public(ctx.owner, group, row.id, true)
    row
  end

  defp start!(ctx, group, row) do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, group, row.id, %{"title" => "lift"})
    Engine.run(instance.id)
    instance.id
  end

  # Until nothing of the processes is due: a call's run, then its caller.
  defp settle(passes \\ 10) do
    if passes > 0 and Engine.run_due() > 0, do: settle(passes - 1)
  end

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  describe "Reach" do
    test "groups are related up and down the tree, not across it", ctx do
      assert Reach.related?(ctx.mid.id, ctx.low.id)
      assert Reach.related?(ctx.low.id, ctx.mid.id)
      assert Reach.related?(ctx.top.id, ctx.low.id)
      assert Reach.related?(ctx.low.id, ctx.top.id)

      refute Reach.related?(ctx.mid.id, ctx.side.id)
      refute Reach.related?(ctx.low.id, ctx.side.id)
      refute Reach.related?(ctx.mid.id, ctx.mid.id)
      refute Reach.related?(ctx.mid.id, -1)
    end

    test "the public processes of the groups above and below are found from either", ctx do
      private = callee!(ctx, ctx.mid, %{"name" => "Privatan"})
      public = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      beside = public!(ctx, ctx.side, callee!(ctx, ctx.side))

      assert public.id in Reach.public_ids(ctx.low.id)
      assert public.id in Reach.public_ids(ctx.top.id)
      assert beside.id in Reach.public_ids(ctx.top.id)

      # Not its own group's, which it calls anyway, nor a branch beside it.
      refute public.id in Reach.public_ids(ctx.mid.id)
      refute public.id in Reach.public_ids(ctx.side.id)
      refute beside.id in Reach.public_ids(ctx.low.id)

      for group <- [ctx.top, ctx.mid, ctx.low, ctx.side] do
        refute private.id in Reach.public_ids(group.id)
      end
    end
  end

  describe "who may call" do
    test "a private process is called from its own group alone", ctx do
      callee = callee!(ctx, ctx.mid)
      refute callee.is_public

      assert {:ok, _row} = caller(ctx, ctx.mid, callee.id)

      for group <- [ctx.low, ctx.top, ctx.side] do
        assert caller(ctx, group, callee.id) ==
                 {:error, {:invalid_graph, "nodes.1.process", :unknown_process}}
      end
    end

    test "a public one is called from the groups above and below, not from beside", ctx do
      callee = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      assert callee.is_public

      assert {:ok, _row} = caller(ctx, ctx.mid, callee.id)
      assert {:ok, _row} = caller(ctx, ctx.low, callee.id)
      assert {:ok, _row} = caller(ctx, ctx.top, callee.id)

      assert caller(ctx, ctx.side, callee.id) ==
               {:error, {:invalid_graph, "nodes.1.process", :unknown_process}}
    end

    test "an editor is offered its group's own, then the public ones around it", ctx do
      own = callee!(ctx, ctx.low, %{"name" => "Svoj"})
      public = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      _private = callee!(ctx, ctx.top, %{"name" => "Privatan"})
      _beside = public!(ctx, ctx.side, callee!(ctx, ctx.side))

      assert [first, second] = DrawnProcesses.callable(ctx.low)
      assert %{id: id, name: "Svoj", group: nil, public: false, fields: ["kvar"]} = first
      assert id == own.id

      assert %{id: id, name: "Majstor", group: group, public: true, fields: ["kvar"]} = second
      assert id == public.id
      assert group == ctx.mid.name
    end

    test "only a process others call can be public, and only its editors say so", ctx do
      callee = callee!(ctx, ctx.mid)

      {:ok, manual} =
        DrawnProcesses.create(ctx.owner, ctx.mid, %{
          "trigger" => "manual",
          "name" => "Rucni",
          "graph" => chain([message("javi", "x")])
        })

      assert DrawnProcesses.set_public(ctx.owner, ctx.mid, manual.id, true) ==
               {:error, :not_callable}

      assert DrawnProcesses.set_public(ctx.other, ctx.mid, callee.id, true) ==
               {:error, :not_permitted}

      assert DrawnProcesses.set_public(ctx.owner, ctx.low, callee.id, true) ==
               {:error, :not_found}

      # The database keeps it too.
      assert_raise Ecto.ConstraintError, ~r/app_processes_public_check/, fn ->
        manual |> Ecto.Changeset.change(is_public: true) |> Repo.update!()
      end

      assert {:ok, %AppProcess{is_public: true}} =
               DrawnProcesses.set_public(ctx.owner, ctx.mid, callee.id, true)

      assert {:ok, %AppProcess{is_public: false}} =
               DrawnProcesses.set_public(ctx.owner, ctx.mid, callee.id, false)
    end
  end

  describe "a call across groups" do
    test "starts a run with what it hands over and nothing else, and hears how it ended", ctx do
      callee = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      caller = caller!(ctx, ctx.low, callee.id)

      id = start!(ctx, ctx.low, caller)
      settle()

      assert %ValueProcess{status: :done} = Repo.get!(ValueProcess, id)

      assert [child] =
               Repo.all(from(i in ValueProcess, where: i.app_process_id == ^callee.id))

      # No subject and nobody of the caller's group, who are no one there.
      assert %ValueProcess{
               status: :done,
               depth: 1,
               value_id: nil,
               subject_group_id: nil,
               started_by_id: nil,
               triggered_by_id: nil,
               data: %{"kvar" => "lift", "from" => "Prijava"}
             } = child

      assert chat(ctx.mid) == ["lift od Prijava"]
      # The caller hears the end it reached, not what the run held.
      assert chat(ctx.low) == ["Gotovo/"]
    end

    test "in its own group a called run shares the caller's people and says what it held", ctx do
      callee = callee!(ctx, ctx.mid)
      caller = caller!(ctx, ctx.mid, callee.id)

      start!(ctx, ctx.mid, caller)
      settle()

      assert [%ValueProcess{started_by_id: started_by, triggered_by_id: triggered_by}] =
               Repo.all(from(i in ValueProcess, where: i.app_process_id == ^callee.id))

      assert started_by == ctx.owner.id
      assert triggered_by == ctx.owner.id
      assert chat(ctx.mid) == ["lift od Prijava", "Gotovo/lift"]
    end

    test "goes down the tree as it goes up", ctx do
      callee = public!(ctx, ctx.low, callee!(ctx, ctx.low))
      caller = caller!(ctx, ctx.top, callee.id)

      id = start!(ctx, ctx.top, caller)
      settle()

      assert %ValueProcess{status: :done} = Repo.get!(ValueProcess, id)
      assert chat(ctx.low) == ["lift od Prijava"]
      assert chat(ctx.top) == ["Gotovo/"]
    end

    test "hands over the entity the called process takes, each attribute as its type", ctx do
      {:ok, kvar} =
        GroupEntities.create(ctx.mid, Access.for_profile(ctx.owner, ctx.mid), %{
          "name" => "Kvar",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"}
          ]
        })

      callee =
        public!(
          ctx,
          ctx.mid,
          callee!(ctx, ctx.mid, %{
            "trigger_config" => %{},
            "entry_entity_id" => kvar.id,
            "graph" => chain([message("javi", "{{start.naslov}} na {{start.sprat + 1}}")])
          })
        )

      # The caller's group has no such entity: it reads the one the process
      # was saved with.
      assert [%{id: id, attributes: [%{"name" => "naslov"}, %{"name" => "sprat"}]}] =
               DrawnProcesses.callable(ctx.low)

      assert id == callee.id

      typed = fn fields ->
        DrawnProcesses.create(ctx.owner, ctx.low, %{
          "trigger" => "manual",
          "name" => "Prijava #{unique()}",
          "graph" => calling(callee.id, fields)
        })
      end

      assert typed.(%{"naslov" => "", "sprat" => "2"}) ==
               {:error, {:invalid_graph, "nodes.1.fields.naslov", :required}}

      assert {:error, {:invalid_graph, "nodes.1.fields.sprat", {:mismatch, :number, :text}}} =
               typed.(%{"naslov" => "{{start.title}}", "sprat" => "start.title"})

      {:ok, caller} = typed.(%{"naslov" => "{{start.title}}", "sprat" => "length(start.title)"})
      {:ok, caller} = DrawnProcesses.activate(ctx.owner, ctx.low, caller.id)

      start!(ctx, ctx.low, caller)
      settle()
      assert chat(ctx.mid) == ["lift na 5"]
    end
  end

  describe "a public process that goes" do
    test "made private again, its callers elsewhere fail and their drawings are stale", ctx do
      callee = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      caller = caller!(ctx, ctx.low, callee.id)
      refute DrawnProcesses.stale?(caller, ctx.low)

      {:ok, _private} = DrawnProcesses.set_public(ctx.owner, ctx.mid, callee.id, false)

      assert DrawnProcesses.stale?(caller, ctx.low)

      id = start!(ctx, ctx.low, caller)

      assert %ValueProcess{
               status: :failed,
               error: %{"element" => "poziv", "reason" => "call_unknown"}
             } = Repo.get!(ValueProcess, id)

      assert chat(ctx.mid) == []

      # Its own group's callers go on as before.
      own = caller!(ctx, ctx.mid, callee.id)
      refute DrawnProcesses.stale?(own, ctx.mid)
    end

    test "is not kept by those of other groups that call it", ctx do
      callee = public!(ctx, ctx.mid, callee!(ctx, ctx.mid))
      far = caller!(ctx, ctx.low, callee.id)
      {:ok, near} = caller(ctx, ctx.mid, callee.id)

      assert {:error, {:in_use, "Prijava"}} =
               DrawnProcesses.delete(ctx.owner, ctx.mid, callee.id)

      {:ok, _gone} = DrawnProcesses.delete(ctx.owner, ctx.mid, near.id)
      assert {:ok, _gone} = DrawnProcesses.delete(ctx.owner, ctx.mid, callee.id)

      assert DrawnProcesses.stale?(far, ctx.low)

      id = start!(ctx, ctx.low, far)

      assert %ValueProcess{status: :failed, error: %{"reason" => "call_unknown"}} =
               Repo.get!(ValueProcess, id)
    end

    test "a caller whose called run went with its group fails where it waits", ctx do
      waiting =
        chain([
          %{"id" => "odluka", "type" => "userTask", "role" => "admin", "outcomes" => ["Da"]}
        ])
        |> update_in(["flows"], fn flows ->
          Enum.map(flows, &if(&1["from"] == "odluka", do: Map.put(&1, "outcome", "Da"), else: &1))
        end)

      callee = public!(ctx, ctx.low, callee!(ctx, ctx.low, %{"graph" => waiting}))
      caller = caller!(ctx, ctx.top, callee.id)

      # A run that only waits for a decision is none of this.
      {:ok, bystander} =
        DrawnProcesses.create(ctx.owner, ctx.top, %{
          "trigger" => "manual",
          "name" => "Odluka",
          "graph" => waiting
        })

      {:ok, bystander} = DrawnProcesses.activate(ctx.owner, ctx.top, bystander.id)

      id = start!(ctx, ctx.top, caller)
      other = start!(ctx, ctx.top, bystander)
      settle()

      assert %ValueProcess{status: :waiting, element: "poziv", awaiting_id: awaited} =
               Repo.get!(ValueProcess, id)

      assert is_integer(awaited)
      assert Engine.fail_orphaned_calls() == 0

      {:ok, _deleted} = Social.delete_group(ctx.owner, Social.get_group!(ctx.low.id))
      refute Repo.get(ValueProcess, awaited)

      assert Engine.fail_orphaned_calls() == 1

      assert %ValueProcess{
               status: :failed,
               awaiting_id: nil,
               error: %{"element" => "poziv", "reason" => "call_cancelled"}
             } = Repo.get!(ValueProcess, id)

      assert %ValueProcess{status: :waiting, element: "odluka"} = Repo.get!(ValueProcess, other)
      assert Engine.fail_orphaned_calls() == 0
    end
  end

  describe "Types.fits?/3" do
    test "an entity takes another that holds each of its attributes" do
      entities = %{
        "1" => %{
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "list" => false},
            %{"name" => "sprat", "type" => "number", "list" => false}
          ]
        },
        "2" => %{
          "attributes" => [
            %{"name" => "sprat", "type" => "number", "list" => false},
            %{"name" => "naslov", "type" => "text", "list" => false},
            %{"name" => "hitno", "type" => "boolean", "list" => false}
          ]
        },
        "3" => %{"attributes" => [%{"name" => "naslov", "type" => "number", "list" => false}]}
      }

      # The second holds all the first asks for, and more.
      assert Types.fits?({:entity, 2}, {:entity, 1}, entities)
      refute Types.fits?({:entity, 1}, {:entity, 2}, entities)
      refute Types.fits?({:entity, 3}, {:entity, 1}, entities)
      refute Types.fits?({:entity, 9}, {:entity, 1}, entities)
      assert Types.fits?({:entity, 1}, {:entity, 1}, entities)
      assert Types.fits?({:list, {:entity, 2}}, {:list, {:entity, 1}}, entities)
    end
  end
end
