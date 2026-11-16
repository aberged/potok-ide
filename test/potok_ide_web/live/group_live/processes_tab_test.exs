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
