defmodule PotokIdeWeb.GroupLive.AppProcessesApiTest do
  @moduledoc """
  What an app does with the instances of its processes: lists those of the
  values its viewer may read, lets the people of a task's role finish it,
  lets its editors take a failed one up again or cancel one, and hears each
  move live.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, group_with_members!: 3]

  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.AppData

  setup do
    {owner_account, owner} = account_with_profile!("pa-own#{System.unique_integer([:positive])}")

    {member_account, member} =
      account_with_profile!("pa-mem#{System.unique_integer([:positive])}")

    {other_account, other} = account_with_profile!("pa-oth#{System.unique_integer([:positive])}")

    group =
      group_with_members!(owner, [member, other], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, _role} = Social.assign_group_member_role(owner, group, owner.id, savet.key)
    group = Social.get_group!(group.id)

    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "odluka",
          "type" => "userTask",
          "role" => savet.key,
          "outcomes" => ["odobri", "odbij"],
          "deadline" => "P7D"
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "odluka"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odobri"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "odbij"},
        %{"from" => "odluka", "to" => "kraj", "deadline" => true}
      ]
    }

    {:ok, _config} =
      AppData.save_config(
        owner,
        group,
        nil,
        %{"rules" => %{"molbe" => %{"process" => %{"name" => "Prijem", "graph" => graph}}}},
        0
      )

    {:ok, value, _rule} = AppData.insert(member, member_account, group, nil, "molbe", %{})
    instance = Repo.get_by!(ValueProcess, value_id: value.id)
    Engine.run(instance.id)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      other_account: other_account,
      other: other,
      group: group,
      instance: instance
    }
  end

  defp open_app(account, group) do
    {:ok, view, _html} =
      build_conn() |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp api(view, method, params) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  test "lists the instances of the values the viewer may read, with the task they wait on",
       ctx do
    id = ctx.instance.id
    owner = open_app(ctx.owner_account, ctx.group)
    api(owner, "list_processes", %{"collection" => "molbe"})

    assert_reply(owner, %{
      ok: true,
      processes: [
        %{
          id: ^id,
          status: "waiting",
          element: "odluka",
          task: %{element: "odluka", outcomes: ["odobri", "odbij"], can_complete: true}
        }
      ]
    })

    # The author sees their own, without the right to decide it.
    member = open_app(ctx.member_account, ctx.group)
    api(member, "list_processes", %{"collection" => "molbe"})
    assert_reply(member, %{ok: true, processes: [%{id: ^id, task: %{can_complete: false}}]})

    other = open_app(ctx.other_account, ctx.group)
    api(other, "list_processes", %{"collection" => "molbe"})
    assert_reply(other, %{ok: true, processes: []})
  end

  test "the people of the task's role finish it, once", ctx do
    id = ctx.instance.id
    member = open_app(ctx.member_account, ctx.group)

    api(member, "complete_task", %{"id" => id, "element" => "odluka", "outcome" => "odobri"})
    assert_reply(member, %{ok: false, error: "forbidden"})

    owner = open_app(ctx.owner_account, ctx.group)

    api(owner, "complete_task", %{
      "id" => id,
      "element" => "odluka",
      "outcome" => "odobri",
      "comment" => "U redu."
    })

    owner_name = ctx.owner.username

    assert_reply(owner, %{
      ok: true,
      process: %{
        status: "running",
        element: "kraj",
        task: nil,
        log: [%{outcome: "odobri", comment: "U redu.", by: %{username: ^owner_name}}]
      }
    })

    api(owner, "complete_task", %{"id" => id, "element" => "odluka", "outcome" => "odbij"})
    assert_reply(owner, %{ok: false, error: "not_waiting"})
  end

  test "editors take a failed instance up again or cancel one", ctx do
    id = ctx.instance.id

    ctx.instance.id
    |> then(&Repo.get!(ValueProcess, &1))
    |> Ecto.Changeset.change(status: :failed, error: %{"element" => "odluka", "reason" => "x"})
    |> Repo.update!()

    member = open_app(ctx.member_account, ctx.group)
    api(member, "retry_process", %{"id" => id})
    assert_reply(member, %{ok: false, error: "forbidden"})

    owner = open_app(ctx.owner_account, ctx.group)
    api(owner, "retry_process", %{"id" => id})
    assert_reply(owner, %{ok: true, process: %{status: "running", error: nil}})

    api(owner, "cancel_process", %{"id" => id})
    assert_reply(owner, %{ok: true, process: %{status: "cancelled"}})

    api(owner, "cancel_process", %{"id" => id})
    assert_reply(owner, %{ok: false, error: "not_running"})
  end

  test "an instance of another app is not found", ctx do
    {:ok, elsewhere} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "elsewhere-#{System.unique_integer([:positive])}",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true,
        "home_page" => :description
      })

    view = open_app(ctx.owner_account, elsewhere)

    api(view, "complete_task", %{
      "id" => ctx.instance.id,
      "element" => "odluka",
      "outcome" => "odobri"
    })

    assert_reply(view, %{ok: false, error: "not_found"})
  end

  test "the app hears each move of an instance", ctx do
    id = ctx.instance.id
    view = open_app(ctx.owner_account, ctx.group)

    api(view, "complete_task", %{"id" => id, "element" => "odluka", "outcome" => "odbij"})
    assert_reply(view, %{ok: true})

    # The page hears of the move after its reply; a render waits for that.
    _ = render(view)
    assert_push_event(view, "app_value", %{event: "process", collection: "molbe", id: ^id})
  end
end
