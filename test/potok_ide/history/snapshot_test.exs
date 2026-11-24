defmodule PotokIde.History.SnapshotTest do
  @moduledoc """
  A group as it was at a moment: what it had then, what it was called, how
  many records its apps kept, and none of it for those who may not see it.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.History.{GroupChange, Reader, Snapshot}
  alias PotokIde.Processes.GroupFields
  alias PotokIde.{Repo, Social}
  alias PotokIde.Social.{Access, AppData, Group}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("hs#{unique()}")
    {member_account, member} = account_with_profile!("hs#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "name" => "Prvo ime",
        "uses_api" => true,
        "description" => "<p>prvi</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: Social.get_group!(group.id)
    }
  end

  defp reader(ctx, profile, opts \\ []) do
    group = Repo.get!(Group, ctx.group.id)
    Reader.new(group, Access.for_profile(profile, group), profile, opts)
  end

  # Moves all that happened so far an hour back; what it returns is a moment
  # between then and what comes next.
  defp an_hour_later! do
    for table <- ~w(group_alt_descriptions group_fields group_entities group_templates polls
                    group_events values app_processes) do
      Repo.query!(~s(UPDATE "#{table}" SET inserted_at = inserted_at - interval '1 hour'))
    end

    Repo.query!("UPDATE group_changes SET at = at - interval '1 hour'")
    DateTime.add(DateTime.utc_now(), -30, :minute)
  end

  defp names(snapshot, type) do
    case List.keyfind(snapshot.things, type, 0) do
      nil -> []
      {_type, list} -> Enum.map(list, & &1.name)
    end
  end

  defp alt!(ctx, name, text, roles \\ []) do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => name,
        "description" => text,
        "visible_role_keys" => roles
      })

    alt
  end

  test "things by the names they had, without what came and with what went since", ctx do
    stays = alt!(ctx, "Staro", "1")
    goes = alt!(ctx, "Nestalo", "2")
    poll = create_poll!(ctx.owner, ctx.group)
    then = an_hour_later!()

    {:ok, _} = Social.update_alt_description(ctx.owner, ctx.group, stays, %{"name" => "Novo"})
    {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, goes)
    alt!(ctx, "Tek stiglo", "3")
    {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "Drugo ime"})

    snapshot = Snapshot.load(reader(ctx, ctx.owner), then)
    assert names(snapshot, "description") == ["Nestalo", "Staro"]
    assert names(snapshot, "poll") == [poll.question]
    assert {:ok, %{"name" => "Prvo ime"}} = snapshot.group

    now = Snapshot.load(reader(ctx, ctx.owner), DateTime.utc_now())
    assert names(now, "description") == ["Novo", "Tek stiglo"]
    assert {:ok, %{"name" => "Drugo ime"}} = now.group

    # A member does not see what is gone, as nobody but the editors does.
    assert names(Snapshot.load(reader(ctx, ctx.member), then), "description") == ["Staro"]

    assert {:ok, %{"description" => "2"}} =
             Snapshot.thing(reader(ctx, ctx.owner), "description", goes.id, then)

    assert Snapshot.thing(reader(ctx, ctx.member), "description", goes.id, then) == :none
  end

  test "what was changed since and then deleted was there too", ctx do
    alt = alt!(ctx, "Prvo ime", "1")
    rules = %{"rules" => %{"molbe" => %{"edit_own" => true}}}
    {:ok, _} = AppData.save_config(ctx.owner, ctx.group, nil, rules, 0)

    {:ok, value, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{"n" => 1})

    then = an_hour_later!()
    {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, value.id, %{"n" => 2}, nil)
    {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, value.id)
    {:ok, alt} = Social.update_alt_description(ctx.owner, ctx.group, alt, %{"name" => "Drugo"})
    {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)

    reader = reader(ctx, ctx.owner)
    assert names(Snapshot.load(reader, then), "description") == ["Prvo ime"]

    assert {[%{values: %{"data" => %{"n" => 1}}}], false} =
             Snapshot.record_page(reader, nil, "molbe", then)

    # Made after it, changed and deleted, it was not.
    assert names(Snapshot.load(reader, DateTime.add(then, -2, :day)), "description") == []
  end

  test "fields, with their values, those who edit", ctx do
    access = Access.for_profile(ctx.owner, ctx.group)
    attrs = %{"name" => "stanje", "type" => "text"}
    {:ok, field} = GroupFields.declare(ctx.group, access, attrs, ctx.owner)
    Repo.query!("UPDATE group_fields SET value = 'pre' WHERE id = $1", [field.id])
    then = an_hour_later!()
    {:ok, _} = GroupFields.clear(ctx.group, access, field.id, ctx.owner)

    assert names(Snapshot.load(reader(ctx, ctx.owner), then), "field") == ["stanje"]

    assert {:ok, %{"value" => "pre"}} =
             Snapshot.thing(reader(ctx, ctx.owner), "field", field.id, then)

    assert names(Snapshot.load(reader(ctx, ctx.member), then), "field") == []
    assert Snapshot.thing(reader(ctx, ctx.member), "field", field.id, then) == :none
  end

  test "records by their collections, all of them or one's own", ctx do
    rules = %{"rules" => %{"molbe" => %{"edit_own" => true}}}
    {:ok, _} = AppData.save_config(ctx.owner, ctx.group, nil, rules, 0)

    {:ok, mine, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{"n" => 1})

    {:ok, theirs, _} =
      AppData.insert(ctx.owner, ctx.owner_account, ctx.group, nil, "molbe", %{"n" => 2})

    then = an_hour_later!()
    {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, mine.id, %{"n" => 10}, nil)
    {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, theirs.id)

    {:ok, _, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{"n" => 3})

    count = fn profile ->
      reader(ctx, profile)
      |> Snapshot.records(then)
      |> Enum.find(&(&1.collection == "molbe"))
      |> Map.fetch!(:count)
    end

    assert count.(ctx.owner) == 2
    assert count.(ctx.member) == 1

    data = fn profile ->
      {records, false} = Snapshot.record_page(reader(ctx, profile), nil, "molbe", then)
      for %{values: %{"data" => data}} <- records, do: data
    end

    assert data.(ctx.owner) == [%{"n" => 2}, %{"n" => 1}]
    assert data.(ctx.member) == [%{"n" => 1}]

    # Looking at the page as someone else, nothing is one's own.
    nobody = reader(ctx, ctx.member, own: false)
    assert Snapshot.record_page(nobody, nil, "molbe", then) == {[], false}
    assert Enum.filter(Snapshot.records(nobody, then), &(&1.collection == "molbe")) == []
  end

  test "what hid behind roles then stays there", ctx do
    alt = alt!(ctx, "Tajni plan", "tajna", ["admin"])
    then = an_hour_later!()

    {:ok, _} =
      Social.update_alt_description(ctx.owner, ctx.group, alt, %{
        "name" => "Plan",
        "description" => "javno",
        "visible_role_keys" => []
      })

    assert names(Snapshot.load(reader(ctx, ctx.owner), then), "description") == ["Tajni plan"]
    assert names(Snapshot.load(reader(ctx, ctx.member), then), "description") == []
    assert Snapshot.thing(reader(ctx, ctx.member), "description", alt.id, then) == :none
  end

  test "a record's grades, as far as they were released", ctx do
    config = %{
      "rules" => %{
        "molbe" => %{
          "under" => ["a"],
          "score" => %{"release" => "manual", "show" => %{"points" => true}}
        }
      },
      "secret" => %{"score" => %{"molbe" => %{"p" => %{"points" => 1, "right" => "x"}}}}
    }

    {:ok, _} = AppData.save_config(ctx.owner, ctx.group, nil, config, 0)
    data = %{"a" => %{"p" => "x"}}

    {:ok, value, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", data)

    change = %GroupChange{
      subject_type: "record",
      subject_id: value.id,
      creator_id: ctx.member.id,
      collection: "molbe"
    }

    now = DateTime.utc_now()
    assert {:ok, %{"managed" => %{}}} = Snapshot.record(reader(ctx, ctx.owner), change, now)
    assert {:ok, values} = Snapshot.record(reader(ctx, ctx.member), change, now)
    refute Map.has_key?(values, "managed")
  end
end
