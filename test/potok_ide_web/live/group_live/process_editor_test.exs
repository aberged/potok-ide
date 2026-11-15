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
    assert has_element?(lv, "#process-outline-task-1")
    assert has_element?(lv, "#process-node-panel")
    assert has_element?(lv, "#process-add-outcome")

    lv
    |> form("#process-editor-meta", %{"meta" => %{"name" => "Savet odlučuje"}})
    |> render_change()

    lv |> element("#process-editor-save") |> render_click()

    assert [%AppProcess{name: "Savet odlučuje", active: false} = row] = drawn(ctx.group)
    assert_patch(lv, ~p"/groups/#{ctx.group.id}/processes?process=#{row.id}")
    assert Enum.any?(row.graph["nodes"], &(&1["type"] == "userTask"))

    lv |> element("#process-editor-activate") |> render_click()

    assert %AppProcess{active: true} = Repo.get!(AppProcess, row.id)
    assert has_element?(lv, "#process-editor-state", "on")
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

    render_hook(canvas(lv), "process_editor_select", %{"node" => "message-1"})
    lv |> element("#process-node-delete") |> render_click()

    refute has_element?(lv, "#process-outline-message-1")
    assert has_element?(lv, "#process-outline-task-1")
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
