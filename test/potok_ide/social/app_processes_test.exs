defmodule PotokIde.Social.AppProcessesTest do
  @moduledoc """
  The profile that signs what an app's process does: born with the rule, a
  member of the app's group and nothing more, never an account's, and left
  out wherever people are listed, mentioned, invited or inherited.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, AppProcess, AppProcesses, GroupRole, Profile}
  alias PotokIde.Social.{ProcessActions, ProcessStep}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("pr#{unique()}")
    {_member_account, member} = account_with_profile!("pr#{unique()}")

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
      group: Social.get_group!(group.id)
    }
  end

  defp save!(editor, group, rules) do
    revision =
      case AppData.get_config(group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    {:ok, config} = AppData.save_config(editor, group, nil, %{"rules" => rules}, revision)
    config
  end

  defp with_process(name \\ "Prijem"), do: %{"tasks" => %{"process" => %{"name" => name}}}

  # A process that opens a sub-group for every value, and so needs the right to.
  defp with_graph(graph \\ subgroup_graph()),
    do: %{"tasks" => %{"process" => %{"name" => "Prijem", "graph" => graph}}}

  defp subgroup_graph(admins \\ ["owner"]) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "predmet",
          "type" => "serviceTask",
          "action" => "subgroup",
          "name" => "{{naslov}}",
          "admins" => admins
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "predmet"},
        %{"from" => "predmet", "to" => "kraj"}
      ]
    }
  end

  defp process_of(group, collection \\ "tasks") do
    AppProcess
    |> Repo.get_by!(group_id: group.id, collection: collection)
    |> Repo.preload(:profile)
  end

  defp member?(profile, group), do: Social.member_of_group?(profile, group)

  describe "with the rule" do
    test "comes a profile of its own, a plain member of the app's group", ctx do
      save!(ctx.owner, ctx.group, with_process())
      row = process_of(ctx.group)

      assert %AppProcess{active: true, alt_description_id: nil} = row
      assert row.owner_profile_id == ctx.owner.id
      assert %Profile{kind: :process, username: "proces." <> _} = row.profile

      access = Access.for_profile(row.profile, ctx.group)
      assert access.member?
      refute access.admin?
      assert access.role_keys == [GroupRole.everyone_key()]
    end

    test "saving again keeps the one profile, and the name follows the rule", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile_id: profile_id, name: "Prijem"} = process_of(ctx.group)

      save!(ctx.owner, ctx.group, with_process("Prijem molbi"))

      assert [%AppProcess{profile_id: ^profile_id, name: "Prijem molbi"}] = Repo.all(AppProcess)
    end

    test "goes by the rule's name once its process is loaded", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: profile} = row = process_of(ctx.group)

      assert Profile.display_name(profile) == profile.username
      assert Profile.display_name(%{profile | app_process: row}) == "Prijem"
      assert Profile.display_name(Repo.preload(profile, :app_process)) == "Prijem"
      assert Profile.display_name(ctx.owner) == ctx.owner.username
    end

    test "a rule without a process makes none, and a process needs a name", ctx do
      save!(ctx.owner, ctx.group, %{"tasks" => %{"write" => ["everyone"]}})
      assert Repo.all(AppProcess) == []

      for process <- [%{}, %{"name" => "  "}, %{"name" => String.duplicate("a", 61)}, "x"] do
        assert {:error, :invalid_rules} =
                 AppData.save_config(
                   ctx.owner,
                   ctx.group,
                   nil,
                   %{"rules" => %{"tasks" => %{"process" => process}}},
                   1
                 )
      end
    end

    test "the default description holds one process per collection", ctx do
      save!(ctx.owner, ctx.group, with_process())
      row = process_of(ctx.group)
      other = AppProcesses.create_process_profile!()

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%AppProcess{
          profile_id: other.id,
          group_id: ctx.group.id,
          alt_description_id: nil,
          collection: row.collection,
          name: "Drugi",
          owner_profile_id: ctx.owner.id
        })
      end
    end

    test "it posts in the chat as itself", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: process} = process_of(ctx.group)

      assert {:ok, value} = Social.create_value(process, ctx.group, %{"content" => "Primljeno."})
      assert value.creator_id == process.id
    end
  end

  describe "without the rule" do
    test "the process stops and leaves the group; what it wrote keeps its author", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: process} = process_of(ctx.group)
      {:ok, value} = Social.create_value(process, ctx.group, %{"content" => "Primljeno."})

      save!(ctx.owner, ctx.group, %{})

      assert %AppProcess{active: false} = process_of(ctx.group)
      refute member?(process, ctx.group)
      assert Social.get_value!(value.id).creator_id == process.id
    end

    test "the rule coming back brings the same profile back, owned by who saved it", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile_id: profile_id, profile: process} = process_of(ctx.group)
      save!(ctx.owner, ctx.group, %{})

      {:ok, _role} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
      save!(ctx.member, ctx.group, with_process())

      assert %AppProcess{active: true, profile_id: ^profile_id, owner_profile_id: owner_id} =
               process_of(ctx.group)

      assert owner_id == ctx.member.id
      assert member?(process, ctx.group)
    end
  end

  describe "the owner" do
    test "who no longer edits the app shows in the warnings and gives way to the next editor",
         ctx do
      {:ok, _role} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
      save!(ctx.member, ctx.group, with_process())
      assert AppProcesses.warnings(ctx.group, nil) == %{}

      :ok = Social.unassign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")

      assert %{"tasks" => %{"missing" => [], "owner_left" => true}} =
               AppProcesses.warnings(ctx.group, nil)

      save!(ctx.owner, ctx.group, with_process())
      assert process_of(ctx.group).owner_profile_id == ctx.owner.id
      assert AppProcesses.warnings(ctx.group, nil) == %{}
    end
  end

  describe "list_active/1" do
    test "lists the group's running processes by name, with their owners", ctx do
      save!(
        ctx.owner,
        ctx.group,
        %{
          "tasks" => %{"process" => %{"name" => "Zadaci"}},
          "notes" => %{"process" => %{"name" => "Beleške"}}
        }
      )

      assert [%{name: "Beleške"} = notes, %{name: "Zadaci"}] =
               AppProcesses.list_active(ctx.group)

      assert notes.owner_profile.id == ctx.owner.id
      assert notes.profile.kind == :process

      save!(ctx.owner, ctx.group, %{"tasks" => %{"process" => %{"name" => "Zadaci"}}})
      assert [%{name: "Zadaci"}] = AppProcesses.list_active(ctx.group)
    end
  end

  describe "warnings" do
    test "name what the actions of its graph need and it lacks in the app's group", ctx do
      save!(ctx.owner, ctx.group, with_process())

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_subgroups,
          :neutral
        )

      # Without a graph it does nothing, so it needs nothing.
      assert AppProcesses.warnings(ctx.group, nil) == %{}

      save!(ctx.owner, ctx.group, with_graph())

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_subgroups,
          :neutral
        )

      assert %{"tasks" => %{"missing" => ["create_subgroups"], "owner_left" => false}} =
               AppProcesses.warnings(ctx.group, nil)

      row = process_of(ctx.group)
      assert AppProcesses.warning(row, ctx.group)["missing"] == ["create_subgroups"]
    end
  end

  describe "a graph" do
    test "is kept with the rule, checked", ctx do
      save!(ctx.owner, ctx.group, with_graph())

      assert %{"tasks" => %{"process" => %{"name" => "Prijem", "graph" => graph}}} =
               ctx.group |> AppData.get_config(nil) |> AppData.rules()

      assert [_start, %{"admins" => ["owner"]}, _end] = graph["nodes"]
    end

    test "that cannot hold is refused, saying where", ctx do
      broken = Map.update!(subgroup_graph(), "flows", &Enum.drop(&1, -1))

      assert {:error, {:invalid_process, "tasks", "process.graph.nodes.1", :one_flow}} =
               AppData.save_config(ctx.owner, ctx.group, nil, %{"rules" => with_graph(broken)}, 0)

      assert Repo.all(AppProcess) == []
    end

    test "names only roles of the app's group", ctx do
      assert {:error,
              {:invalid_process, "tasks", "process.graph.nodes.1.admins.0", :unknown_role}} =
               AppData.save_config(
                 ctx.owner,
                 ctx.group,
                 nil,
                 %{"rules" => with_graph(subgroup_graph(["savet"]))},
                 0
               )

      {:ok, savet} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "savet"})
      save!(ctx.owner, ctx.group, with_graph(subgroup_graph([savet.key, "triggered_by"])))
    end
  end

  describe "a process profile" do
    setup ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{process: process_of(ctx.group).profile}
    end

    test "never belongs to an account", ctx do
      assert {:error, :process_profile} =
               Social.add_profile_to_account(ctx.process, ctx.owner_account)

      assert Social.list_profiles_for_account(ctx.owner_account) |> Enum.map(& &1.id) == [
               ctx.owner.id
             ]
    end

    test "is not mentioned, by suggestion, by name or through a role", ctx do
      prefix = ctx.process.username |> String.slice(0, 9)
      candidates = Social.list_mention_candidates(ctx.owner, ctx.group, prefix)
      refute Enum.any?(candidates, &(&1[:id] == ctx.process.id))

      {:ok, value} =
        Social.create_value(ctx.owner, ctx.group, %{
          "content" => "@#{ctx.process.username} @everyone"
        })

      refute ctx.process.id in value.mentioned_profile_ids
      assert ctx.member.id in value.mentioned_profile_ids
    end

    test "has no direct conversations", ctx do
      assert {:error, :process_profile} =
               Social.get_or_create_direct_group(ctx.owner, ctx.process)

      assert {:error, :process_profile} =
               Social.get_or_create_direct_group(ctx.process, ctx.owner)
    end

    test "is not offered for invitations", ctx do
      {:ok, other} =
        Social.create_group(ctx.owner, Social.get_root_group!(), %{
          "name" => "other-#{unique()}",
          "description" => "",
          "description_format" => :markdown
        })

      assert Social.list_invitable_profiles_for_group(ctx.owner, other, "proces.") == []
    end

    test "is not counted or listed among the members, nor among those a poll counts", ctx do
      ids = ctx.group |> Social.list_group_members() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([ctx.owner.id, ctx.member.id])
      assert Social.count_group_members(ctx.group) == 2
      refute ctx.process.id in Enum.map(Social.list_first3_group_members(ctx.group), & &1.id)
      refute Map.has_key?(Access.for_members(ctx.group), ctx.process.id)
      refute ctx.process.id in Access.profile_ids_with_role(ctx.group, "everyone")
    end

    test "leaves its app's group only with its rule, and may be removed from its sub-groups",
         ctx do
      assert {:error, :process_profile} =
               Social.remove_group_member(ctx.owner, ctx.group, ctx.process.id)

      assert {:error, :process_profile} =
               Social.block_from_group(ctx.owner, ctx.group, ctx.process)

      assert member?(ctx.process, ctx.group)

      step = %ProcessStep{
        process: process_of(ctx.group),
        instance: 1,
        element: "predmet",
        triggered_by: ctx.member.id
      }

      {:ok, sub, _announce} =
        ProcessActions.create_subgroup(step, ctx.group, %{"name" => "molba"})

      assert {:ok, _process} = Social.remove_group_member(ctx.owner, sub, ctx.process.id)

      # Stopped, it would still come back with its rule.
      save!(ctx.owner, ctx.group, %{})

      assert {:error, :process_profile} =
               Social.block_from_group(ctx.owner, ctx.group, ctx.process)
    end

    test "is not taken in by groups that inherit members", ctx do
      {:ok, child} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "child-#{unique()}",
          "description" => "",
          "description_format" => :markdown,
          "inherits_members" => true
        })

      assert member?(ctx.member, child)
      refute member?(ctx.process, child)
    end
  end

  describe "sweep/0" do
    test "deletes a process profile whose process is gone, unless it wrote something", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: silent} = process_of(ctx.group)

      save!(
        ctx.owner,
        ctx.group,
        Map.merge(with_process(), %{"notes" => %{"process" => %{"name" => "B"}}})
      )

      %{profile: talker} = process_of(ctx.group, "notes")
      {:ok, _value} = Social.create_value(talker, ctx.group, %{"content" => "Zabeleženo."})

      kept = AppProcesses.create_process_profile!()

      Repo.insert!(%AppProcess{
        profile_id: kept.id,
        group_id: ctx.group.id,
        collection: "kept",
        name: "Kept"
      })

      # As when the app or its group is deleted.
      Repo.delete_all(from(p in AppProcess, where: p.collection in ["tasks", "notes"]))

      assert AppProcesses.sweep() == 1
      refute Repo.get(Profile, silent.id)
      assert Repo.get(Profile, talker.id)
      assert Repo.get(Profile, kept.id)
    end

    test "leaves people alone", ctx do
      AppProcesses.sweep()
      assert Repo.get(Profile, ctx.member.id)
    end
  end
end
