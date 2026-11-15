defmodule PotokIdeWeb.GroupLive.AppProcessesTest do
  @moduledoc """
  The processes of a group's apps on its page: apart from the members, with
  what they lack for those who edit the apps, and under their rule's name in
  the chat.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Social.{AppData, AppProcess, ProcessActions, ProcessStep}

  setup do
    {owner_account, owner} = account_with_profile!("ap-owner")
    {member_account, member} = account_with_profile!("ap-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "app-processes",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
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

  defp with_process, do: %{"tasks" => %{"process" => %{"name" => "Prijem molbi"}}}

  # A process whose graph opens a sub-group, and so needs the right to.
  defp with_subgroups do
    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "predmet", "type" => "serviceTask", "action" => "subgroup", "name" => "Molba"},
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "predmet"},
        %{"from" => "predmet", "to" => "kraj"}
      ]
    }

    put_in(with_process(), ["tasks", "process", "graph"], graph)
  end

  defp process_of(group) do
    AppProcess |> Repo.get_by!(group_id: group.id) |> Repo.preload(:profile)
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp step(group, triggered_by, groups \\ []) do
    %ProcessStep{
      process: process_of(group),
      instance: 1,
      element: "Task_1",
      triggered_by: triggered_by,
      groups: groups
    }
  end

  defp post!(step, group, content) do
    {:ok, value, announce} = ProcessActions.post_value(step, group, %{"content" => content})
    ProcessActions.announce([announce])
    value
  end

  describe "the members tab" do
    test "lists the app's processes apart from the members", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: process} = process_of(ctx.group)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

      assert has_element?(lv, "#group-process-#{process.id}", "Prijem molbi")
      assert has_element?(lv, "#group-process-#{process.id}", "tasks")
      assert has_element?(lv, "#group-process-#{process.id}", ctx.owner.username)
      refute has_element?(lv, "#group-members-list", process.username)
      refute has_element?(lv, "#member-#{process.id}")

      # Only those who edit the app hear what is missing, and only admins assign roles.
      refute has_element?(lv, "#process-#{process.id}-warning")
      refute has_element?(lv, "#process-#{process.id}-roles-toggle")
    end

    test "leads to the Processes tab, where the counts are", ctx do
      save!(ctx.owner, ctx.group, with_process())

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

      lv |> element("#group-processes-link") |> render_click()
      assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#group-panel-processes")
    end

    test "is quiet about processes while the apps have none", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")

      refute has_element?(lv, "#group-processes")
    end

    test "tells the editors what a process may not do, until an admin gives it a role", ctx do
      save!(ctx.owner, ctx.group, with_subgroups())
      %{profile: process} = process_of(ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_subgroups,
          :neutral
        )

      {:ok, bot} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "bot"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, bot.key, :create_subgroups, :allow)

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")

      assert has_element?(lv, "#process-#{process.id}-missing", "Create sub-groups")
      refute has_element?(lv, "#process-#{process.id}-owner-left")

      lv |> element("#process-#{process.id}-role-#{bot.key}") |> render_click()

      assert has_element?(lv, "#process-#{process.id}-role-badge-#{bot.key}")
      refute has_element?(lv, "#process-#{process.id}-warning")
      refute has_element?(lv, "#member-#{process.id}")
    end

    test "follows the app's rules as they are saved", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")
      refute has_element?(lv, "#group-processes")

      # The page hears of each save before it answers the next call.
      save!(ctx.owner, ctx.group, with_process())
      assert has_element?(lv, "#group-processes", "Prijem molbi")

      save!(ctx.owner, ctx.group, %{})
      refute has_element?(lv, "#group-processes")
    end
  end

  describe "the instances" do
    # A process whose every value waits for a member to say it is done.
    defp with_task do
      graph = %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "odluka",
            "type" => "userTask",
            "role" => "everyone",
            "outcomes" => ["gotovo"]
          },
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "odluka"},
          %{"from" => "odluka", "to" => "kraj", "outcome" => "gotovo"}
        ]
      }

      put_in(with_process(), ["tasks", "process", "graph"], graph)
    end

    defp waiting!(ctx) do
      {:ok, value, _rule} =
        AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "tasks", %{})

      instance = Repo.get_by!(ValueProcess, value_id: value.id)
      Engine.run(instance.id)
    end

    test "are counted by state on the Processes tab, and follow each move", ctx do
      save!(ctx.owner, ctx.group, with_task())
      row = process_of(ctx.group)
      instance = waiting!(ctx)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#process-row-#{row.id}-count-waiting", "Waiting: 1")
      assert has_element?(lv, "#process-row-#{row.id}-kind", "from the app")

      {:ok, _moved} = Engine.complete_task(ctx.member, instance.id, "odluka", "gotovo")
      Engine.run(instance.id)

      assert render(lv) =~ "Done: 1"
      refute has_element?(lv, "#process-row-#{row.id}-count-waiting")
    end

    test "that failed show to the editors, who take them up again", ctx do
      save!(ctx.owner, ctx.group, with_task())
      row = process_of(ctx.group)
      instance = waiting!(ctx)

      instance
      |> Ecto.Changeset.change(
        status: :failed,
        error: %{"element" => "odluka", "reason" => "not_permitted"}
      )
      |> Repo.update!()

      {:ok, member_lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")

      assert has_element?(member_lv, "#process-row-#{row.id}-count-failed", "Failed: 1")
      refute has_element?(member_lv, "#process-row-#{row.id}-failed")

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#process-instance-#{instance.id}", "Stopped at odluka")
      assert has_element?(lv, "#process-instance-#{instance.id}", "lacks a permission")

      lv |> element("#process-instance-#{instance.id}-retry") |> render_click()

      refute has_element?(lv, "#process-instance-#{instance.id}")
      assert has_element?(lv, "#process-row-#{row.id}-count-running", "Running: 1")
      assert %ValueProcess{status: :running, error: nil} = Repo.get!(ValueProcess, instance.id)
    end
  end

  describe "the chat" do
    test "shows a process's values under its rule's name, marked as a process", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: process} = process_of(ctx.group)
      {:ok, value} = Social.create_value(process, ctx.group, %{"content" => "Primljeno."})

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      assert has_element?(lv, "#value-#{value.id} .chat-header", "Prijem molbi")
      assert has_element?(lv, "#value-process-#{value.id}")
      refute has_element?(lv, "#value-#{value.id} .chat-header", process.username)
    end

    test "says who set the process going, and nobody when a timer did", ctx do
      save!(ctx.owner, ctx.group, with_process())
      started = post!(step(ctx.group, ctx.member.id), ctx.group, "Primljeno.")
      timed = post!(step(ctx.group, nil), ctx.group, "Rok je istekao.")

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")

      assert has_element?(lv, "#value-process-trigger-#{started.id}", ctx.member.username)
      refute has_element?(lv, "#value-process-trigger-#{timed.id}")
      assert has_element?(lv, "#value-process-#{timed.id}")
    end

    test "from a sub-group it made, the process's name leads to its app", ctx do
      save!(ctx.owner, ctx.group, with_process())
      at_home = post!(step(ctx.group, ctx.member.id), ctx.group, "Primljeno.")

      {:ok, sub, announce} =
        ProcessActions.create_subgroup(step(ctx.group, ctx.member.id), ctx.group, %{
          "name" => "molba"
        })

      ProcessActions.announce([announce])
      in_sub = post!(step(ctx.group, ctx.member.id, [sub.id]), sub, "Uzeto u rad.")

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{sub.id}/values")

      assert has_element?(
               lv,
               ~s(#value-process-app-#{in_sub.id}[href="/groups/#{ctx.group.id}/group_home"]),
               "Prijem molbi"
             )

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      refute has_element?(lv, "#value-process-app-#{at_home.id}")
      assert has_element?(lv, "#value-#{at_home.id} .chat-header", "Prijem molbi")
    end

    test "names the process on a value that arrives while the chat is open", ctx do
      save!(ctx.owner, ctx.group, with_process())
      %{profile: process} = process_of(ctx.group)

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      {:ok, value} = Social.create_value(process, ctx.group, %{"content" => "Primljeno."})

      assert has_element?(lv, "#value-process-#{value.id}")
      assert has_element?(lv, "#value-#{value.id} .chat-header", "Prijem molbi")
    end
  end
end
