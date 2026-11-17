defmodule PotokIdeWeb.GroupLive.ProcessEditorTest do
  @moduledoc """
  Drawing a process on the group's Processes tab: the app's editors draw,
  save and switch it on; everyone else and every app's own process are
  shown as they are, to look at.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, AppProcess, DrawnProcesses}

  setup do
    {owner_account, owner} = account_with_profile!("pe-owner")
    {member_account, member} = account_with_profile!("pe-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "process-editor",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)

    {:ok, _config} = AppData.save_config(owner, group, nil, %{"rules" => %{"molbe" => %{}}}, 0)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  defp live_as(account, path), do: build_conn() |> log_in_account(account) |> live(path)

  defp canvas(lv), do: element(lv, "#process-canvas")

  defp insert(lv, flow, kind) do
    render_hook(canvas(lv), "process_editor_insert_menu", %{"flow" => flow})
    lv |> element("#process-insert-#{kind}") |> render_click()
  end

  defp drawn(group), do: DrawnProcesses.list(group)

  test "an editor draws a new process, saves it and switches it on", ctx do
    {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")

    lv |> element("#processes-new") |> render_click()
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes?process=new")

    assert has_element?(lv, "#process-editor")
    assert has_element?(lv, ~s(#process-canvas[data-editable="true"]))
    assert has_element?(lv, "#process-outline-start")
    assert has_element?(lv, "#process-outline-end")

    insert(lv, "f1", "task")
    assert has_element?(lv, "#process-outline-task_1")
    assert has_element?(lv, "#process-node-panel")
    assert has_element?(lv, "#process-add-outcome")

    lv
    |> form("#process-element-form", %{
      "element" => %{"deadline_amount" => "7", "deadline_unit" => "days"}
    })
    |> render_change()

    assert has_element?(lv, "#process-outline-task_1", "1 week")
    assert has_element?(lv, "#process-outline-push_1")

    lv
    |> form("#process-editor-meta", %{"meta" => %{"name" => "Savet odlučuje"}})
    |> render_change()

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{name: "Savet odlučuje", active: false} = row] = drawn(ctx.group)
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")
    assert Enum.any?(row.graph["nodes"], &(&1["type"] == "userTask" and &1["deadline"] == "P7D"))

    lv |> element("#process-editor-activate") |> render_click()

    assert %AppProcess{active: true} = Repo.get!(AppProcess, row.id)
    assert has_element?(lv, "#process-editor-state", "on")
  end

  test "a new process starts on what its editor picks, set on its start step", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    assert has_element?(lv, "#process-editor-collection")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "message"}}) |> render_change()
    refute has_element?(lv, "#process-editor-collection")

    # Without a word or a role a message would start it every time.
    assert has_element?(lv, "#process-editor-error", "Type a word")
    assert has_element?(lv, "#process-editor-save[disabled]")

    render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
    assert has_element?(lv, "#process-trigger-form")

    lv
    |> form("#process-trigger-form", %{"trigger" => %{"words" => "kvar, curi"}})
    |> render_change()

    refute has_element?(lv, "#process-editor-error")
    assert has_element?(lv, "#process-outline-start", "A message with: kvar, curi")

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{trigger: "message", collection: nil} = row] = drawn(ctx.group)
    assert row.trigger_config == %{"words" => ["kvar", "curi"], "role" => nil}
  end

  test "a process started by hand gets a Start button and a form", ctx do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "trigger_config" => %{"roles" => ["everyone"]},
        "name" => "Prijava kvara",
        "graph" => PotokIde.Processes.GraphEdit.new()
      })

    {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes")
    assert has_element?(lv, "#process-row-#{row.id}", "Started by:")

    lv |> element("#process-row-#{row.id}-start") |> render_click()
    assert has_element?(lv, "#process-start-form")

    lv |> form("#process-start-form", %{"start" => %{"title" => " "}}) |> render_submit()
    assert has_element?(lv, "#process-start-error")

    lv
    |> form("#process-start-form", %{
      "start" => %{"title" => "Lift stoji", "text" => "Od jutros."}
    })
    |> render_submit()

    refute has_element?(lv, "#process-start-form")

    assert [%{data: %{"title" => "Lift stoji"}}] =
             Repo.all(PotokIde.Processes.ValueProcess)
  end

  test "a process takes calls on the fields its editor names", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "process"}}) |> render_change()
    render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})

    lv
    |> form("#process-trigger-form", %{"trigger" => %{"fields" => "kvar, from"}})
    |> render_change()

    assert has_element?(lv, "#process-editor-error", "from and outcome are taken")

    lv
    |> form("#process-trigger-form", %{"trigger" => %{"fields" => "kvar, sprat"}})
    |> render_change()

    assert has_element?(lv, "#process-outline-start", "Called with: kvar, sprat")
    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{trigger: "process", trigger_config: %{"fields" => ["kvar", "sprat"]}}] =
             drawn(ctx.group)
  end

  test "a call starts a process of the group with the fields it takes", ctx do
    {:ok, callee} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "process",
        "trigger_config" => %{"fields" => ["kvar"]},
        "name" => "Majstor",
        "graph" => PotokIde.Processes.GraphEdit.new()
      })

    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
    insert(lv, "f1", "call")
    assert has_element?(lv, "#process-outline-call_1", "Call Majstor")
    assert has_element?(lv, "#process-call-field-kvar")

    lv
    |> form("#process-element-form", %{
      "element" => %{
        "process" => to_string(callee.id),
        "wait" => "true",
        "fields" => %{"kvar" => "Kvar: "},
        "deadline_amount" => "3",
        "deadline_unit" => "days"
      }
    })
    |> render_change()

    lv
    |> element("#process-field-fields\\.kvar-0")
    |> render_click()

    assert has_element?(lv, "#process-outline-call_1", "3 days")

    lv |> element("#process-editor-save") |> render_click()

    assert [_callee, %AppProcess{graph: graph}] = Enum.sort_by(drawn(ctx.group), & &1.id)

    assert %{"process" => id, "wait" => true, "deadline" => "P3D", "fields" => fields} =
             Enum.find(graph["nodes"], &(&1["type"] == "callActivity"))

    assert id == callee.id
    assert fields["kvar"] =~ "Kvar: {{"

    assert {:error, {:in_use, "New process"}} =
             DrawnProcesses.delete(ctx.owner, ctx.group, callee.id)
  end

  test "a step keeps a field of the group, which every process reads", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
    insert(lv, "f1", "set")

    lv
    |> form("#process-element-form", %{
      "element" => %{"field" => "kvarova", "op" => "add", "value" => "1"}
    })
    |> render_change()

    assert has_element?(lv, "#process-outline-set_1", "kvarova")

    insert(lv, "f2", "message")
    assert has_element?(lv, "#process-field-text-3", "group.kvarova")

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{graph: graph}] = drawn(ctx.group)

    assert %{"field" => "kvarova", "op" => "add", "value" => "1"} =
             Enum.find(graph["nodes"], &(&1["action"] == "set"))
  end

  test "a process sends a signal with fields, and another waits for it or starts on it",
       ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
    insert(lv, "f1", "signal")

    lv
    |> form("#process-element-form", %{"element" => %{"name" => " Subota "}})
    |> render_change()

    lv |> element("#process-add-signal-field") |> render_click()

    lv
    |> form("#process-element-form", %{
      "element" => %{"signal_fields" => %{"0" => %{"name" => "mesto", "value" => "Dvorište "}}}
    })
    |> render_change()

    lv |> element("#process-field-signal_fields\\.0-0") |> render_click()
    assert has_element?(lv, "#process-outline-signal_1", "Signal subota")

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{graph: graph}] = drawn(ctx.group)

    assert %{"name" => "subota", "fields" => [%{"name" => "mesto", "value" => value}]} =
             Enum.find(graph["nodes"], &(&1["action"] == "signal"))

    assert value =~ "Dvorište {{"

    # Another process waits for it, and offers what it carries.
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
    insert(lv, "f1", "receive")
    assert has_element?(lv, "#process-outline-receive_1", "subota")

    lv
    |> form("#process-element-form", %{
      "element" => %{
        "same_subject" => "true",
        "deadline_amount" => "2",
        "deadline_unit" => "days"
      }
    })
    |> render_change()

    assert has_element?(lv, "#process-outline-receive_1", "2 days")
    insert(lv, "f2", "message")
    assert has_element?(lv, "#process-element-form button", "receive_1.mesto")

    # And a third starts on it.
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "signal"}}) |> render_change()
    render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})

    lv
    |> form("#process-trigger-form", %{"trigger" => %{"name" => "subota"}})
    |> render_change()

    assert has_element?(lv, "#process-outline-start", "On the signal subota")
  end

  test "an unfinished drawing says what is wrong and is not saved", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    insert(lv, "f1", "message")

    lv
    |> form("#process-element-form", %{"element" => %{"text" => " "}})
    |> render_change()

    assert has_element?(lv, "#process-editor-error", "The text is empty or too long.")
    assert has_element?(lv, "#process-editor-save[disabled]")
    assert drawn(ctx.group) == []
  end

  test "steps go and branches come, and the drawing stays whole", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    insert(lv, "f1", "message")
    insert(lv, "f1", "task")
    lv |> element("#process-add-outcome") |> render_click()
    refute has_element?(lv, "#process-editor-error")

    render_hook(canvas(lv), "process_editor_select", %{"node" => "message_1"})
    lv |> element("#process-node-delete") |> render_click()

    refute has_element?(lv, "#process-outline-message_1")
    assert has_element?(lv, "#process-outline-task_1")
    refute has_element?(lv, "#process-editor-error")
  end

  test "the places of the steps on a wide screen are kept", ctx do
    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

    render_hook(canvas(lv), "process_editor_move", %{
      "positions" => %{"start" => [0, 0], "end" => [40, 200.4], "nope" => [1, 1]}
    })

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{layout: %{"nodes" => %{"start" => [0, 0], "end" => [40, 200]}}}] =
             drawn(ctx.group)
  end

  test "a second editor's save meets the first one's", ctx do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "alt_id" => nil,
        "collection" => "molbe",
        "name" => "Prvi",
        "graph" => PotokIde.Processes.GraphEdit.new()
      })

    path = ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}"
    {:ok, first, _html} = live_as(ctx.owner_account, path)
    {:ok, second, _html} = live_as(ctx.owner_account, path)

    first
    |> form("#process-editor-meta", %{"meta" => %{"name" => "Prvi menja"}})
    |> render_change()

    first |> element("#process-editor-save") |> render_click()

    second
    |> form("#process-editor-meta", %{"meta" => %{"name" => "Drugi menja"}})
    |> render_change()

    second |> element("#process-editor-save") |> render_click()

    assert has_element?(second, "#process-editor-conflict")
    assert %AppProcess{name: "Prvi menja"} = Repo.get!(AppProcess, row.id)

    second |> element("#process-editor-keep-mine") |> render_click()
    assert %AppProcess{name: "Drugi menja"} = Repo.get!(AppProcess, row.id)
  end

  describe "today's language" do
    # A fault by hand, written before texts held expressions.
    defp first_language do
      %{
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "poruka-1",
            "type" => "serviceTask",
            "action" => "message",
            "text" => "Kvar: {{title}}"
          },
          %{"id" => "uslov", "type" => "exclusiveGateway"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "poruka-1"},
          %{"from" => "poruka-1", "to" => "uslov"},
          %{
            "from" => "uslov",
            "to" => "kraj",
            "condition" => %{"field" => "title", "op" => "=", "value" => "lift"}
          },
          %{"from" => "uslov", "to" => "kraj", "default" => true}
        ]
      }
    end

    test "a drawing in the first language is turned into it as its editor opens it", ctx do
      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Prijava",
          "graph" => first_language(),
          "layout" => %{"nodes" => %{"poruka-1" => [40, 200]}}
        })

      {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
      path = ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}"

      # Whoever only looks sees it as it is kept.
      {:ok, member_lv, _html} = live_as(ctx.member_account, path)
      refute has_element?(member_lv, "#process-editor-upgraded")
      assert has_element?(member_lv, "#process-outline-poruka-1", "Kvar: {{title}}")

      {:ok, lv, _html} = live_as(ctx.owner_account, path)
      assert has_element?(lv, "#process-editor-upgraded")
      assert has_element?(lv, "#process-outline-poruka_1", "Kvar: {{start.title}}")
      refute has_element?(lv, "#process-editor-error")
      refute has_element?(lv, "#process-editor-save[disabled]")

      render_hook(canvas(lv), "process_editor_select", %{"flow" => "f3"})
      assert has_element?(lv, "#process-flow-form textarea", ~s|start.title = "lift"|)

      lv |> element("#process-editor-save") |> render_click()
      refute has_element?(lv, "#process-editor-upgraded")

      saved = Repo.get!(AppProcess, row.id)
      assert %{"v" => 2} = saved.graph
      assert Enum.map(saved.graph["nodes"], & &1["id"]) == ~w(start poruka_1 uslov kraj)
      assert saved.layout == %{"nodes" => %{"poruka_1" => [40, 200]}}

      assert %{"condition" => %{"expr" => ~s|start.title = "lift"|}} =
               Enum.at(saved.graph["flows"], 2)
    end

    test "a condition asks an expression, which a mistake stops and a name helps to write",
         ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
      insert(lv, "f1", "gateway")
      refute has_element?(lv, "#process-editor-error")

      render_hook(canvas(lv), "process_editor_select", %{"flow" => "f2"})
      assert has_element?(lv, "#process-flow-form textarea", "true")

      lv
      |> form("#process-flow-form", %{"flow" => %{"expr" => "naslov > 1"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "The process has nothing named naslov.")
      assert has_element?(lv, "#process-editor-save[disabled]")

      lv
      |> form("#process-flow-form", %{"flow" => %{"expr" => "start.title + 1 > 2"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      lv
      |> form("#process-flow-form", %{"flow" => %{"expr" => "start.title ="}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "This cannot be read")

      # The names the process has are offered, as an expression writes them.
      lv |> form("#process-flow-form", %{"flow" => %{"expr" => "true"}}) |> render_change()
      assert has_element?(lv, "#process-field-expr-0", "start.title")
      lv |> element("#process-field-expr-0") |> render_click()
      assert has_element?(lv, "#process-flow-form textarea", "start.title")

      lv
      |> form("#process-flow-form", %{"flow" => %{"expr" => ~s|start.title = "lift"|}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{graph: %{"v" => 2, "zone" => "Etc/UTC"} = graph}] = drawn(ctx.group)

      assert Enum.any?(
               graph["flows"],
               &(&1["condition"] == %{"expr" => ~s|start.title = "lift"|})
             )
    end

    test "a text names what the process has, and is told when it does not", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
      insert(lv, "f1", "message")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "Kvar: {{title}}"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "The process has nothing named title.")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "Kvar:"}})
      |> render_change()

      # A name goes into a text between its braces.
      assert has_element?(lv, "#process-field-text-0", "start.title")
      lv |> element("#process-field-text-0") |> render_click()
      assert has_element?(lv, "#process-outline-message_1", "Kvar: {{start.title}}")
      refute has_element?(lv, "#process-editor-error")
    end
  end

  describe "the data of the process" do
    alias PotokIde.Processes.GroupEntities
    alias PotokIde.Social.Access

    defp manual(lv),
      do:
        lv
        |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}})
        |> render_change()

    defp variables(lv, rows),
      do: lv |> form("#process-variables-form", %{"variables" => rows}) |> render_change()

    test "shows what the drawing may name, with what each holds", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      manual(lv)
      insert(lv, "f1", "task")
      render_hook(canvas(lv), "process_editor_select", %{})

      assert has_element?(lv, "#process-data-panel")
      assert has_element?(lv, "#process-data-entry", "start.title")
      assert has_element?(lv, "#process-data-entry", "text")
      assert has_element?(lv, "#process-data-results", "task_1.outcome")
      refute has_element?(lv, "#process-variables-form")
      assert has_element?(lv, "#process-data-entities")
    end

    test "an editor lists the variables, and the drawing keeps them", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      manual(lv)
      lv |> element("#process-variable-add") |> render_click()
      assert has_element?(lv, "#process-variable-0-name[value='variable1']")

      lv |> element("#process-variable-add") |> render_click()

      variables(lv, %{
        "0" => %{"name" => "ukupno", "type" => "number", "list" => "false", "initial" => "0"},
        "1" => %{"name" => "vrsta", "type" => "choice", "list" => "false"}
      })

      # A choice says what it may be.
      assert has_element?(lv, "#process-editor-error", "A choice lists what it may be")
      assert has_element?(lv, "#process-variable-1-options")

      variables(lv, %{
        "0" => %{"name" => "ukupno", "type" => "number", "list" => "false", "initial" => "0"},
        "1" => %{
          "name" => "vrsta",
          "type" => "choice",
          "list" => "false",
          "options" => "voda, struja",
          "initial" => "voda"
        }
      })

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{graph: %{"variables" => saved}}] = drawn(ctx.group)

      assert saved == [
               %{"name" => "ukupno", "type" => "number", "list" => false, "initial" => "0"},
               %{
                 "name" => "vrsta",
                 "type" => "choice",
                 "list" => false,
                 "options" => ["voda", "struja"],
                 "initial" => "voda"
               }
             ]

      lv |> element("#process-variable-0-remove") |> render_click()
      refute has_element?(lv, "#process-variable-1")
      assert has_element?(lv, "#process-variable-0-name[value='vrsta']")
    end

    test "a variable that is not right is told", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      manual(lv)
      lv |> element("#process-variable-add") |> render_click()

      variables(lv, %{"0" => %{"name" => "broj stana", "type" => "number", "list" => "false"}})
      assert has_element?(lv, "#process-editor-error", "A variable is named in one word")

      variables(lv, %{"0" => %{"name" => "start", "type" => "number", "list" => "false"}})
      assert has_element?(lv, "#process-editor-error", "has that name already")

      variables(lv, %{
        "0" => %{
          "name" => "ukupno",
          "type" => "number",
          "list" => "false",
          "initial" => "start.title"
        }
      })

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")
      assert has_element?(lv, "#process-editor-save[disabled]")
    end

    test "a step sets a variable to what an expression gives", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      manual(lv)

      # Without a variable there is nothing to set.
      insert(lv, "f1", "assign")
      assert has_element?(lv, "#process-assign-none")
      assert has_element?(lv, "#process-editor-error", "Pick what the step sets")

      render_hook(canvas(lv), "process_editor_select", %{})
      lv |> element("#process-variable-add") |> render_click()
      lv |> element("#process-variable-add") |> render_click()

      variables(lv, %{
        "0" => %{"name" => "ukupno", "type" => "number", "list" => "false", "initial" => "1"},
        "1" => %{"name" => "opis", "type" => "text", "list" => "false"}
      })

      render_hook(canvas(lv), "process_editor_select", %{"node" => "assign_1"})
      refute has_element?(lv, "#process-assign-none")

      lv
      |> form("#process-element-form", %{
        "element" => %{"target" => "ukupno", "value" => "start.title"}
      })
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      # A name goes into an expression as it is, and into a text in braces.
      lv
      |> form("#process-element-form", %{"element" => %{"target" => "ukupno", "value" => ""}})
      |> render_change()

      lv |> element("[id^='process-field-value_expr-']", "ukupno") |> render_click()
      assert has_element?(lv, "#process-outline-assign_1", "Set ukupno · ukupno")

      lv
      |> form("#process-element-form", %{
        "element" => %{"target" => "ukupno", "value" => "ukupno + 1"}
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      lv
      |> form("#process-element-form", %{"element" => %{"target" => "opis", "value" => "Kvar:"}})
      |> render_change()

      lv |> element("[id^='process-field-value-']", "start.title") |> render_click()
      assert has_element?(lv, "#process-outline-assign_1", "Set opis · Kvar: {{start.title}}")
      refute has_element?(lv, "#process-editor-error")

      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{graph: graph}] = drawn(ctx.group)

      assert %{"action" => "assign", "target" => "opis", "value" => "Kvar: {{start.title}}"} =
               PotokIde.Processes.Graph.node(graph, "assign_1")
    end

    test "a variable holds an entity of the group, defined without leaving the drawing", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      manual(lv)
      assert has_element?(lv, "#process-data-entities", "None yet")

      lv |> element("#process-data-entity-new") |> render_click()
      assert has_element?(lv, "#entity-dialog")

      lv
      |> form("#entity-form")
      |> render_submit(%{
        "entity" => %{
          "name" => "Prijava",
          "attributes" => %{
            "0" => %{"name" => "naslov", "type" => "text"},
            "1" => %{"name" => "sprat", "type" => "number"}
          },
          "attributes_sort" => ["0", "1"]
        }
      })

      refute has_element?(lv, "#entity-dialog")
      [entity] = GroupEntities.list(ctx.group)
      assert has_element?(lv, "#process-data-entity-#{entity.id}", "Prijava")

      lv |> element("#process-variable-add") |> render_click()

      # Picking the type brings the choice of the entity.
      variables(lv, %{"0" => %{"name" => "prijava", "type" => "entity", "list" => "false"}})
      assert has_element?(lv, "#process-editor-error", "Pick the entity the variable holds.")

      variables(lv, %{
        "0" => %{
          "name" => "prijava",
          "type" => "entity",
          "list" => "false",
          "entity" => "#{entity.id}"
        }
      })

      refute has_element?(lv, "#process-editor-error")

      # Its attributes can be set, each as its type takes it.
      insert(lv, "f1", "assign")

      assert has_element?(
               lv,
               "#process-element-form select[name='element[target]'] option[value='prijava.sprat']"
             )

      lv
      |> form("#process-element-form", %{
        "element" => %{"target" => "prijava.sprat", "value" => "3"}
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{graph: graph}] = drawn(ctx.group)
      assert Map.keys(graph["types"]) == [to_string(entity.id)]

      # An entity changed under an open drawing is checked again at once.
      access = Access.for_profile(ctx.owner, ctx.group)

      {:ok, _changed} =
        GroupEntities.update(ctx.group, access, entity, %{
          "attributes" => [%{"name" => "naslov", "type" => "text"}]
        })

      assert has_element?(lv, "#process-editor-error", "There is no sprat in that.")
    end

    test "is for the app's editors: a member sees the drawing only", ctx do
      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "manual",
          "name" => "Prijava",
          "graph" => PotokIde.Processes.GraphEdit.new()
        })

      {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")

      refute has_element?(lv, "#process-data-panel")
      refute has_element?(lv, "#process-editor-data")
      assert has_element?(lv, "#process-panel-hint")
    end
  end

  describe "what a process takes" do
    alias PotokIde.Processes.GroupEntities
    alias PotokIde.Social.Access

    defp entity!(ctx, name, attributes) do
      {:ok, entity} =
        GroupEntities.create(ctx.group, Access.for_profile(ctx.owner, ctx.group), %{
          "name" => name,
          "attributes" => attributes
        })

      entity
    end

    defp kvar!(ctx) do
      entity!(ctx, "Kvar", [
        %{"name" => "naslov", "type" => "text", "required" => true},
        %{"name" => "sprat", "type" => "number"}
      ])
    end

    defp trigger(lv, name),
      do: lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => name}}) |> render_change()

    defp start_form(lv, params),
      do: lv |> form("#process-trigger-form", %{"trigger" => params}) |> render_change()

    test "a process that takes calls takes an entity instead of plain fields", ctx do
      kvar = kvar!(ctx)

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "process")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      assert has_element?(lv, "#process-trigger-fields")
      assert has_element?(lv, "#process-trigger-entity option", "Kvar")

      start_form(lv, %{"entity" => "#{kvar.id}"})
      refute has_element?(lv, "#process-trigger-fields")

      # What it takes is what its start holds, each attribute of its type.
      render_hook(canvas(lv), "process_editor_select", %{})
      assert has_element?(lv, "#process-data-entry", "start.naslov")
      assert has_element?(lv, "#process-data-entry li", "start.sprat")
      assert has_element?(lv, "#process-data-entry", "number")
      assert has_element?(lv, "#process-data-entry", "start.from")

      insert(lv, "f1", "message")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{start.sprat + 1}}"}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{start.naslov + 1}}"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{start.naslov}}"}})
      |> render_change()

      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{entry_entity_id: id, trigger_config: %{"fields" => []}}] =
               drawn(ctx.group)

      assert id == kvar.id
    end

    test "a process that takes calls hands an entity back, which each end fills in", ctx do
      ponuda =
        entity!(ctx, "Ponuda", [
          %{"name" => "iznos", "type" => "number", "required" => true},
          %{"name" => "napomena", "type" => "text"}
        ])

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "process")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      assert has_element?(lv, "#process-trigger-returns option", "Ponuda")
      start_form(lv, %{"returns" => "#{ponuda.id}"})

      render_hook(canvas(lv), "process_editor_select", %{"node" => "end"})
      assert has_element?(lv, "#process-end-values", "iznos · number *")
      assert has_element?(lv, "#process-editor-error", "must be filled in is left empty")

      lv
      |> form("#process-element-form", %{
        "element" => %{"end_values" => %{"iznos" => "42", "napomena" => "Za "}}
      })
      |> render_change()

      lv |> element("#process-field-end_values\\.napomena-0") |> render_click()
      refute has_element?(lv, "#process-editor-error")

      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{return_entity_id: id, graph: graph}] = drawn(ctx.group)
      assert id == ponuda.id
      assert graph["returns"] == ponuda.id

      assert %{"values" => %{"iznos" => "42", "napomena" => "Za {{" <> _rest}} =
               PotokIde.Processes.Graph.node(graph, "end")
    end

    test "a call says what its process hands back, which the steps after read", ctx do
      ponuda =
        entity!(ctx, "Ponuda", [
          %{"name" => "iznos", "type" => "number", "required" => true},
          %{"name" => "napomena", "type" => "text"}
        ])

      graph = PotokIde.Processes.GraphEdit.new()

      graph = %{
        graph
        | "nodes" =>
            Enum.map(graph["nodes"], fn
              %{"type" => "endEvent"} = node -> Map.put(node, "values", %{"iznos" => "7"})
              node -> node
            end)
      }

      {:ok, callee} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "process",
          "name" => "Procena",
          "graph" => graph,
          "return_entity_id" => ponuda.id
        })

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "manual")
      insert(lv, "f1", "call")

      lv
      |> form("#process-element-form", %{"element" => %{"process" => "#{callee.id}"}})
      |> render_change()

      assert has_element?(lv, "#process-call-returns", "Ponuda: iznos, napomena")
      assert has_element?(lv, "#process-node-panel", "{{call_1.iznos}}")

      insert(lv, "f1", "message")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{call_1.iznos + 1}}"}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{call_1.nema}}"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "There is no nema in that.")
    end

    test "a drawing whose entity changed opens ready to be saved again", ctx do
      kvar = kvar!(ctx)

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "process")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      start_form(lv, %{"entity" => "#{kvar.id}"})
      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{id: id}] = drawn(ctx.group)

      # Saved a moment ago, it is in step: nothing to save.
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=#{id}")

      refute has_element?(lv, "#process-editor-stale")
      assert has_element?(lv, "#process-editor-save[disabled]")

      {:ok, _entity} =
        GroupEntities.update(ctx.group, Access.for_profile(ctx.owner, ctx.group), kvar, %{
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"},
            %{"name" => "hitno", "type" => "boolean"}
          ]
        })

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=#{id}")

      assert has_element?(lv, "#process-editor-stale")
      refute has_element?(lv, "#process-editor-save[disabled]")

      lv |> element("#process-editor-save") |> render_click()
      refute has_element?(lv, "#process-editor-stale")
      assert has_element?(lv, "#process-editor-save[disabled]")

      assert [%AppProcess{graph: %{"types" => types}} = row] = drawn(ctx.group)
      assert length(types["#{kvar.id}"]["attributes"]) == 3
      refute DrawnProcesses.stale?(row, ctx.group)
    end

    test "the fields a process takes become an entity of the group", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "process")
      lv |> form("#process-editor-meta", %{"meta" => %{"name" => "Majstor"}}) |> render_change()
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      refute has_element?(lv, "#process-trigger-entity-from-fields")

      start_form(lv, %{"fields" => "kvar, sprat"})
      lv |> element("#process-trigger-entity-from-fields") |> render_click()

      assert [
               %{name: "Majstor", attributes: [%{name: "kvar", type: "text"}, %{name: "sprat"}]} =
                 entity
             ] =
               GroupEntities.list(ctx.group)

      refute has_element?(lv, "#process-trigger-fields")
      assert has_element?(lv, "#process-trigger-entity option[selected]", "Majstor")

      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{entry_entity_id: id}] = drawn(ctx.group)
      assert id == entity.id
    end

    test "a form fills in plain attributes only", ctx do
      stan = entity!(ctx, "Stan", [%{"name" => "broj", "type" => "number"}])
      entity!(ctx, "Zgrada", [%{"name" => "stan", "type" => "entity", "entity_id" => stan.id}])

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "manual")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      assert has_element?(lv, "#process-trigger-entity option", "Stan")
      refute has_element?(lv, "#process-trigger-entity option", "Zgrada")

      # A trigger that hands over texts takes no entity.
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "message")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      refute has_element?(lv, "#process-trigger-entity")
    end

    test "a call hands over the attributes of the entity, each as its type", ctx do
      kvar = kvar!(ctx)

      {:ok, callee} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "process",
          "name" => "Majstor",
          "graph" => PotokIde.Processes.GraphEdit.new(),
          "entry_entity_id" => kvar.id
        })

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "manual")
      insert(lv, "f1", "call")

      assert has_element?(lv, "#process-call-fields", "naslov · text *")
      assert has_element?(lv, "#process-call-fields", "sprat · number")
      assert has_element?(lv, "#process-editor-error", "must be filled in is left empty")

      lv
      |> form("#process-element-form", %{
        "element" => %{
          "process" => "#{callee.id}",
          "fields" => %{"naslov" => "Kvar:", "sprat" => "start.title"}
        }
      })
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      # A name goes into a text in braces, and into an expression as it is.
      lv |> element("[id^='process-field-fields.naslov-']", "start.title") |> render_click()
      assert has_element?(lv, "#process-call-field-naslov[value='Kvar: {{start.title}}']")

      lv
      |> form("#process-element-form", %{
        "element" => %{"fields" => %{"naslov" => "Kvar: {{start.title}}", "sprat" => ""}}
      })
      |> render_change()

      lv |> element("[id^='process-field-fields.sprat-']", "start.title") |> render_click()
      assert has_element?(lv, "#process-call-field-sprat[value='start.title']")

      lv
      |> form("#process-element-form", %{
        "element" => %{
          "fields" => %{"naslov" => "Kvar: {{start.title}}", "sprat" => "length(start.title)"}
        }
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()

      assert [_callee, %AppProcess{graph: graph}] = Enum.sort_by(drawn(ctx.group), & &1.id)

      assert %{
               "fields" => %{
                 "naslov" => "Kvar: {{start.title}}",
                 "sprat" => "length(start.title)"
               }
             } =
               PotokIde.Processes.Graph.node(graph, "call_1")
    end

    test "a signal is sent and waited for with an entity", ctx do
      uplata =
        entity!(ctx, "Uplata", [%{"name" => "iznos", "type" => "number", "required" => true}])

      # Someone waits for it with the entity.
      {:ok, _waits} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "signal",
          "trigger_config" => %{"name" => "uplata"},
          "name" => "Knjizenje",
          "graph" => PotokIde.Processes.GraphEdit.new(),
          "entry_entity_id" => uplata.id
        })

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "manual")
      insert(lv, "f1", "signal")

      # Naming the signal brings the entity those who wait for it expect.
      lv
      |> form("#process-element-form", %{"element" => %{"name" => "uplata"}})
      |> render_change()

      assert has_element?(
               lv,
               "#process-element-form select[name='element[entity]'] option[selected]",
               "Uplata"
             )

      assert has_element?(lv, "#process-signal-field-0", "iznos · number *")
      refute has_element?(lv, "#process-add-signal-field")
      assert has_element?(lv, "#process-editor-error", "must be filled in is left empty")

      lv
      |> form("#process-element-form", %{
        "element" => %{
          "signal_fields" => %{"0" => %{"name" => "iznos", "value" => "length(start.title)"}}
        }
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      # With another entity, or none, nobody would hear it as they expect.
      lv |> form("#process-element-form", %{"element" => %{"entity" => ""}}) |> render_change()
      assert has_element?(lv, "#process-editor-error", "expect it with another entity")
      assert has_element?(lv, "#process-add-signal-field")

      lv
      |> form("#process-element-form", %{"element" => %{"entity" => "#{uplata.id}"}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      # A wait brings the attributes of the entity it names.
      insert(lv, "f1", "receive")

      lv
      |> form("#process-element-form", %{"element" => %{"signal" => "uplata"}})
      |> render_change()

      assert has_element?(
               lv,
               "#process-element-form select[name='element[entity]'] option[selected]",
               "Uplata"
             )

      render_hook(canvas(lv), "process_editor_select", %{})
      assert has_element?(lv, "#process-data-results", "receive_1.iznos")

      lv |> element("#process-editor-save") |> render_click()
      [saved] = Enum.filter(drawn(ctx.group), &(&1.trigger == "manual"))

      assert %{"entity" => id, "fields" => [%{"name" => "iznos"}]} =
               PotokIde.Processes.Graph.node(saved.graph, "signal_1")

      assert id == uplata.id
      assert %{"entity" => ^id} = PotokIde.Processes.Graph.node(saved.graph, "receive_1")
    end

    test "a form asks for an entity, whoever started the run or the people of a role", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "message")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      start_form(lv, %{"words" => "kvar"})

      # With no entity to ask for, the step says what it lacks.
      insert(lv, "f1", "form")
      assert has_element?(lv, "#process-outline-form_1", "whoever started it")
      assert has_element?(lv, "#process-form-no-entity")
      assert has_element?(lv, "#process-editor-error", "Pick the entity the form asks for.")
      lv |> element("#process-node-delete") |> render_click()

      kvar = kvar!(ctx)
      # A form cannot fill in a list, so this one is not offered.
      entity!(ctx, "Obilazak", [%{"name" => "kvarovi", "type" => "text", "list" => true}])

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "message")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      start_form(lv, %{"words" => "kvar"})

      # A new form asks for the first entity it can.
      insert(lv, "f1", "form")
      refute has_element?(lv, "#process-editor-error")

      assert has_element?(
               lv,
               "#process-element-form select[name='element[entity]'] option[selected]",
               "Kvar"
             )

      refute has_element?(
               lv,
               "#process-element-form select[name='element[entity]'] option",
               "Obilazak"
             )

      assert has_element?(lv, "#process-form-reads", "{{form_1.naslov}}")
      assert has_element?(lv, "#process-form-where", "opens by itself")

      # What it brings back is there for the steps after it, each of its type.
      render_hook(canvas(lv), "process_editor_select", %{})
      assert has_element?(lv, "#process-data-results", "form_1.naslov")
      assert has_element?(lv, "#process-data-results li", "form_1.sprat")
      assert has_element?(lv, "#process-data-results", "form_1.author")

      # The form's way on is the second flow of the drawing.
      insert(lv, "f2", "message")

      lv
      |> form("#process-element-form", %{
        "element" => %{"text" => "{{form_1.naslov}}, sprat {{form_1.sprat + 1}}"}
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{form_1.naslov + 1}}"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{form_1.naslov}}"}})
      |> render_change()

      # The people of a role fill it in, with a deadline that goes on.
      render_hook(canvas(lv), "process_editor_select", %{"node" => "form_1"})

      lv
      |> form("#process-element-form", %{
        "element" => %{"who" => "role:admin", "deadline_amount" => "2", "deadline_unit" => "days"}
      })
      |> render_change()

      assert has_element?(lv, "#process-outline-form_1", "2 days")
      refute has_element?(lv, "#process-outline-push_1")
      assert has_element?(lv, "#process-form-where", "people of the role")

      lv |> element("#process-editor-save") |> render_click()
      [saved] = drawn(ctx.group)

      assert PotokIde.Processes.Graph.node(saved.graph, "form_1") == %{
               "id" => "form_1",
               "type" => "formTask",
               "by" => "role",
               "role" => "admin",
               "entity" => kvar.id,
               "deadline" => "P2D"
             }

      assert Map.keys(saved.graph["types"]) == [to_string(kvar.id)]

      # And whoever started it again.
      render_hook(canvas(lv), "process_editor_select", %{"node" => "form_1"})

      lv
      |> form("#process-element-form", %{"element" => %{"who" => "starter"}})
      |> render_change()

      lv |> element("#process-editor-save") |> render_click()
      [saved] = drawn(ctx.group)
      form = PotokIde.Processes.Graph.node(saved.graph, "form_1")
      assert form["by"] == "starter"
      refute Map.has_key?(form, "role")
    end

    test "a form says something first and starts with what the run holds", ctx do
      kvar = kvar!(ctx)

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      trigger(lv, "message")
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      start_form(lv, %{"words" => "kvar"})
      insert(lv, "f1", "form")

      # One row for each attribute of the entity it asks for.
      assert has_element?(lv, "#process-form-value-naslov", "naslov · ")
      assert has_element?(lv, "#process-form-value-sprat", "sprat · ")

      # A name tapped in goes in braces where the attribute is a text, bare
      # where it is an expression.
      lv |> element("#process-field-intro-0", "start.text") |> render_click()

      lv
      |> element("[id='process-field-form_values.naslov-0']", "start.text")
      |> render_click()

      lv
      |> form("#process-element-form", %{
        "element" => %{"form_values" => %{"sprat" => "start.text"}}
      })
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      lv
      |> form("#process-element-form", %{
        "element" => %{
          "intro" => "Javi nam još: {{start.text}}",
          "form_values" => %{"sprat" => "length(start.text)"}
        }
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      lv |> element("#process-editor-save") |> render_click()
      [saved] = drawn(ctx.group)

      assert %{
               "entity" => entity,
               "intro" => "Javi nam još: {{start.text}}",
               "values" => %{"naslov" => "{{start.text}}", "sprat" => "length(start.text)"}
             } = PotokIde.Processes.Graph.node(saved.graph, "form_1")

      assert entity == kvar.id
    end

    test "a member reads what a form asks for, as the drawing was saved", ctx do
      kvar = kvar!(ctx)

      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "prijava", "type" => "formTask", "entity" => kvar.id},
          %{"id" => "end", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "prijava"},
          %{"from" => "prijava", "to" => "end"}
        ]
      }

      {:ok, row} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "message",
          "trigger_config" => %{"words" => "kvar"},
          "name" => "Prijava kvara",
          "graph" => graph
        })

      {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")

      render_hook(canvas(lv), "process_editor_select", %{"node" => "prijava"})
      assert has_element?(lv, "#process-form-asks", "Kvar")
      assert has_element?(lv, "#process-form-reads", "{{prijava.naslov}}")
      refute has_element?(lv, "#process-form-no-entity")
    end
  end

  test "members look at a drawing that is on, and change nothing", ctx do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "alt_id" => nil,
        "collection" => "molbe",
        "name" => "Savet",
        "graph" => PotokIde.Processes.GraphEdit.new()
      })

    {:ok, _row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)

    {:ok, lv, _html} =
      live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")

    assert has_element?(lv, ~s(#process-canvas[data-editable="false"]))
    refute has_element?(lv, "#process-editor-save")
    refute has_element?(lv, "#processes-new")
  end

  describe "a loop" do
    alias PotokIde.Processes.Graph

    defp with_list(lv) do
      lv
      |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}})
      |> render_change()

      lv |> element("#process-variable-add") |> render_click()
      lv |> element("#process-variable-add") |> render_click()

      lv
      |> form("#process-variables-form", %{
        "variables" => %{
          "0" => %{"name" => "brojevi", "type" => "number", "list" => "true"},
          "1" => %{"name" => "ukupno", "type" => "number", "list" => "false", "initial" => "0"}
        }
      })
      |> render_change()
    end

    test "an editor draws a loop over a list the drawing keeps", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      with_list(lv)
      insert(lv, "f1", "loop")

      # It starts on the first list there is, with a body of one step.
      assert has_element?(
               lv,
               "#process-element-form input[name='element[list]'][value='brojevi']"
             )

      assert has_element?(lv, "#process-element-form input[name='element[item]'][value='item']")
      assert has_element?(lv, "#process-node-panel", "{{loop_1.index}}")
      refute has_element?(lv, "#process-editor-error")

      lv
      |> form("#process-element-form", %{"element" => %{"item" => "broj"}})
      |> render_change()

      # The body reads the item by its type.
      render_hook(canvas(lv), "process_editor_select", %{"node" => "message_1"})

      lv
      |> form("#process-element-form", %{"element" => %{"text" => "{{upper(broj)}}"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a text, and this is a number.")

      lv
      |> form("#process-element-form", %{
        "element" => %{"text" => "{{broj * 2}} ({{loop_1.index}}/{{loop_1.count}})"}
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")

      # The data of the process names the item and where the loop stands.
      render_hook(canvas(lv), "process_editor_select", %{})
      assert has_element?(lv, "#process-data-results li", "broj")
      assert has_element?(lv, "#process-data-results", "loop_1.index")
      assert has_element?(lv, "#process-data-results", "loop_1.count")

      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{graph: graph}] = drawn(ctx.group)

      assert %{"list" => "brojevi", "item" => "broj", "of" => %{"type" => "number"}} =
               Graph.node(graph, "loop_1")

      assert %{"from" => "loop_1", "to" => "message_1", "each" => true} in graph["flows"]
      assert %{"from" => "message_1", "to" => "loop_1"} in graph["flows"]
      assert %{"from" => "loop_1", "to" => "end"} in graph["flows"]
    end

    test "a loop says what it lacks, and offers the lists of the drawing", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      lv
      |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}})
      |> render_change()

      insert(lv, "f1", "loop")
      assert has_element?(lv, "#process-editor-error", "Say which list the loop goes through.")
      refute has_element?(lv, "#process-field-list_expr-0")

      lv
      |> form("#process-element-form", %{"element" => %{"list" => "start.title"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a list, and this is a text.")

      lv
      |> form("#process-element-form", %{"element" => %{"list" => "nema", "item" => "moj broj"}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "An item is named in one word")

      render_hook(canvas(lv), "process_editor_select", %{})
      with_list(lv)
      render_hook(canvas(lv), "process_editor_select", %{"node" => "loop_1"})

      # Only the lists are offered for a list.
      assert has_element?(lv, "#process-field-list_expr-0", "brojevi")
      refute has_element?(lv, "#process-field-list_expr-1")

      lv |> element("#process-field-list_expr-0") |> render_click()

      assert has_element?(
               lv,
               "#process-element-form input[name='element[list]'][value='brojevi']"
             )

      lv
      |> form("#process-element-form", %{"element" => %{"item" => "broj"}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
    end

    test "the last step of a loop's body stays, and a loop goes with its body", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      with_list(lv)
      insert(lv, "f1", "loop")

      render_hook(canvas(lv), "process_editor_select", %{"node" => "message_1"})
      html = lv |> element("#process-node-delete") |> render_click()
      assert html =~ "A loop keeps at least one step of its own."
      assert has_element?(lv, "#process-outline-message_1")

      render_hook(canvas(lv), "process_editor_select", %{"node" => "loop_1"})
      lv |> element("#process-node-delete") |> render_click()
      refute has_element?(lv, "#process-outline-loop_1")
      refute has_element?(lv, "#process-outline-message_1")
    end

    test "a step adds to a list, while what it sets is one", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      with_list(lv)
      insert(lv, "f1", "assign")

      # The first variable is the list: it may be set whole or added to.
      assert has_element?(lv, "#process-element-form select[name='element[op]']")

      lv
      |> form("#process-element-form", %{"element" => %{"op" => "append", "value" => ~s("tri")}})
      |> render_change()

      assert has_element?(lv, "#process-editor-error", "Here goes a number, and this is a text.")

      lv
      |> form("#process-element-form", %{"element" => %{"value" => "ukupno + 1"}})
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{graph: graph}] = drawn(ctx.group)
      assert %{"target" => "brojevi", "op" => "append"} = Graph.node(graph, "assign_1")

      # With a plain variable picked, it sets again.
      render_hook(canvas(lv), "process_editor_select", %{"node" => "assign_1"})

      lv
      |> form("#process-element-form", %{"element" => %{"target" => "ukupno"}})
      |> render_change()

      refute has_element?(lv, "#process-element-form select[name='element[op]']")
      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{graph: graph}] = drawn(ctx.group)
      assert %{"target" => "ukupno", "op" => "set"} = Graph.node(graph, "assign_1")
    end
  end

  describe "a public process" do
    alias PotokIde.Processes.GroupEntities
    alias PotokIde.Social.Access

    # A group under the one of the setup, with the same editor.
    defp below!(ctx) do
      {:ok, group} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "ispod",
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat
        })

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, group)
      Social.get_group!(group.id)
    end

    test "an editor makes a process others call public, with the drawing", ctx do
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=new")

      # Only a process that others call can be.
      lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()
      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      refute has_element?(lv, "#process-trigger-public")

      lv
      |> form("#process-editor-meta", %{"meta" => %{"trigger" => "process"}})
      |> render_change()

      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      assert has_element?(lv, "#process-trigger-public:not([checked])")

      lv
      |> form("#process-trigger-form", %{"trigger" => %{"fields" => "kvar", "public" => "true"}})
      |> render_change()

      assert has_element?(lv, "#process-trigger-public[checked]")
      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{id: id, is_public: true, trigger: "process"}] = drawn(ctx.group)

      # The Processes tab marks it.
      {:ok, tab, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      assert has_element?(tab, "#process-row-#{id}-public")

      # Private again, saved the same way.
      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=#{id}")

      render_hook(canvas(lv), "process_editor_select", %{"node" => "start"})
      assert has_element?(lv, "#process-trigger-public[checked]")

      lv
      |> form("#process-trigger-form", %{"trigger" => %{"fields" => "kvar", "public" => "false"}})
      |> render_change()

      lv |> element("#process-editor-save") |> render_click()
      assert [%AppProcess{is_public: false}] = drawn(ctx.group)

      {:ok, tab, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes")
      refute has_element?(tab, "#process-row-#{id}-public")
    end

    test "a call in a group below is offered it, with what it takes", ctx do
      {:ok, kvar} =
        GroupEntities.create(ctx.group, Access.for_profile(ctx.owner, ctx.group), %{
          "name" => "Kvar",
          "attributes" => [
            %{"name" => "naslov", "type" => "text", "required" => true},
            %{"name" => "sprat", "type" => "number"}
          ]
        })

      {:ok, callee} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "process",
          "name" => "Majstor",
          "entry_entity_id" => kvar.id,
          "is_public" => true,
          "graph" => PotokIde.Processes.GraphEdit.new()
        })

      {:ok, callee} = DrawnProcesses.activate(ctx.owner, ctx.group, callee.id)

      {:ok, _private} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "trigger" => "process",
          "name" => "Samo ovde",
          "graph" => PotokIde.Processes.GraphEdit.new()
        })

      below = below!(ctx)

      {:ok, lv, _html} =
        live_as(ctx.owner_account, ~p"/groups/#{below.id}/processes?process=new")

      lv |> form("#process-editor-meta", %{"meta" => %{"trigger" => "manual"}}) |> render_change()

      # Its data shows what the public process takes, to read.
      assert has_element?(lv, "#process-data-taken-#{callee.id}", "Majstor")
      assert has_element?(lv, "#process-data-taken-#{callee.id}", "process-editor")
      assert has_element?(lv, "#process-data-taken-#{callee.id}", "naslov")
      assert has_element?(lv, "#process-data-taken-#{callee.id}", "number")

      insert(lv, "f1", "call")

      # The public one, named with its group; not the private one.
      assert has_element?(
               lv,
               "#process-element-form select[name='element[process]'] option[value='#{callee.id}']",
               "Majstor · process-editor"
             )

      refute has_element?(lv, "#process-element-form option", "Samo ovde")
      assert has_element?(lv, "#process-call-foreign", "process-editor")
      assert has_element?(lv, "#process-call-field-naslov")

      assert has_element?(
               lv,
               "#process-editor-error",
               "An attribute that must be filled in is left empty."
             )

      lv
      |> form("#process-element-form", %{
        "element" => %{"fields" => %{"naslov" => "{{start.title}}", "sprat" => "2"}}
      })
      |> render_change()

      refute has_element?(lv, "#process-editor-error")
      lv |> element("#process-editor-save") |> render_click()

      assert [%AppProcess{graph: graph}] = drawn(below)
      assert %{"process" => id} = Enum.find(graph["nodes"], &(&1["type"] == "callActivity"))
      assert id == callee.id
    end
  end

  test "an app's own process shows as the app drew it", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "kraj", "type" => "endEvent", "label" => "Gotovo"}
      ],
      "flows" => [%{"from" => "start", "to" => "kraj"}]
    }

    config = AppData.get_config(ctx.group, nil)

    {:ok, _config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{"rules" => %{"molbe" => %{"process" => %{"name" => "Prijem", "graph" => graph}}}},
        config.lock_version
      )

    row = Repo.get_by!(AppProcess, group_id: ctx.group.id, drawn: false)

    {:ok, lv, _html} =
      live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")

    assert has_element?(lv, "#process-editor-readonly")
    assert has_element?(lv, "#process-outline-kraj", "Gotovo")
    refute has_element?(lv, "#process-editor-save")
  end
end
