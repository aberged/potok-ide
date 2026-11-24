defmodule PotokIde.History.ReadingTest do
  @moduledoc """
  Who reads what of a group's history: each thing by its own rules, as they
  are now and as they were; pages of it; and what a thing was.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{History, Repo, Social}
  alias PotokIde.History.{Feed, GroupChange, Reader, State}
  alias PotokIde.Processes.GroupFields
  alias PotokIde.Social.{Access, AppData, DrawnProcesses, Group, GroupTemplates}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("hr#{unique()}")
    {member_account, member} = account_with_profile!("hr#{unique()}")
    {other_account, other} = account_with_profile!("hr#{unique()}")
    {outsider_account, outsider} = account_with_profile!("hr#{unique()}")

    group =
      group_with_members!(owner, [member, other], %{
        "uses_api" => true,
        "is_public" => true,
        "has_public_chat" => true,
        "description" => "<p>prvi</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "savet"})

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      other: other,
      other_account: other_account,
      outsider: outsider,
      outsider_account: outsider_account,
      role: role.key,
      group: Social.get_group!(group.id)
    }
  end

  defp reader(ctx, profile, opts \\ []) do
    group = Repo.get!(Group, ctx.group.id)

    case Access.for_profile(profile, group) do
      %Access{member?: true} = access -> Reader.new(group, access, profile, opts)
      _outside -> nil
    end
  end

  defp entries(ctx, profile, opts \\ []),
    do:
      ctx
      |> reader(profile)
      |> Feed.page(Keyword.merge([filter: :all], opts))
      |> Map.fetch!(:entries)

  # The changes a profile reads, as `{type, op}`, the newest first.
  defp reads(ctx, profile, opts \\ []) do
    for %{source: :change, row: row} <- entries(ctx, profile, opts),
        do: {row.subject_type, row.op}
  end

  defp sees?(ctx, profile, type, op \\ :changed, opts \\ []),
    do: {type, op} in reads(ctx, profile, opts)

  defp sides(ctx, profile, type, op) do
    change =
      Repo.one(
        from(c in GroupChange,
          where: c.group_id == ^ctx.group.id and c.subject_type == ^type and c.op == ^op,
          order_by: [desc: c.id],
          limit: 1,
          select: c.id
        )
      )

    reader = reader(ctx, profile)

    case Feed.get(reader, change) do
      nil -> nil
      change -> reader |> State.sides(change) |> Map.new(fn {f, b, a} -> {f, {b, a}} end)
    end
  end

  defp config!(ctx, rules, extra \\ %{}) do
    revision =
      case AppData.get_config(ctx.group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    {:ok, config} =
      AppData.save_config(ctx.owner, ctx.group, nil, Map.put(extra, "rules", rules), revision)

    config
  end

  defp record!(ctx, data \\ %{"n" => 1}) do
    {:ok, value, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", data)

    value
  end

  describe "who reads it" do
    test "nobody outside the group, whatever it lets them do", ctx do
      assert_raise FunctionClauseError, fn ->
        Reader.new(ctx.group, Access.for_profile(ctx.outsider, ctx.group), ctx.outsider)
      end

      assert_raise FunctionClauseError, fn ->
        Reader.new(ctx.group, Access.for_profile(nil, ctx.group), nil)
      end
    end

    test "the group's own changes, every member", ctx do
      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "Novo"})
      assert sees?(ctx, ctx.member, "group")

      assert %{"name" => {{:value, old}, {:value, "Novo"}}} =
               sides(ctx, ctx.member, "group", :changed)

      assert old == ctx.group.name
    end

    test "templates, fields and drawings that are off, those who edit", ctx do
      attrs = %{"name" => "Vest", "purpose" => "", "html" => "<p>1</p>", "fields" => []}
      {:ok, _} = GroupTemplates.create(ctx.owner, ctx.group, attrs)

      {:ok, _} =
        GroupFields.declare(
          ctx.group,
          Access.for_profile(ctx.owner, ctx.group),
          %{"name" => "broj", "type" => "number"},
          ctx.owner
        )

      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "kraj"}]
      }

      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "P",
          "graph" => graph,
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      for type <- ["template", "field", "process"] do
        assert sees?(ctx, ctx.owner, type, :created)
        refute sees?(ctx, ctx.member, type, :created)
      end

      # Switched on, it is every member's, and what it was while off is not.
      {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)
      Repo.update_all(GroupChange, set: [at: ~U[2026-01-01 00:00:00.000000Z]])

      {:ok, _} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          process.id,
          %{"name" => "P2", "graph" => graph},
          process.lock_version
        )

      member_rows =
        for %{row: %{subject_type: "process"} = row} <- entries(ctx, ctx.member), do: row.fields

      assert member_rows == [["name"]]
    end

    test "records, those who read the collection, and the author their own", ctx do
      config!(ctx, %{"molbe" => %{"edit_own" => true, "read" => [ctx.role]}})
      value = record!(ctx)
      {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, value.id, %{"n" => 2}, nil)

      assert sees?(ctx, ctx.owner, "record", :changed, filter: :records)
      assert sees?(ctx, ctx.member, "record", :changed, filter: :records)
      refute {"record", :changed} in reads(ctx, ctx.other, filter: :records)

      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.other.id, ctx.role)
      assert sees?(ctx, ctx.other, "record", :changed, filter: :records)

      assert %{"data" => {{:value, %{"n" => 1}}, {:value, %{"n" => 2}}}} =
               sides(ctx, ctx.other, "record", :changed)

      # Looking at the page as someone else, nothing is one's own.
      reader = reader(ctx, ctx.member, own: false)
      rows = for %{row: row} <- Feed.page(reader, filter: :records).entries, do: row.subject_id
      refute value.id in rows
    end

    test "grades, as far as they were released", ctx do
      rules = %{
        "molbe" => %{
          "edit_own" => true,
          "under" => ["a"],
          "score" => %{"release" => "manual", "show" => %{"points" => true}}
        }
      }

      config!(ctx, rules, %{
        "secret" => %{"score" => %{"molbe" => %{"p1" => %{"points" => 5, "right" => "x"}}}}
      })

      value = record!(ctx, %{"a" => %{"p1" => "y"}})

      {:ok, _, _} =
        AppData.grade(ctx.owner, ctx.group, nil, value.id, %{
          "p1" => %{"points" => 3, "feedback" => "može"}
        })

      assert %{"managed" => {_, {:value, %{}}}} = sides(ctx, ctx.owner, "record", :changed)
      assert %{"managed" => {_, :hidden}} = sides(ctx, ctx.member, "record", :changed)
    end

    test "the records of an app that took another's place, by the rules of their own", ctx do
      config!(ctx, %{"molbe" => %{"edit_own" => true, "read" => []}})
      value = record!(ctx)

      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Javna",
          "description" => "<p>app</p>",
          "uses_api" => true
        })

      {:ok, _} =
        AppData.save_config(
          ctx.owner,
          ctx.group,
          alt,
          %{"rules" => %{"molbe" => %{"read" => ["everyone"]}}},
          0
        )

      {:ok, _, _} = Social.promote_alt_description(ctx.owner, ctx.group, alt, "Stara")

      rows = for %{row: row} <- entries(ctx, ctx.other, filter: :records), do: row.subject_id
      refute value.id in rows
    end

    test "an alternative description, who sees it now and saw it then", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Savet",
          "description" => "tajna 1",
          "visible_role_keys" => [ctx.role]
        })

      {:ok, alt} =
        Social.update_alt_description(ctx.owner, ctx.group, alt, %{"description" => "tajna 2"})

      refute sees?(ctx, ctx.member, "description")
      assert sides(ctx, ctx.member, "description", :changed) == nil

      # Opened to everyone with another text: what it was then stays hidden.
      Repo.update_all(GroupChange, set: [at: ~U[2026-01-01 00:00:00.000000Z]])

      {:ok, _} =
        Social.update_alt_description(ctx.owner, ctx.group, alt, %{
          "description" => "javno",
          "visible_role_keys" => []
        })

      assert sees?(ctx, ctx.member, "description")

      assert %{"description" => {:hidden, {:value, "javno"}}} =
               sides(ctx, ctx.member, "description", :changed)

      assert %{"description" => {{:value, "tajna 2"}, {:value, "javno"}}} =
               sides(ctx, ctx.owner, "description", :changed)

      # Closed again, with a secret text: what the open one became is hidden too.
      Repo.update_all(GroupChange, set: [at: ~U[2026-01-01 00:00:00.000000Z]])
      alt = Repo.reload!(alt)

      {:ok, _} =
        Social.update_alt_description(ctx.owner, ctx.group, alt, %{
          "description" => "tajna 3",
          "visible_role_keys" => [ctx.role]
        })

      alt = Repo.reload!(alt)
      Repo.update_all(GroupChange, set: [at: ~U[2026-01-01 00:00:00.000000Z]])

      {:ok, _} =
        Social.update_alt_description(ctx.owner, ctx.group, alt, %{
          "description" => "opet javno",
          "visible_role_keys" => []
        })

      changes =
        for %{row: %{subject_type: "description"} = row} <-
              entries(ctx, ctx.member, filter: :group),
            do: Feed.get(reader(ctx, ctx.member), row.id)

      shown =
        for change <- changes,
            change,
            {"description", b, a} <- State.sides(reader(ctx, ctx.member), change),
            side <- [b, a],
            match?({:value, _}, side),
            do: elem(side, 1)

      refute Enum.any?(shown, &String.starts_with?(&1, "tajna"))

      for days <- 0..3 do
        moment = DateTime.add(~U[2026-01-01 00:00:00Z], -days, :day)
        refute inspect(State.at(reader(ctx, ctx.member), "description", alt.id, moment)) =~ "tajna"
      end
    end

    test "a deleted description and its app, those who edit", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "App",
          "description" => "<p>app</p>",
          "uses_api" => true
        })

      {:ok, _} = Social.create_data_value(ctx.other, ctx.group, %{"content" => "1"}, alt)
      assert sees?(ctx, ctx.member, "record", :created, filter: :records)
      {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)

      assert sees?(ctx, ctx.owner, "record", :deleted, filter: :records)
      refute sees?(ctx, ctx.member, "record", :deleted, filter: :records)
      refute sees?(ctx, ctx.member, "description", :deleted)
    end

    test "sub-groups and shortcuts, who sees the group they lead to", ctx do
      sub = group_with_members!(ctx.owner, [], %{:parent => ctx.group, "is_public" => true})
      target = group_with_members!(ctx.owner, [], %{"is_public" => true})
      {:ok, _} = Social.create_group_shortcut(ctx.owner, ctx.group, target.id)

      assert sees?(ctx, ctx.member, "sub_group", :created)
      assert sees?(ctx, ctx.member, "shortcut", :created)

      for closed <- [sub, target],
          do:
            {:ok, _} =
              Social.update_group(ctx.owner, Repo.get!(Group, closed.id), %{"is_public" => false})

      refute sees?(ctx, ctx.member, "sub_group", :created)
      refute sees?(ctx, ctx.member, "shortcut", :created)
      assert sees?(ctx, ctx.owner, "sub_group", :created)
    end

    test "blocks among changes of access, those who may lift them", ctx do
      {:ok, _} = Social.block_from_group(ctx.owner, ctx.group, ctx.outsider)

      kinds = fn profile ->
        for %{source: :access, row: row} <- entries(ctx, profile), do: row.kind
      end

      assert :member_blocked in kinds.(ctx.owner)
      refute :member_blocked in kinds.(ctx.member)
      assert :role_added in kinds.(ctx.member)
    end
  end

  describe "the pages" do
    test "go on from each other, the two histories in one order", ctx do
      for n <- 1..5 do
        {:ok, _} = Social.create_value(ctx.owner, ctx.group, %{"content" => "#{n}"})
      end

      for value <- Social.list_group_values(ctx.group), do: Social.delete_value(ctx.owner, value)
      reader = reader(ctx, ctx.owner)
      all = Feed.page(reader, limit: 100)
      assert all.cursor == nil

      paged =
        Stream.unfold(%{entries: [], cursor: :start}, fn
          %{cursor: nil} ->
            nil

          %{cursor: cursor} ->
            cursor = if cursor == :start, do: nil, else: cursor
            page = Feed.page(reader, limit: 2, cursor: cursor)
            {page.entries, page}
        end)
        |> Enum.to_list()
        |> List.flatten()

      assert Enum.map(paged, & &1.id) == Enum.map(all.entries, & &1.id)

      assert Enum.map(all.entries, & &1.at) ==
               Enum.sort(Enum.map(all.entries, & &1.at), {:desc, DateTime})
    end

    test "narrow to a kind, a person, a day and one thing", ctx do
      {:ok, message} = Social.create_value(ctx.member, ctx.group, %{"content" => "x"})
      {:ok, message} = Social.update_value(ctx.member, message, %{"content" => "y"})
      {:ok, _} = Social.toggle_value_reaction(ctx.other, ctx.group, message, "👍")
      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "Novo"})

      refute sees?(ctx, ctx.member, "reaction", :created)
      assert sees?(ctx, ctx.member, "reaction", :created, filter: :talk)
      assert reads(ctx, ctx.member, filter: :group) == [{"group", :changed}]
      assert entries(ctx, ctx.member, filter: :access) |> Enum.all?(&(&1.source == :access))
      assert reads(ctx, ctx.owner, actor: ctx.member.id) == [{"message", :changed}]

      assert reads(ctx, ctx.owner, subject: {"group", ctx.group.id}) == [{"group", :changed}]
      assert entries(ctx, ctx.owner, until: ~U[2026-01-01 00:00:00Z]) == []
    end

    test "what is said in a thread is told in its group, to its members", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "tema"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "t"})

      {:ok, reply} = Social.create_value(ctx.owner, thread, %{"content" => "r"})
      {:ok, _} = Social.delete_value(ctx.owner, reply)
      assert reads(ctx, ctx.member, filter: :talk) == [{"message", :deleted}]
    end

    test "settings told as changes of access are not told twice", ctx do
      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"has_public_chat" => false})
      refute sees?(ctx, ctx.member, "group")
      assert sees?(ctx, ctx.member, "group", :changed, filter: :group)
      assert Enum.any?(entries(ctx, ctx.member), &(&1.source == :access))
    end

    test "a collection deleted at once is one entry", ctx do
      config!(ctx, %{"molbe" => %{"read" => []}})
      for n <- 1..3, do: record!(ctx, %{"n" => n})
      {:ok, 3} = AppData.delete_collection(ctx.owner, ctx.group, nil, "molbe")

      deleted = fn profile ->
        for %{row: %{op: :deleted} = row} <- entries(ctx, profile, filter: :records), do: row
      end

      assert [%{cause: %{"count" => 3}}] = deleted.(ctx.owner)
      # Their author, who does not read the rest, sees each of their own.
      assert length(deleted.(ctx.member)) == 3
      assert deleted.(ctx.other) == []
    end

    test "names, of what is there and of what is gone", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{"name" => "A", "description" => "1"})

      {:ok, gone} =
        Social.create_alt_description(ctx.owner, ctx.group, %{"name" => "G", "description" => "1"})

      {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, gone)
      poll = create_poll!(ctx.owner, ctx.group)
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "x"})
      {:ok, value} = Social.update_value(ctx.owner, value, %{"content" => "y"})

      names = Feed.names(reader(ctx, ctx.owner), entries(ctx, ctx.owner))
      assert names[{"description", alt.id}] == "A"
      assert names[{"description", gone.id}] == "G"
      assert names[{"poll", poll.id}] == "Where do we go?"
      assert names[{"message", value.id}]
    end
  end

  describe "what a thing was" do
    test "is what it is with the changes since taken back, whatever they were", ctx do
      rename = fn attrs ->
        group = Repo.get!(Group, ctx.group.id)
        {:ok, _} = Social.update_group(ctx.owner, group, attrs)
      end

      start = State.current("group", ctx.group.id)
      :rand.seed(:exsss, {1, 2, 3})

      # Each state, and a moment at which it stood.
      states =
        for n <- 1..12 do
          rename.(
            Enum.random([
              %{"name" => "ime #{n}"},
              %{"description" => "<p>#{n}</p>"},
              %{"home_page" => Enum.random(["chat", "description"])},
              %{"latitude" => "44.#{n}", "longitude" => "20.#{n}", "pin_icon" => "place"}
            ])
          )

          # One row for each, as if five minutes passed between them.
          Repo.query!("UPDATE group_changes SET at = at - interval '1 hour'")
          state = State.current("group", ctx.group.id)
          {n, state}
        end

      reader = reader(ctx, ctx.owner)
      now = DateTime.utc_now()

      for {n, state} <- states do
        # The n-th of 12 changes is (12 - n + 1) hours old.
        moment = DateTime.add(now, -((12 - n) * 3600 + 1800), :second)
        assert {:ok, ^state} = State.at(reader, "group", ctx.group.id, moment)
      end

      assert {:ok, ^start} =
               State.at(reader, "group", ctx.group.id, DateTime.add(now, -1, :day))
    end

    test "a record that is gone, and one that was not there yet", ctx do
      config!(ctx, %{"molbe" => %{"edit_own" => true}})
      value = record!(ctx, %{"n" => 1})
      before = ~U[2026-01-01 00:00:00.000000Z]
      then = DateTime.utc_now()
      {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, value.id, %{"n" => 2}, nil)
      {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, value.id)

      reader = reader(ctx, ctx.owner)
      assert {:ok, %{"data" => %{"n" => 1}}} = State.at(reader, "record", value.id, then)
      assert State.at(reader, "record", value.id, before) == :none
      assert State.at(reader, "record", value.id, DateTime.utc_now()) == :none
    end

    test "emptied, it says so", ctx do
      {:ok, _} = Social.update_group_description(ctx.owner, ctx.group, %{"description" => "2"})

      change =
        Repo.one!(from(c in GroupChange, where: c.subject_type == "group", limit: 1))

      {:ok, 1} = History.empty(ctx.owner, ctx.group, change)

      assert %{"description" => {:emptied, {:value, "2"}}} =
               sides(ctx, ctx.owner, "group", :changed)

      assert {:ok, %{"description" => :emptied}} =
               State.at(
                 reader(ctx, ctx.owner),
                 "group",
                 ctx.group.id,
                 ~U[2026-01-01 00:00:00.000000Z]
               )
    end

    test "the secret part of a config is in none of it", ctx do
      config = config!(ctx, %{}, %{"secret" => %{"k" => "tajna"}, "form" => 1})
      refute inspect(State.current("record", config.id)) =~ "tajna"
    end
  end
end
