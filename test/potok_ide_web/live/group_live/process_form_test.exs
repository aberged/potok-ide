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

  defp draw!(ctx, steps) when is_list(steps), do: draw!(ctx, chain(steps))

  defp draw!(ctx, graph) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "message",
        "trigger_config" => %{"words" => "kvar"},
        "name" => "Prijava kvara",
        "graph" => graph
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

  test "says what its process put first, and starts with what the message said", ctx do
    row =
      draw!(ctx, [
        form_step("prijava", ctx.kvar, %{
          "intro" => "Hvala! Još samo sprat, ako znaš.",
          "values" => %{"naslov" => "{{start.text}}", "hitno" => "true"}
        })
      ])

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
    run = report!(ctx, row)

    assert has_element?(lv, "#process-form-intro", "Hvala! Još samo sprat, ako znaš.")
    assert has_element?(lv, "#process-form input[name='answers[naslov]'][value='kvar u liftu']")
    assert has_element?(lv, "#process-form input[name='answers[sprat]'][value='']")

    assert has_element?(
             lv,
             "#process-form input[type='checkbox'][name='answers[hitno]'][checked]"
           )

    lv
    |> form("#process-form", %{"answers" => %{"naslov" => "kvar u liftu", "sprat" => "2"}})
    |> render_submit()

    assert %{"naslov" => "kvar u liftu", "sprat" => "2", "hitno" => true} =
             Repo.get!(ValueProcess, run.id).results["prijava"]

    # Left for later, the card on the tab says it too.
    run = report_again!(ctx, row)
    lv |> element("#process-form-later") |> render_click()

    {:ok, tab, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(tab, "#process-task-#{run.id}-intro", "Hvala! Još samo sprat")
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

  describe "what waits for the viewer" do
    test "is counted in the page's header, on every tab but the one that lists it", ctx do
      row = draw!(ctx, [form_step("prijava", ctx.kvar)])

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      refute has_element?(lv, "#group-waiting")
      refute has_element?(lv, "#group-tab-processes-waiting")

      run = report!(ctx, row)

      assert has_element?(lv, "#group-waiting-count", "1")
      assert has_element?(lv, "#group-waiting[aria-label='Waiting for you: 1']")
      assert has_element?(lv, "#group-tab-processes-waiting", "1")
      # It is nobody else's.
      refute has_element?(owner_lv, "#group-waiting")

      lv |> element("#process-form-later") |> render_click()
      lv |> element("#group-waiting") |> render_click()

      assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#process-task-#{run.id}-fill")
      refute has_element?(lv, "#group-waiting")
      assert has_element?(lv, "#group-tab-processes-waiting", "1")

      # A page opened later counts it too, and stops once the form is sent.
      {:ok, later_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")
      assert has_element?(later_lv, "#group-waiting-count", "1")

      lv |> element("#process-task-#{run.id}-fill") |> render_click()
      lv |> form("#process-form", %{"answers" => %{"naslov" => "Lift"}}) |> render_submit()

      refute has_element?(later_lv, "#group-waiting")
      refute has_element?(lv, "#group-tab-processes-waiting")
    end

    test "counts the decisions of the viewer's roles, and nobody else's", ctx do
      row =
        draw!(ctx, %{
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
        })

      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      run = report!(ctx, row)
      second = report_again!(ctx, row)

      assert has_element?(owner_lv, "#group-waiting-count", "2")
      refute has_element?(lv, "#group-waiting")

      access = Access.for_profile(ctx.owner, ctx.group)

      assert {:ok, _presented} =
               Processes.complete_task(
                 ctx.owner,
                 ctx.group,
                 :any,
                 access,
                 run.id,
                 "odluka",
                 "Primljeno",
                 nil
               )

      assert has_element?(owner_lv, "#group-waiting-count", "1")

      # A process switched off asks nobody.
      {:ok, _off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, row.id)
      refute has_element?(owner_lv, "#group-waiting")
      assert Repo.get!(ValueProcess, second.id).status == :cancelled
    end
  end

  describe "what waits for the viewer, outside the group" do
    defp fill_in!(ctx, run, answers \\ %{"naslov" => "Lift"}) do
      {:ok, _presented} =
        Processes.complete_form(
          ctx.member,
          ctx.group,
          Access.for_profile(ctx.member, ctx.group),
          run.id,
          "prijava",
          answers,
          nil
        )

      Engine.run(run.id)
    end

    test "is counted on the hand in the bar, on every page, as it comes and goes", ctx do
      row = draw!(ctx, [form_step("prijava", ctx.kvar)])

      {:ok, tags, _html} = live_as(ctx.member_account, ~p"/tags")
      assert has_element?(tags, "#nav-requests-count-badge[hidden]")

      run = report!(ctx, row)

      assert Processes.waiting_by_group(ctx.member) == %{ctx.group.id => 1}
      assert Social.nav_counts(ctx.member).pending_group_join_requests == 1

      # A page open elsewhere hears of it and counts again.
      render(tags)
      refute has_element?(tags, "#nav-requests-count-badge[hidden]")
      assert has_element?(tags, "#nav-requests-count-badge", "1")

      fill_in!(ctx, run)
      render(tags)
      assert has_element?(tags, "#nav-requests-count-badge[hidden]")
      assert Social.nav_counts(ctx.member).pending_group_join_requests == 0
    end

    test "is listed under Requests, where a form opens in its group at once", ctx do
      row = draw!(ctx, [form_step("prijava", ctx.kvar, %{"label" => "Prijavi kvar"})])
      run = report!(ctx, row)

      # With nothing to approve, the page opens on what waits.
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/requests")
      assert has_element?(lv, "#requests-tab-processes[aria-selected='true']")
      assert has_element?(lv, "#waiting-group-#{ctx.group.id}")
      assert has_element?(lv, "#waiting-task-#{run.id}", "Prijavi kvar")

      path = ~p"/groups/#{ctx.group.id}/processes?#{[form: run.id]}"
      assert has_element?(lv, "#waiting-task-#{run.id} a[href='#{path}']")

      {:ok, group_lv, _html} = live_as(ctx.member_account, path)
      assert has_element?(group_lv, "#process-form-dialog")
      assert has_element?(group_lv, "#process-form-title", "Prijavi kvar")

      # Filled in elsewhere, it goes from the list.
      fill_in!(ctx, run)
      render(lv)
      refute has_element?(lv, "#waiting-task-#{run.id}")
      assert has_element?(lv, "#requests-processes-empty")
    end

    test "the decisions of a role are listed under Requests too, and lead to their tab", ctx do
      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "odluka", "type" => "userTask", "role" => "admin", "outcomes" => ["Da"]},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "odluka"},
          %{"from" => "odluka", "to" => "kraj", "outcome" => "Da"}
        ]
      }

      run = report!(ctx, draw!(ctx, graph))

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/requests?section=processes")
      assert has_element?(lv, "#waiting-task-#{run.id}", "decision")

      assert has_element?(
               lv,
               "#waiting-task-#{run.id} a[href='/groups/#{ctx.group.id}/processes']"
             )

      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/requests?section=processes")
      assert has_element?(member_lv, "#requests-processes-empty")
    end

    test "marks the rows of the groups it waits in, and those above them", ctx do
      {:ok, child} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "Ulaz A",
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat
        })

      {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, child, ctx.member)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.member)
      child = Social.get_group!(child.id)

      {:ok, kvar} =
        GroupEntities.create(child, Access.for_profile(ctx.owner, child), %{
          "name" => "Kvar",
          "attributes" => [%{"name" => "naslov", "type" => "text", "required" => true}]
        })

      {:ok, row} =
        DrawnProcesses.create(ctx.owner, child, %{
          "trigger" => "message",
          "trigger_config" => %{"words" => "kvar"},
          "name" => "Kvar u ulazu",
          "graph" => chain([form_step("prijava", kvar.id)])
        })

      {:ok, row} = DrawnProcesses.activate(ctx.owner, child, row.id)

      {:ok, list, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/sub_groups")
      refute has_element?(list, "#child-group-waiting-#{child.id}")

      {:ok, _value} =
        Social.create_value(ctx.member, child, %{
          "content" => "kvar na vratima",
          "content_format" => :markdown
        })

      run = Repo.one!(from(i in ValueProcess, where: i.app_process_id == ^row.id))
      run = Engine.run(run.id)

      # Up the tree to the root, as unread values add up.
      root = Social.get_root_group!()

      assert Social.waiting_overview(ctx.member) ==
               %{child.id => 1, ctx.group.id => 1, root.id => 1}

      # The open list hears of it, and the folder view shows it on every level.
      render(list)
      assert has_element?(list, "#child-group-waiting-#{child.id}", "1")

      {:ok, tree, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/sub_groups?view=tree")

      assert has_element?(tree, "#sub-group-folder-waiting-#{child.id}", "1")

      {:ok, home, _html} = live_as(ctx.member_account, ~p"/groups/#{root.id}")
      assert has_element?(home, "#child-group-waiting-#{ctx.group.id}", "1")

      {:ok, _presented} =
        Processes.complete_form(
          ctx.member,
          child,
          Access.for_profile(ctx.member, child),
          run.id,
          "prijava",
          %{"naslov" => "Vrata"},
          nil
        )

      render(list)
      refute has_element?(list, "#child-group-waiting-#{child.id}")
      render(home)
      refute has_element?(home, "#child-group-waiting-#{ctx.group.id}")
    end
  end

  # One more message with the word, and its run taken as far as it goes.
  defp report_again!(ctx, row) do
    {:ok, value} =
      Social.create_value(ctx.member, ctx.group, %{
        "content" => "još jedan kvar",
        "content_format" => :markdown
      })

    run =
      Repo.one!(
        from(i in ValueProcess,
          where: i.app_process_id == ^row.id and i.value_id == ^value.id
        )
      )

    Engine.run(run.id)
  end

  describe "an entity that holds a list and another entity" do
    setup ctx do
      access = Access.for_profile(ctx.owner, ctx.group)

      {:ok, stan} =
        GroupEntities.create(ctx.group, access, %{
          "name" => "Stan",
          "attributes" => [%{"name" => "broj", "type" => "number", "required" => true}]
        })

      {:ok, stavka} =
        GroupEntities.create(ctx.group, access, %{
          "name" => "Stavka",
          "attributes" => [
            %{"name" => "naziv", "type" => "text", "required" => true},
            %{"name" => "komada", "type" => "number"}
          ]
        })

      {:ok, narudzbina} =
        GroupEntities.create(ctx.group, access, %{
          "name" => "Narudžbina",
          "attributes" => [
            %{"name" => "stan", "type" => "entity", "entity_id" => stan.id},
            %{"name" => "stavke", "type" => "entity", "entity_id" => stavka.id, "list" => true},
            %{"name" => "napomene", "type" => "text", "list" => true}
          ]
        })

      %{order: narudzbina.id}
    end

    test "asks for it item by item, adds and takes out items, and says where one is wrong",
         ctx do
      row =
        draw!(ctx, [
          form_step("prijava", ctx.order),
          %{
            "id" => "poruka",
            "type" => "serviceTask",
            "action" => "message",
            "text" => "{{length(prijava.stavke)}} za stan {{prijava.stan.broj}}"
          }
        ])

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      run = report!(ctx, row)

      # Each list starts with one item; the entity it holds is a group of its own.
      assert has_element?(lv, "#process-form input[name='answers[stan][broj]']")
      assert has_element?(lv, "#process-form input[name='answers[stavke][0][naziv]']")
      assert has_element?(lv, "#process-form input[name='answers[napomene][0]']")

      lv |> element("#process-form-field-stavke-add") |> render_click()
      lv |> element("#process-form-field-stavke-add") |> render_click()
      assert has_element?(lv, "#process-form input[name='answers[stavke][2][naziv]']")

      lv |> element("#process-form-field-stavke-1-remove") |> render_click()
      refute has_element?(lv, "#process-form input[name='answers[stavke][1][naziv]']")

      answers = %{
        "stan" => %{"broj" => "12"},
        "stavke" => %{
          "0" => %{"naziv" => "Mleko", "komada" => "2"},
          "2" => %{"naziv" => "Jaja", "komada" => "deset"}
        },
        "napomene" => %{"0" => "  "}
      }

      lv |> form("#process-form", %{"answers" => answers}) |> render_submit()

      # The second item sent is the one keyed 2: its input says what is wrong.
      assert has_element?(lv, "#process-form-error", "stavke.1.komada: takes a number.")
      assert has_element?(lv, "#process-form-field-stavke-2-komada.input-error")
      refute has_element?(lv, "#process-form-field-stavke-0-komada.input-error")

      answers = put_in(answers, ["stavke", "2", "komada"], "10")
      lv |> form("#process-form", %{"answers" => answers}) |> render_submit()
      refute has_element?(lv, "#process-form-dialog")

      assert %ValueProcess{results: %{"prijava" => filled}} = Repo.get!(ValueProcess, run.id)

      assert filled == %{
               "stan" => %{"broj" => "12"},
               "stavke" => [
                 %{"naziv" => "Mleko", "komada" => "2"},
                 %{"naziv" => "Jaja", "komada" => "10"}
               ],
               "napomene" => [],
               "author" => ctx.member.username
             }

      Engine.run(run.id)
      assert "2 za stan 12" in chat(ctx.group)
    end

    test "a Start form asks for it the same way", ctx do
      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Narudžba",
          "entry_entity_id" => ctx.order,
          "graph" =>
            chain([
              %{
                "id" => "poruka",
                "type" => "serviceTask",
                "action" => "message",
                "text" => "{{start.stavke[0].naziv}}, stan {{start.stan.broj}}"
              }
            ])
        })

      {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      render_click(lv, "processes_start_open", %{"id" => to_string(row.id)})

      # On the page, wherever the viewer is.
      assert has_element?(lv, "#process-start-form input[name='start[stavke][0][naziv]']")
      lv |> element("#process-start-field-napomene-add") |> render_click()
      assert has_element?(lv, "#process-start-form input[name='start[napomene][1]']")

      lv
      |> form("#process-start-form", %{
        "start" => %{
          "stan" => %{"broj" => "4"},
          "stavke" => %{"0" => %{"naziv" => "Hleb", "komada" => ""}},
          "napomene" => %{"0" => "", "1" => "brzo"}
        }
      })
      |> render_submit()

      refute has_element?(lv, "#process-start-dialog")
      [run] = Repo.all(from(i in ValueProcess, where: i.app_process_id == ^row.id))

      assert run.data["stavke"] == [%{"naziv" => "Hleb", "komada" => nil}]
      assert run.data["napomene"] == ["brzo"]
      assert run.data["stan"] == %{"broj" => "4"}
    end
  end
end
