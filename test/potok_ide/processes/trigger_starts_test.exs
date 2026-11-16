defmodule PotokIde.Processes.TriggerStartsTest do
  @moduledoc """
  What sets a drawn process going besides a value: a member's message with
  its words, a sub-group made one at a time, and a schedule's time; and what
  does not: a process's own messages and sub-groups, replies, records,
  threads, and a schedule long past.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppProcess, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("ts#{unique()}")
    {_member_account, member} = account_with_profile!("ts#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "description" => "",
        "description_format" => :markdown,
        "home_page" => :chat
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    %{owner: owner, member: member, group: Social.get_group!(group.id)}
  end

  # A run waits for the admins, so it stays to be looked at.
  defp waiting_graph do
    %{
      "nodes" => [
        %{"id" => "start", "type" => "startEvent"},
        %{"id" => "odluka", "type" => "userTask", "role" => "admin", "outcomes" => ["Primljeno"]},
        %{"id" => "kraj", "type" => "endEvent"}
      ],
      "flows" => [
        %{"from" => "start", "to" => "odluka"},
        %{"from" => "odluka", "to" => "kraj", "outcome" => "Primljeno"}
      ]
    }
  end

  defp drawn!(ctx, trigger, config) do
    {:ok, row} =
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => trigger,
        "trigger_config" => config,
        "name" => "Na #{trigger}",
        "graph" => waiting_graph()
      })

    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp runs(row), do: Repo.all(from(i in ValueProcess, where: i.app_process_id == ^row.id))

  defp post!(profile, group, content, extra \\ %{}) do
    {:ok, value} =
      Social.create_value(
        profile,
        group,
        Map.merge(%{"content" => content, "content_format" => :markdown}, extra)
      )

    value
  end

  describe "a message" do
    test "with one of the words starts a run on it, with its text", ctx do
      row = drawn!(ctx, "message", %{"words" => "kvar, curi"})

      value = post!(ctx.member, ctx.group, "Lift je opet u kvar!")
      post!(ctx.member, ctx.group, "Lepo je danas.")

      assert [%ValueProcess{value_id: value_id, data: data, started_by_id: started_by}] =
               runs(row)

      assert value_id == value.id
      assert data == %{"text" => "Lift je opet u kvar!", "author" => ctx.member.username}
      assert started_by == ctx.member.id
    end

    test "in a reply, or from a process, starts nothing", ctx do
      row = drawn!(ctx, "message", %{"words" => "kvar"})
      parent = post!(ctx.member, ctx.group, "Pitanje za sve.")

      post!(ctx.member, ctx.group, "I kod mene je kvar.", %{"parent_id" => parent.id})
      process = Repo.preload(row, :profile).profile
      {:ok, _value} = Social.create_value(process, ctx.group, %{"content" => "Prijavljen kvar."})

      assert runs(row) == []
    end

    test "starts nothing while the process is off", ctx do
      row = drawn!(ctx, "message", %{"words" => "kvar"})
      {:ok, _off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, row.id)

      post!(ctx.member, ctx.group, "kvar")
      assert runs(row) == []
    end
  end

  describe "a sub-group" do
    test "made by hand or from a preset starts a run on it", ctx do
      row = drawn!(ctx, "subgroup", %{"placed" => false})

      {:ok, sub} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "Ulaz B",
          "description" => "Stepenište i lift",
          "description_format" => :markdown
        })

      {:ok, %{group: chat}} =
        Social.create_group_from_preset(ctx.owner, ctx.group, "chat", %{"name" => "Dogovor"})

      subjects = row |> runs() |> Enum.map(& &1.subject_group_id) |> Enum.sort()
      assert subjects == Enum.sort([sub.id, chat.id])

      run = Enum.find(runs(row), &(&1.subject_group_id == sub.id))
      assert run.data["name"] == "Ulaz B"
      assert run.data["description"] =~ "Stepenište i lift"
    end

    test "with a place only, when the process asks for one", ctx do
      row = drawn!(ctx, "subgroup", %{"placed" => true})

      {:ok, _unplaced} =
        Social.create_group_from_preset(ctx.owner, ctx.group, "chat", %{"name" => "Bez mesta"})

      {:ok, %{group: placed}} =
        Social.create_group_from_preset(ctx.owner, ctx.group, "chat", %{"name" => "Klupa"}, %{
          "latitude" => 45.25,
          "longitude" => 19.84
        })

      assert [%ValueProcess{subject_group_id: id}] = runs(row)
      assert id == placed.id
    end

    test "that is a record, a thread or a process's starts nothing", ctx do
      row = drawn!(ctx, "subgroup", %{"placed" => false})

      {:ok, _children} =
        Social.create_children(ctx.owner, ctx.group, [
          %{
            "name" => "Zapis",
            "description" => "",
            "is_public" => true,
            "latitude" => 45.2,
            "longitude" => 19.8,
            "external_key" => "r:1"
          }
        ])

      value = post!(ctx.member, ctx.group, "Razgovor o ovome")

      {:ok, _thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "nit"})

      assert runs(row) == []
    end
  end

  describe "a schedule" do
    defp scheduled!(ctx) do
      drawn!(ctx, "schedule", %{
        "every" => "day",
        "time" => "09:00",
        "time_zone" => "Europe/Belgrade"
      })
    end

    test "is due from when it is switched on, and starts once when its time comes", ctx do
      row = scheduled!(ctx)
      assert %DateTime{} = row.next_run_at
      assert DateTime.compare(row.next_run_at, DateTime.utc_now()) == :gt

      due = DateTime.add(DateTime.utc_now(:second), -60)
      row |> Ecto.Changeset.change(next_run_at: due) |> Repo.update!()

      assert Engine.start_scheduled() >= 1
      local = DateTime.shift_zone!(due, "Europe/Belgrade")
      assert [%ValueProcess{data: data, started_by_id: nil}] = runs(row)

      assert data == %{
               "date" => Calendar.strftime(local, "%d. %m. %Y."),
               "time" => Calendar.strftime(local, "%H:%M")
             }

      assert DateTime.compare(Repo.get!(AppProcess, row.id).next_run_at, DateTime.utc_now()) ==
               :gt

      Engine.start_scheduled()
      assert length(runs(row)) == 1
    end

    test "skips a run more than a day late, and stops with the process", ctx do
      row = scheduled!(ctx)
      late = DateTime.add(DateTime.utc_now(:second), -2 * 86_400)
      row |> Ecto.Changeset.change(next_run_at: late) |> Repo.update!()

      Engine.start_scheduled()
      assert runs(row) == []

      assert DateTime.compare(Repo.get!(AppProcess, row.id).next_run_at, DateTime.utc_now()) ==
               :gt

      {:ok, off} = DrawnProcesses.deactivate(ctx.owner, ctx.group, row.id)
      assert off.next_run_at == nil
    end
  end
end
