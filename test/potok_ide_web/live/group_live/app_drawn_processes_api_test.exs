defmodule PotokIdeWeb.GroupLive.AppDrawnProcessesApiTest do
  @moduledoc """
  What an app sees of the processes drawn in its group: what waits for its
  viewer, a form of which opens in Potok's own dialog, a decision it may
  finish, the processes the viewer may start by hand, whose Start opens in
  Potok's dialog too, and word when what waits changes.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupEntities, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("dp-own#{unique()}")
    {member_account, member} = account_with_profile!("dp-mem#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)

    {:ok, kvar} =
      GroupEntities.create(group, Access.for_profile(owner, group), %{
        "name" => "Kvar",
        "attributes" => [
          %{"name" => "naslov", "type" => "text", "required" => true},
          %{"name" => "sprat", "type" => "number"}
        ]
      })

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      kvar: kvar.id
    }
  end

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

  defp draw!(ctx, attrs) do
    {:ok, row} = DrawnProcesses.create(ctx.owner, ctx.group, attrs)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  # A run started by hand by the member, waiting on a form that asks them.
  defp waiting_form!(ctx) do
    row =
      draw!(ctx, %{
        "trigger" => "manual",
        "name" => "Prijava",
        "graph" => chain([%{"id" => "prijava", "type" => "formTask", "entity" => ctx.kvar}])
      })

    {:ok, run} = DrawnProcesses.start(ctx.member, ctx.group, row.id, %{"title" => "lift"})
    %ValueProcess{status: :waiting} = Engine.run(run.id)
    run
  end

  defp open_app(account, group) do
    {:ok, view, _html} =
      build_conn() |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp api(view, method, params \\ %{}) do
    render_hook(view, "app_api", %{"method" => method, "params" => params})
  end

  test "lists what waits for the viewer, and opens a form in Potok's dialog", ctx do
    run = waiting_form!(ctx)
    id = run.id
    view = open_app(ctx.member_account, ctx.group)

    api(view, "list_waiting")

    assert_reply(view, %{
      ok: true,
      tasks: [
        %{
          id: ^id,
          kind: "form",
          label: "Kvar",
          process: %{name: "Prijava"},
          started_by_viewer: true,
          attributes: [%{"name" => "naslov"}, %{"name" => "sprat"}]
        }
      ]
    })

    refute has_element?(view, "#process-form-dialog")
    api(view, "open_process_form", %{"id" => id})
    assert_reply(view, %{ok: true})
    assert has_element?(view, "#process-form-dialog #process-form input[name='answers[naslov]']")

    # Nothing waits for the owner.
    owner = open_app(ctx.owner_account, ctx.group)
    api(owner, "list_waiting")
    assert_reply(owner, %{ok: true, tasks: []})
    api(owner, "open_process_form", %{"id" => id})
    assert_reply(owner, %{ok: false, error: "not_found"})
  end

  test "hears when what waits changes", ctx do
    view = open_app(ctx.member_account, ctx.group)
    _run = waiting_form!(ctx)

    # The run told the page before it returned: a render waits for the page.
    _ = render(view)
    assert_push_event(view, "app_waiting_changed", %{host: "page"}, 2_000)
  end

  test "finishes a drawn decision that waits for the viewer", ctx do
    row =
      draw!(ctx, %{
        "trigger" => "manual",
        "name" => "Odluka",
        "graph" => %{
          "v" => 2,
          "nodes" => [
            %{"id" => "start", "type" => "startEvent"},
            %{
              "id" => "odluka",
              "type" => "userTask",
              "role" => "admin",
              "outcomes" => ["da", "ne"]
            },
            %{"id" => "kraj", "type" => "endEvent"}
          ],
          "flows" => [
            %{"from" => "start", "to" => "odluka"},
            %{"from" => "odluka", "to" => "kraj", "outcome" => "da"},
            %{"from" => "odluka", "to" => "kraj", "outcome" => "ne"}
          ]
        }
      })

    {:ok, run} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => "budžet"})
    %ValueProcess{status: :waiting} = Engine.run(run.id)
    id = run.id

    owner = open_app(ctx.owner_account, ctx.group)
    api(owner, "list_waiting")

    assert_reply(owner, %{ok: true, tasks: [%{id: ^id, kind: "decision", outcomes: ["da", "ne"]}]})

    api(owner, "complete_task", %{"id" => id, "element" => "odluka", "outcome" => "da"})
    assert_reply(owner, %{ok: true})
    assert %ValueProcess{element: "kraj"} = Repo.get!(ValueProcess, id)

    # The member holds no role it asks.
    member = open_app(ctx.member_account, ctx.group)
    api(member, "complete_task", %{"id" => id, "element" => "odluka", "outcome" => "ne"})
    assert_reply(member, %{ok: false})
  end

  test "lists the processes the viewer may start, and opens a Start with what the app filled in",
       ctx do
    row =
      draw!(ctx, %{
        "trigger" => "manual",
        "name" => "Hitno",
        "entry_entity_id" => ctx.kvar,
        "graph" => chain([])
      })

    _off =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => "Isključen",
        "graph" => chain([])
      })

    id = row.id
    view = open_app(ctx.member_account, ctx.group)
    api(view, "list_startable")

    assert_reply(view, %{
      ok: true,
      processes: [%{id: ^id, name: "Hitno", takes: "entity", attributes: [_, _]}]
    })

    api(view, "open_process_start", %{"id" => id, "prefill" => %{"naslov" => "Curi voda"}})
    assert_reply(view, %{ok: true})

    assert has_element?(
             view,
             "#process-start-dialog input[name='start[naslov]'][value='Curi voda']"
           )
  end

  test "a guest is refused", ctx do
    {:ok, public} =
      Social.update_group(ctx.owner, ctx.group, %{
        "is_public" => true,
        "description_for_guests" => true
      })

    {:ok, view, _html} = live(build_conn(), ~p"/groups/#{public.id}/group_home")
    api(view, "list_waiting")
    assert_reply(view, %{ok: false})
  end
end
