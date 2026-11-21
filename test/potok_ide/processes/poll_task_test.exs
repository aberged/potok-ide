defmodule PotokIde.Processes.PollTaskTest do
  @moduledoc """
  The step "Poll" of a process drawn in Potok: it puts a question to the
  group, waits for the end, and goes on with how it went. A decision that
  gives or takes a role is carried out by the poll, not by the process,
  which holds no more than "everyone" does.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls.{Deadlines, Poll}
  alias PotokIde.Processes.{Check, Engine, Graph, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("pt#{unique()}")
    {member_account, member} = account_with_profile!("pt#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: Social.get_group!(group.id)
    }
  end

  defp poll(id, more \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "type" => "pollTask",
        "question" => "Does whoever asked become an admin?",
        "duration" => "P1D",
        "effect" => "grant",
        "role" => "admin",
        "who" => "starter",
        "majority" => "simple",
        "quorum" => 50
      },
      more
    )
  end

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

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

  defp drawn!(ctx, graph) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => "Admin by vote",
        "graph" => graph
      })

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp the_poll(instance) do
    Repo.one!(from(p in Poll, where: p.process_instance_id == ^instance.id))
  end

  defp end_poll!(poll) do
    Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
      set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
    )

    Deadlines.close_due(DateTime.utc_now(:second))
  end

  defp admin?(profile, group), do: Access.for_profile(profile, Repo.reload!(group)).admin?

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  describe "Graph.normalize/2" do
    test "keeps a poll and what its decision changes" do
      assert {:ok, %{"nodes" => [_start, kept, _end]}} =
               Graph.normalize(chain([poll("glas", %{"quorum" => "60", "secret" => "true"})]),
                 drawn: true
               )

      assert kept["effect"] == "grant"
      assert kept["quorum"] == 60
      assert kept["secret"] == true
      assert kept["who"] == "starter"
      refute Map.has_key?(kept, "answers")

      assert Graph.role_refs(chain([poll("glas")])) == [{"nodes.1.role", "admin"}]
      assert :create_polls in Graph.permissions(chain([poll("glas")]))
    end

    test "a decision on a role has a majority and a quorum, a plain poll its answers" do
      assert {:error, {"nodes.1.quorum", :effect_quorum}} =
               Graph.normalize(chain([poll("glas", %{"quorum" => nil})]), drawn: true)

      assert {:error, {"nodes.1.majority", :effect_majority}} =
               Graph.normalize(chain([poll("glas", %{"majority" => "plurality"})]), drawn: true)

      assert {:error, {"nodes.1.answers", :invalid}} =
               Graph.normalize(chain([poll("glas", %{"effect" => "none"})]), drawn: true)

      assert {:ok, _graph} =
               Graph.normalize(
                 chain([poll("glas", %{"effect" => "none", "answers" => ["Da", "Ne"]})]),
                 drawn: true
               )
    end

    test "only a drawing of today puts a poll" do
      first = chain([poll("glas")]) |> Map.delete("v")
      assert {:error, {"nodes.1.type", :invalid}} = Graph.normalize(first, drawn: true)
    end

    test "names whoever started the run only where someone does" do
      {:ok, graph} = Graph.normalize(chain([poll("glas")]), drawn: true)

      assert {:error, {"nodes.1.who", :no_starter}} =
               Check.run(graph, %{trigger: "schedule", config: %{}, entities: %{}})
    end
  end

  test "a process puts a role to the vote, waits, and the decision gives it", ctx do
    row =
      drawn!(
        ctx,
        chain([
          poll("glas"),
          message("ishod", "Ishod: {{glas.outcome}}, glasalo {{glas.voters}}")
        ])
      )

    {:ok, instance} = DrawnProcesses.start(ctx.member, ctx.group, row.id, %{"title" => "Molba"})
    assert %ValueProcess{status: :waiting, element: "glas"} = Engine.run(instance.id)

    poll = the_poll(instance)
    assert poll.effect == :grant
    assert poll.effect_profile_id == ctx.member.id
    assert poll.creator_id == row.profile_id
    assert poll.value_id, "it is posted in the chat"

    vote!(ctx.member, ctx.member_account, poll, 0)
    vote!(ctx.owner, ctx.owner_account, poll, 0)
    end_poll!(poll)

    assert %ValueProcess{status: :done} = Engine.run(instance.id)
    assert admin?(ctx.member, ctx.group)
    assert "Ishod: passed, glasalo 2" in chat(ctx.group)

    assert %{"glas" => %{"passed" => true, "applied" => true}} =
             Repo.get!(ValueProcess, instance.id).results
  end

  test "a decision that does not pass gives nothing, and the run goes on", ctx do
    row = drawn!(ctx, chain([poll("glas"), message("ishod", "Ishod: {{glas.outcome}}")]))

    {:ok, instance} = DrawnProcesses.start(ctx.member, ctx.group, row.id, %{"title" => "Molba"})
    Engine.run(instance.id)
    poll = the_poll(instance)

    vote!(ctx.member, ctx.member_account, poll, 1)
    vote!(ctx.owner, ctx.owner_account, poll, 1)
    end_poll!(poll)

    assert %ValueProcess{status: :done} = Engine.run(instance.id)
    refute admin?(ctx.member, ctx.group)

    assert %{"glas" => %{"passed" => false, "applied" => false}} =
             Repo.get!(ValueProcess, instance.id).results
  end

  test "an owner who is no longer an admin does not hand a decision on roles to the group",
       ctx do
    row = drawn!(ctx, chain([poll("glas")]))

    {:ok, _role} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
    :ok = Social.unassign_group_member_role(ctx.member, ctx.group, ctx.owner.id, "admin")

    {:ok, instance} = DrawnProcesses.start(ctx.member, ctx.group, row.id, %{"title" => "Molba"})

    assert %ValueProcess{status: :failed, error: %{"reason" => "effect_not_permitted"}} =
             Engine.run(instance.id)

    refute Repo.exists?(from(p in Poll, where: p.process_instance_id == ^instance.id))
  end

  test "where the group elects its admins the process itself may", ctx do
    row = drawn!(ctx, chain([poll("glas")]))
    {:ok, _group} = Social.set_elects_admins(ctx.owner, ctx.group, true)

    {:ok, instance} = DrawnProcesses.start(ctx.member, ctx.group, row.id, %{"title" => "Molba"})
    assert %ValueProcess{status: :waiting} = Engine.run(instance.id)
    assert the_poll(instance).effect == :grant
  end

  test "an editor who may not hand a decision on roles to the group cannot draw one", ctx do
    {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "urednik"})

    {:ok, _role} =
      Social.set_group_role_permission(ctx.owner, ctx.group, role.key, :edit_group, :allow)

    {:ok, _role} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, role.key)

    assert {:error, {:invalid_graph, "nodes.1.effect", :effect_not_permitted}} =
             DrawnProcesses.create(ctx.member, ctx.group, %{
               "trigger" => "manual",
               "name" => "Sam sebi admin",
               "graph" => chain([poll("glas")])
             })

    assert {:ok, _row} =
             DrawnProcesses.create(ctx.member, ctx.group, %{
               "trigger" => "manual",
               "name" => "Samo pita",
               "graph" => chain([poll("glas", %{"effect" => "none", "answers" => ["Da", "Ne"]})])
             })
  end
end
