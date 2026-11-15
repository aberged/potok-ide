defmodule PotokIde.Processes.SchedulerTest do
  @moduledoc """
  The scheduler takes a new instance forward as soon as its value is in,
  without waiting for its next pass.
  """

  # It runs as a named process on the shared connection.
  use PotokIde.DataCase, async: false

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Scheduler, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.AppData

  setup do
    previous = Application.get_env(:potok_ide, Scheduler)
    Application.put_env(:potok_ide, Scheduler, enabled: true, interval_ms: :timer.hours(1))
    on_exit(fn -> Application.put_env(:potok_ide, Scheduler, previous) end)
    :ok
  end

  test "a value sets its process going at once" do
    {_owner_account, owner} = account_with_profile!("sc-owner")
    {member_account, member} = account_with_profile!("sc-member")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

    graph = %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "javi", "type" => "serviceTask", "action" => "message", "text" => "Primljeno."},
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [%{"from" => "start", "to" => "javi"}, %{"from" => "javi", "to" => "kraj"}]
    }

    {:ok, _config} =
      AppData.save_config(
        owner,
        group,
        nil,
        %{"rules" => %{"molbe" => %{"process" => %{"name" => "Prijem", "graph" => graph}}}},
        0
      )

    scheduler = start_supervised!(Scheduler)

    {:ok, value, _rule} = AppData.insert(member, member_account, group, nil, "molbe", %{})

    # The nudge is handled before this call is.
    _ = :sys.get_state(scheduler)

    assert %ValueProcess{status: :done} = Repo.get_by!(ValueProcess, value_id: value.id)
    assert ["Primljeno."] = group |> Social.list_group_values() |> Enum.map(& &1.content)
  end
end
