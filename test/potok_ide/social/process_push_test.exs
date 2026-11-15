defmodule PotokIde.Social.ProcessPushTest do
  @moduledoc """
  What an app's process pushes, and under which name: to the people of a
  role, only once its step is announced, and as the process, not as its
  generated username.
  """

  # Push requests are captured through the global push configuration.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, AppProcess, Notifications, ProcessActions, ProcessStep}

  defp unique, do: System.unique_integer([:positive])

  setup do
    capture_push_requests!()

    {owner_account, owner} = account_with_profile!("pp#{unique()}")
    {member_account, member} = account_with_profile!("pp#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)

    {:ok, _config} =
      AppData.save_config(
        owner,
        group,
        nil,
        %{"rules" => %{"tasks" => %{"process" => %{"name" => "Prijem"}}}},
        0
      )

    row = AppProcess |> Repo.get_by!(group_id: group.id) |> Repo.preload(:profile)
    step = %ProcessStep{process: row, instance: 7, element: "Notify_1", triggered_by: nil}

    %{
      owner: owner,
      owner_device: push_device!(owner_account),
      member: member,
      member_device: push_device!(member_account),
      group: group,
      row: row,
      step: step
    }
  end

  test "reaches the people of the role once the step is announced", ctx do
    {:ok, reviewers} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "reviewers"})

    {:ok, _role} =
      Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, reviewers.key)

    assert {:ok, 1, announce} =
             ProcessActions.push(ctx.step, ctx.group, reviewers.key, "  Nova molba  ")

    assert pushed_endpoints() == []

    ProcessActions.announce([announce])
    assert pushed_endpoints() == [ctx.member_device]
  end

  test "everyone means the people of the group, not the process", ctx do
    assert {:ok, 2, announce} = ProcessActions.push(ctx.step, ctx.group, "everyone", "Rok ističe")
    ProcessActions.announce([announce])

    assert pushed_endpoints() == Enum.sort([ctx.owner_device, ctx.member_device])
  end

  test "takes the right to mention roles, and a text", ctx do
    assert {:error, :invalid_push} = ProcessActions.push(ctx.step, ctx.group, "everyone", "  ")

    assert {:error, :invalid_push} =
             ProcessActions.push(ctx.step, ctx.group, "everyone", String.duplicate("a", 241))

    {:ok, _role} =
      Social.set_group_role_permission(
        ctx.owner,
        ctx.group,
        "everyone",
        :mention_roles,
        :neutral
      )

    assert {:error, :not_permitted} =
             ProcessActions.push(ctx.step, ctx.group, "everyone", "Rok ističe")
  end

  test "goes out under the process's name, as do the pushes of its values", ctx do
    process = %{ctx.row.profile | app_process: ctx.row}

    push = Notifications.process_push(process, ctx.group, "Rok ističe", "tag").(nil)
    assert push.title =~ "Prijem"
    assert push.body == "Rok ističe"
    assert push.url == "/groups/#{ctx.group.id}"

    # A process drawn in Potok leads to the group's processes, where its tasks are.
    drawn = Notifications.process_push(process, ctx.group, "Rok", "tag", "/groups/1/processes")
    assert drawn.(nil).url == "/groups/1/processes"

    {:ok, value, _announce} =
      ProcessActions.post_value(ctx.step, ctx.group, %{"content" => "Primljeno."})

    assert Notifications.value_created(process, ctx.group, value).(nil).title =~ "Prijem"
    refute Notifications.value_created(process, ctx.group, value).(nil).title =~ "proces."
  end
end
