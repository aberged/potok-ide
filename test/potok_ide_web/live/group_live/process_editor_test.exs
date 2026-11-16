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
