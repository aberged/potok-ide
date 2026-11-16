defmodule PotokIdeWeb.GroupLive.ProcessesTabTest do
  @moduledoc """
  The group's Processes tab: there for the members of a group with an app,
  it lists the processes of its apps and those drawn in Potok, and lets the
  people of a drawn task's role decide it, as no app shows it to them.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, DrawnProcesses}

  setup do
    {owner_account, owner} = account_with_profile!("pt-owner")
    {member_account, member} = account_with_profile!("pt-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "processes-tab",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, _role} = Social.assign_group_member_role(owner, group, owner.id, savet.key)
    group = Social.get_group!(group.id)

    {:ok, _config} =
      AppData.save_config(owner, group, nil, %{"rules" => %{"molbe" => %{}}}, 0)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group,
      savet: savet.key
    }
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp graph(savet) do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{
          "id" => "odluka",
          "type" => "userTask",
          "label" => "Savet odlučuje",
          "role" => savet,
          "outcomes" => ["Odobri", "Odbij"]
        },
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "odluka"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "Odobri"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "Odbij"}
      ]
    }
  end

  defp draw!(ctx, on? \\ true) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "alt_id" => nil,
        "collection" => "molbe",
        "name" => "Savet MZ",
        "graph" => graph(ctx.savet)
      })

    if on? do
      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      row
    else
      row
    end
  end

  defp waiting!(ctx) do
    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{
        "naslov" => "Klupa u parku"
      })

    instance = Repo.get_by!(ValueProcess, value_id: value.id)
    Engine.run(instance.id)
    instance
  end

  test "the group's menu leads to it where the group has an app", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

    lv |> element("#group-tab-processes") |> render_click()

    assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#group-processes-empty")
  end

  test "a group without an app has it for its editors, who may draw there", ctx do
    {:ok, plain} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "plain",
        "description" => "",
        "description_format" => :markdown,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, plain, ctx.member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.member)

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{plain.id}/processes")
    assert has_element?(lv, "#group-tab-processes")
    assert has_element?(lv, "#processes-new")

    {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{plain.id}/processes")
    refute has_element?(member_lv, "#group-tab-processes")
    refute has_element?(member_lv, "#group-panel-processes")
  end

  test "the people of a drawn task's role decide it here, with the value", ctx do
    row = draw!(ctx)
    instance = waiting!(ctx)

    {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    refute has_element?(member_lv, "#process-task-#{instance.id}")
    assert has_element?(member_lv, "#process-row-#{row.id}-kind", "drawn")
    assert has_element?(member_lv, "#process-row-#{row.id}-count-waiting", "Waiting: 1")

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-task-#{instance.id}", "Savet odlučuje")
    assert has_element?(lv, "#process-task-#{instance.id}-data", "Klupa u parku")
    assert has_element?(lv, "#process-task-#{instance.id}", ctx.member.username)

    lv
    |> form("#process-task-#{instance.id}-form", %{"comment" => "Može."})
    |> render_submit(%{"outcome" => "Odobri"})

    refute has_element?(lv, "#process-task-#{instance.id}")

    assert %ValueProcess{element: "kraj", log: [%{"outcome" => "Odobri", "comment" => "Može."}]} =
             Repo.get!(ValueProcess, instance.id)
  end

  test "an editor cancels a run that stopped", ctx do
    draw!(ctx)
    instance = waiting!(ctx)

    instance
    |> Ecto.Changeset.change(
      status: :failed,
      error: %{"element" => "odluka", "reason" => "crash"}
    )
    |> Repo.update!()

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    lv |> element("#process-instance-#{instance.id}-cancel") |> render_click()

    refute has_element?(lv, "#process-instance-#{instance.id}")
    assert %ValueProcess{status: :cancelled} = Repo.get!(ValueProcess, instance.id)
  end

  test "a run another process called shows who called it, and why a caller stopped", ctx do
    {:ok, callee} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "process",
        "trigger_config" => %{"fields" => ["kvar"]},
        "name" => "Majstor",
        "graph" => graph(ctx.savet)
      })

    {:ok, callee} = DrawnProcesses.activate(ctx.owner, ctx.group, callee.id)

    {:ok, caller} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => "Prijava",
        "graph" => %{
          "nodes" => [
            %{"id" => "start", "type" => "startEvent"},
            %{
              "id" => "majstor",
              "type" => "callActivity",
              "process" => callee.id,
              "fields" => %{"kvar" => "{{title}}"}
            },
            %{"id" => "kraj", "type" => "endEvent"}
          ],
          "flows" => [
            %{"from" => "start", "to" => "majstor"},
            %{"from" => "majstor", "to" => "kraj"}
          ]
        }
      })

    {:ok, caller} = DrawnProcesses.activate(ctx.owner, ctx.group, caller.id)
    {:ok, run} = DrawnProcesses.start(ctx.owner, ctx.group, caller.id, %{"title" => "Lift"})
    Engine.run(run.id)
    child = Repo.get_by!(ValueProcess, app_process_id: callee.id)
    Engine.run(child.id)

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-task-#{child.id}", "Called by")
    assert has_element?(lv, "#process-task-#{child.id}-subject", "Prijava")
    assert has_element?(lv, "#process-task-#{child.id}-data", "Lift")

    {:ok, _cancelled} = Engine.cancel(child.id)
    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-instance-#{run.id}", "the process it called was cancelled")
  end

  test "the app's editors see the fields of the group, and delete them", ctx do
    field =
      Repo.insert!(%PotokIde.Processes.GroupField{
        group_id: ctx.group.id,
        name: "kvarova",
        value: "3"
      })

    {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    refute has_element?(member_lv, "#group-fields")

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#group-field-#{field.id}", "kvarova")
    assert has_element?(lv, "#group-field-#{field.id}", "3")

    lv |> element("#group-field-#{field.id}-delete") |> render_click()
    refute has_element?(lv, "#group-fields")
  end

  describe "entities" do
    alias PotokIde.Processes.GroupEntities
    alias PotokIde.Social.Access

    defp entity!(ctx, name, attributes) do
      access = Access.for_profile(ctx.owner, ctx.group)

      {:ok, entity} =
        GroupEntities.create(ctx.group, access, %{"name" => name, "attributes" => attributes})

      entity
    end

    test "only the app's editors see them", ctx do
      entity = entity!(ctx, "Stan", [%{"name" => "broj", "type" => "number"}])

      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(member_lv, "#group-entities")

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#group-entity-#{entity.id}", "Stan")
      assert has_element?(lv, "#group-entity-#{entity.id}", "broj")
      assert has_element?(lv, "#group-entity-#{entity.id}", "number")
    end

    test "an editor defines one, row by row", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(lv, "#entity-dialog")

      lv |> element("#group-entity-new") |> render_click()
      assert has_element?(lv, "#entity-dialog #entity-attribute-0")

      # A second row, and the first one becomes a choice.
      lv
      |> form("#entity-form")
      |> render_change(%{
        "entity" => %{
          "name" => "Prijava kvara",
          "attributes" => %{"0" => %{"name" => "vrsta", "type" => "choice"}},
          "attributes_sort" => ["0", "new"]
        }
      })

      assert has_element?(lv, "#entity-attribute-0 input[name='entity[attributes][0][options]']")
      assert has_element?(lv, "#entity-attribute-1")

      lv
      |> form("#entity-form")
      |> render_submit(%{
        "entity" => %{
          "name" => "Prijava kvara",
          "attributes" => %{
            "0" => %{"name" => "vrsta", "type" => "choice", "options" => "voda, struja"},
            "1" => %{"name" => "sprat", "type" => "number", "required" => "true"}
          }
        }
      })

      refute has_element?(lv, "#entity-dialog")

      assert [%{name: "Prijava kvara", attributes: [vrsta, sprat]}] =
               GroupEntities.list(ctx.group)

      assert %{name: "vrsta", type: "choice", options: ["voda", "struja"]} = vrsta
      assert %{name: "sprat", type: "number", required: true} = sprat
      assert has_element?(lv, "#group-entities-list", "Prijava kvara")
    end

    test "what is wrong shows in the form", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      lv |> element("#group-entity-new") |> render_click()

      lv
      |> form("#entity-form")
      |> render_submit(%{
        "entity" => %{
          "name" => "Stan",
          "attributes" => %{
            "0" => %{"name" => "broj", "type" => "number"},
            "1" => %{"name" => "broj", "type" => "text"}
          },
          "attributes_sort" => ["0", "1"]
        }
      })

      assert has_element?(lv, "#entity-dialog .entity-form-error")
      assert GroupEntities.list(ctx.group) == []
    end

    test "an editor changes one, holds another in it and deletes it", ctx do
      stan = entity!(ctx, "Stan", [%{"name" => "broj", "type" => "number"}])
      zgrada = entity!(ctx, "Zgrada", [%{"name" => "adresa", "type" => "text"}])
      [adresa] = zgrada.attributes

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      lv |> element("#group-entity-#{zgrada.id}-edit") |> render_click()
      assert has_element?(lv, "#entity-dialog", "Zgrada")

      lv
      |> form("#entity-form")
      |> render_change(%{
        "entity" => %{
          "attributes" => %{"0" => %{"id" => adresa.id, "name" => "adresa", "type" => "text"}},
          "attributes_sort" => ["0", "new"]
        }
      })

      lv
      |> form("#entity-form")
      |> render_change(%{
        "entity" => %{
          "attributes" => %{
            "0" => %{"id" => adresa.id, "name" => "adresa", "type" => "text"},
            "1" => %{"name" => "stanovi", "type" => "entity"}
          },
          "attributes_sort" => ["0", "1"]
        }
      })

      assert has_element?(
               lv,
               "#entity-attribute-1 select[name='entity[attributes][1][entity_id]']"
             )

      lv
      |> form("#entity-form")
      |> render_submit(%{
        "entity" => %{
          "attributes" => %{
            "0" => %{"id" => adresa.id, "name" => "adresa", "type" => "text"},
            "1" => %{
              "name" => "stanovi",
              "type" => "entity",
              "entity_id" => to_string(stan.id),
              "list" => "true"
            }
          },
          "attributes_sort" => ["0", "1"]
        }
      })

      refute has_element?(lv, "#entity-dialog")
      assert has_element?(lv, "#group-entity-#{zgrada.id}", "list of Stan")

      # What another holds stays.
      lv |> element("#group-entity-#{stan.id}-edit") |> render_click()
      lv |> element("#entity-delete") |> render_click()
      assert GroupEntities.get(ctx.group, stan.id)

      lv |> element("#entity-dialog-close") |> render_click()
      lv |> element("#group-entity-#{zgrada.id}-edit") |> render_click()
      lv |> element("#entity-delete") |> render_click()
      refute has_element?(lv, "#group-entity-#{zgrada.id}")
      refute GroupEntities.get(ctx.group, zgrada.id)
    end

    test "follows what another editor defines", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(lv, "#group-entities-list")

      entity = entity!(ctx, "Stan", [%{"name" => "broj", "type" => "number"}])

      assert has_element?(lv, "#group-entity-#{entity.id}")
    end
  end

  describe "a process that takes an entity" do
    alias PotokIde.Processes.{GraphEdit, GroupEntities}
    alias PotokIde.Social.Access

    setup ctx do
      {:ok, kvar} =
        GroupEntities.create(ctx.group, Access.for_profile(ctx.owner, ctx.group), %{
          "name" => "Kvar",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"},
            %{"name" => "hitno", "type" => "boolean"},
            %{"name" => "dan", "type" => "date"},
            %{"name" => "vrsta", "type" => "choice", "options" => "voda, struja"}
          ]
        })

      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]},
          "name" => "Prijava kvara",
          "graph" => GraphEdit.new(),
          "entry_entity_id" => kvar.id
        })

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      %{kvar: kvar, row: row}
    end

    test "is started with a form that asks for its attributes", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(lv, "#process-row-#{ctx.row.id}", "takes Kvar")

      lv |> element("#process-row-#{ctx.row.id}-start") |> render_click()
      refute has_element?(lv, "#process-start-form input[name='start[title]']")
      assert has_element?(lv, "#process-start-form input[name='start[naslov]'][required]")
      assert has_element?(lv, "#process-start-form input[name='start[sprat]']")
      assert has_element?(lv, "#process-start-form input[type='checkbox'][name='start[hitno]']")
      assert has_element?(lv, "#process-start-form input[type='date'][name='start[dan]']")
      assert has_element?(lv, "#process-start-form select[name='start[vrsta]'] option", "struja")

      lv
      |> form("#process-start-form", %{"start" => %{"naslov" => "Lift", "sprat" => "treći"}})
      |> render_submit()

      assert has_element?(lv, "#process-start-error", "sprat: takes a number.")

      lv
      |> form("#process-start-form", %{
        "start" => %{
          "naslov" => "Lift",
          "sprat" => "3",
          "hitno" => "true",
          "dan" => "2026-11-16",
          "vrsta" => "voda"
        }
      })
      |> render_submit()

      refute has_element?(lv, "#process-start-form")

      assert [%{data: data}] = Repo.all(ValueProcess)

      assert data == %{
               "naslov" => "Lift",
               "sprat" => "3",
               "hitno" => true,
               "dan" => "2026-11-16",
               "vrsta" => "voda",
               "author" => ctx.member.username
             }
    end

    test "tells its editors when what it was saved with has changed", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(lv, "#process-row-#{ctx.row.id}-stale")

      {:ok, _changed} =
        GroupEntities.update(ctx.group, Access.for_profile(ctx.owner, ctx.group), ctx.kvar, %{
          "attributes" => [%{"name" => "naslov", "type" => "text"}]
        })

      assert has_element?(lv, "#process-row-#{ctx.row.id}-stale")

      # It still asks for what it was saved with.
      lv |> element("#process-row-#{ctx.row.id}-start") |> render_click()
      assert has_element?(lv, "#process-start-form input[name='start[sprat]']")

      # A member is told nothing: it is the editors' to look over.
      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(member_lv, "#process-row-#{ctx.row.id}-stale")
    end
  end

  test "a drawing that is off shows to the app's editors only", ctx do
    row = draw!(ctx, false)

    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-row-#{row.id}-off")

    {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    refute has_element?(member_lv, "#process-row-#{row.id}")
  end

  test "follows a drawing as it is switched on", ctx do
    row = draw!(ctx, false)
    {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    refute has_element?(member_lv, "#process-row-#{row.id}")

    {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

    assert has_element?(member_lv, "#process-row-#{row.id}")
  end
end
