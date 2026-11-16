defmodule PotokIdeWeb.GroupLive.ProcessFormTest do
  @moduledoc """
  The form a drawn process asks a person: it opens by itself on the group's
  page for whoever started the run, as an answer to what they just did, and
  waits on the Processes tab otherwise.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Processes
  alias PotokIde.Processes.{Engine, GroupEntities, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, DrawnProcesses}

  setup do
    {owner_account, owner} = account_with_profile!("pf-owner")
    {member_account, member} = account_with_profile!("pf-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "process-form",
        "description" => "",
        "description_format" => :markdown,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
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

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      kvar: kvar.id
    }
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp form_step(id, entity, more \\ %{}),
    do: Map.merge(%{"id" => id, "type" => "formTask", "entity" => entity}, more)

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

  defp draw!(ctx, steps) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "message",
        "trigger_config" => %{"words" => "kvar"},
        "name" => "Prijava kvara",
        "graph" => chain(steps)
      })

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  # The member writes a message with the word, and its run goes as far as it can.
  defp report!(ctx, row) do
    {:ok, _value} =
      Social.create_value(ctx.member, ctx.group, %{
        "content" => "kvar u liftu",
        "content_format" => :markdown
      })

    run = Repo.one!(from(i in ValueProcess, where: i.app_process_id == ^row.id))
    Engine.run(run.id)
  end

  defp chat(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  test "opens for whoever wrote the message that started the process", ctx do
    row =
      draw!(ctx, [
        form_step("prijava", ctx.kvar),
        %{
          "id" => "poruka",
          "type" => "serviceTask",
          "action" => "message",
          "text" => "{{prijava.naslov}}, sprat {{prijava.sprat}}"
        }
      ])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
    refute has_element?(lv, "#process-form-dialog")

    run = report!(ctx, row)

    assert has_element?(lv, "#process-form-dialog")
    # It goes by the entity it asks for, in the process that asks.
    assert has_element?(lv, "#process-form-title", "Kvar")
    assert has_element?(lv, "#process-form-dialog", "Prijava kvara")
    assert has_element?(lv, "#process-form-subject", "kvar u liftu")
    assert has_element?(lv, "#process-form input[name='answers[naslov]'][required]")
    assert has_element?(lv, "#process-form input[name='answers[sprat]']")
    assert has_element?(lv, "#process-form input[type='checkbox'][name='answers[hitno]']")

    # Nobody else is asked.
    refute has_element?(owner_lv, "#process-form-dialog")

    lv
    |> form("#process-form", %{"answers" => %{"naslov" => "Lift stoji", "sprat" => "treći"}})
    |> render_submit()

    assert has_element?(lv, "#process-form-error", "sprat: takes a number.")
    assert has_element?(lv, "#process-form input[name='answers[naslov]'][value='Lift stoji']")

    lv
    |> form("#process-form", %{
      "answers" => %{"naslov" => "Lift stoji", "sprat" => "3", "hitno" => "true"}
    })
    |> render_submit()

    refute has_element?(lv, "#process-form-dialog")

    assert %ValueProcess{element: "poruka", results: %{"prijava" => filled}} =
             Repo.get!(ValueProcess, run.id)

    assert filled == %{
             "naslov" => "Lift stoji",
             "sprat" => "3",
             "hitno" => true,
             "author" => ctx.member.username
           }

    Engine.run(run.id)
    assert "Lift stoji, sprat 3" in chat(ctx.group)
    refute has_element?(lv, "#process-form-dialog")
  end

  test "left for later, it waits on the Processes tab, where Fill in opens it", ctx do
    row = draw!(ctx, [form_step("prijava", ctx.kvar, %{"label" => "Prijava kvara u zgradi"})])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)

    assert has_element?(lv, "#process-form-title", "Prijava kvara u zgradi")
    lv |> element("#process-form-later") |> render_click()
    refute has_element?(lv, "#process-form-dialog")

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")

    # A page opened later does not open it by itself.
    refute has_element?(lv, "#process-form-dialog")
    assert has_element?(lv, "#process-task-#{run.id}", "Prijava kvara u zgradi")
    assert has_element?(lv, "#process-task-#{run.id}-subject", "kvar u liftu")
    refute has_element?(lv, "#process-task-#{run.id}-form")

    lv |> element("#process-task-#{run.id}-fill") |> render_click()
    assert has_element?(lv, "#process-form-dialog")

    lv |> form("#process-form", %{"answers" => %{"naslov" => "Lift"}}) |> render_submit()

    refute has_element?(lv, "#process-form-dialog")
    refute has_element?(lv, "#process-task-#{run.id}")
    assert Repo.get!(ValueProcess, run.id).element == "kraj"

    # The owner, whom it never asked, had nothing to fill in.
    {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    refute has_element?(owner_lv, "#process-task-#{run.id}")
  end

  test "reached after a wait, it opens for nobody and waits to be found", ctx do
    row =
      draw!(ctx, [
        %{"id" => "pauza", "type" => "timer", "duration" => "PT1H"},
        form_step("prijava", ctx.kvar)
      ])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)
    assert run.element == "pauza"

    from(i in ValueProcess, where: i.id == ^run.id)
    |> Repo.update_all(set: [wake_at: ~U[2020-01-01 00:00:00Z]])

    assert %ValueProcess{element: "prijava", status: :waiting} = Engine.run(run.id)
    refute has_element?(lv, "#process-form-dialog")

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-task-#{run.id}-fill")
  end

  test "the next form of the same run opens as the first is sent", ctx do
    row =
      draw!(ctx, [
        form_step("prijava", ctx.kvar),
        form_step("potvrda", ctx.kvar, %{"label" => "Potvrdi prijavu"})
      ])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)

    lv |> form("#process-form", %{"answers" => %{"naslov" => "Lift"}}) |> render_submit()
    refute has_element?(lv, "#process-form-dialog")

    assert %ValueProcess{element: "potvrda", status: :waiting} = Engine.run(run.id)
    assert has_element?(lv, "#process-form-title", "Potvrdi prijavu")
    assert has_element?(lv, "#process-form input[name='answers[naslov]'][value='']")
  end

  test "of a role, it opens for nobody, and one of its people fills it in", ctx do
    row = draw!(ctx, [form_step("prijava", ctx.kvar, %{"by" => "role", "role" => "admin"})])

    {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)

    refute has_element?(owner_lv, "#process-form-dialog")
    refute has_element?(lv, "#process-form-dialog")

    # The member, who is not of the role, cannot open it either.
    render_hook(lv, "process_form_open", %{"id" => run.id})
    refute has_element?(lv, "#process-form-dialog")

    {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    owner_lv |> element("#process-task-#{run.id}-fill") |> render_click()

    owner_lv
    |> form("#process-form", %{"answers" => %{"naslov" => "Lift"}})
    |> render_submit()

    refute has_element?(owner_lv, "#process-form-dialog")

    assert %ValueProcess{element: "kraj", results: %{"prijava" => %{"author" => author}}} =
             Repo.get!(ValueProcess, run.id)

    assert author == ctx.owner.username
  end

  test "open on one page, it closes when it is sent from another", ctx do
    row = draw!(ctx, [form_step("prijava", ctx.kvar)])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)
    assert has_element?(lv, "#process-form-dialog")

    access = Access.for_profile(ctx.member, ctx.group)

    assert {:ok, _presented} =
             Processes.complete_form(
               ctx.member,
               ctx.group,
               access,
               run.id,
               "prijava",
               %{"naslov" => "Lift"},
               nil
             )

    refute has_element?(lv, "#process-form-dialog")
  end
end
