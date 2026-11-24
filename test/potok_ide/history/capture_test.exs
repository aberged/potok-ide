defmodule PotokIde.History.CaptureTest do
  @moduledoc """
  What the history of a group keeps of each thing in it, whose name is on it,
  and what it leaves out.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{Events, History, Notices, Polls, Repo, Social}
  alias PotokIde.History.GroupChange
  alias PotokIde.Polls.Poll
  alias PotokIde.Processes.{GroupEntities, GroupFields}

  alias PotokIde.Social.{
    Access,
    AppData,
    DrawnProcesses,
    Group,
    GroupAltDescription,
    GroupTemplates,
    Value
  }

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("hc#{unique()}")
    {member_account, member} = account_with_profile!("hc#{unique()}")

    group =
      group_with_members!(owner, [member], %{
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

  # The history, oldest first, with the old values.
  defp changes(group, type \\ nil) do
    query =
      from(c in GroupChange,
        where: c.group_id == ^group.id,
        order_by: c.id,
        select_merge: %{before: c.before}
      )

    query = if type, do: where(query, [c], c.subject_type == ^type), else: query
    Repo.all(query)
  end

  defp config!(ctx, data, revision) do
    {:ok, config} = AppData.save_config(ctx.owner, ctx.group, nil, data, revision)
    config
  end

  defp record!(ctx, rules \\ %{"molbe" => %{"edit_own" => true}}, data \\ %{"naslov" => "A"}) do
    config!(ctx, %{"rules" => rules}, 0)

    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", data)

    value
  end

  describe "a group" do
    test "its settings, with the old values of what changed and no more", ctx do
      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "Novo ime"})

      assert [change] = changes(ctx.group)
      assert %{subject_type: "group", op: :changed, fields: ["name"]} = change
      assert change.before == %{"name" => ctx.group.name}
      assert change.actor_id == ctx.owner.id
      assert change.op_id
    end

    test "what Potok keeps for itself leaves nothing", ctx do
      {:ok, _} = Social.create_value(ctx.member, ctx.group, %{"content" => "zdravo"})
      {_, joined} = account_with_profile!("hc#{unique()}")
      add_member!(ctx.owner, ctx.group, joined)
      Repo.query!("UPDATE groups SET member_count = 7 WHERE id = $1", [ctx.group.id])

      assert changes(ctx.group) == []
    end

    test "a picture is marked and not kept", ctx do
      picture = "data:image/png;base64,iVBORw0KGgo="
      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"group_picture_url" => picture})

      assert [%{fields: ["group_picture_url"], before: nil}] = changes(ctx.group)
    end

    test "a burst by one person is one row, with the values from before it", ctx do
      for text <- ["<p>drugi</p>", "<p>treći</p>"] do
        {:ok, _} =
          Social.update_group_description(ctx.owner, Repo.get!(Group, ctx.group.id), %{
            "description" => text
          })
      end

      assert [change] = changes(ctx.group)
      assert change.before == %{"description" => "<p>prvi</p>"}
      assert change.last_at

      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")
      group = Repo.get!(Group, ctx.group.id)
      {:ok, _} = Social.update_group_description(ctx.member, group, %{"description" => "4"})

      assert [_, %{before: %{"description" => "<p>treći</p>"}, actor_id: actor_id}] =
               changes(ctx.group)

      assert actor_id == ctx.member.id
    end

    test "changed past every function, it is kept with no name on it", ctx do
      Repo.update_all(from(g in Group, where: g.id == ^ctx.group.id), set: [name: "mimo"])

      assert [%{actor_id: nil, cause: nil, before: before}] = changes(ctx.group)
      assert before == %{"name" => ctx.group.name}
    end

    test "a public sub-group is told of above, a private one and a thread are not", ctx do
      public = group_with_members!(ctx.owner, [], %{:parent => ctx.group, "is_public" => true})
      _private = group_with_members!(ctx.owner, [], %{parent: ctx.group})
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "tema"})

      {:ok, _thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "t"})

      assert [%{op: :created, subject_id: id}] = changes(ctx.group, "sub_group")
      assert id == public.id

      {:ok, _} = Social.delete_group(ctx.owner, public)

      assert [_, %{op: :deleted, before: before, actor_id: actor_id}] =
               changes(ctx.group, "sub_group")

      assert before == %{"name" => public.name}
      assert actor_id == ctx.owner.id
    end

    test "in the root nothing is told of", ctx do
      root = Social.get_root_group!()
      group_with_members!(ctx.owner, [], %{"is_public" => true})
      assert changes(root, "sub_group") == []
    end

    test "its history goes with it, and the rest of it leaves none", ctx do
      record!(ctx)
      {:ok, _} = Social.create_value(ctx.owner, ctx.group, %{"content" => "poruka"})
      {:ok, _} = Social.delete_group(ctx.owner, ctx.group)
      assert changes(ctx.group) == []
    end

    test "a direct conversation has none", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, value} = Social.create_value(ctx.owner, direct, %{"content" => "tajno"})
      {:ok, value} = Social.update_value(ctx.owner, value, %{"content" => "tajnije"})
      {:ok, _} = Social.toggle_value_reaction(ctx.member, direct, value, "👍")
      {:ok, _} = Social.delete_value(ctx.owner, Repo.get!(Value, value.id))
      assert changes(direct) == []
    end
  end

  describe "descriptions" do
    test "each side says who saw it", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Za savet",
          "description" => "tajna",
          "visible_role_keys" => ["admin"]
        })

      {:ok, alt} =
        Social.update_alt_description(ctx.owner, ctx.group, alt, %{
          "description" => "javno",
          "visible_role_keys" => []
        })

      {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)

      assert [created, changed, deleted] = changes(ctx.group, "description")
      assert %{op: :created, keys_before: nil, keys_after: ["admin"], before: nil} = created
      assert %{op: :changed, keys_before: ["admin"], keys_after: []} = changed
      assert changed.before == %{"description" => "tajna", "visible_role_keys" => ["admin"]}
      assert %{op: :deleted, keys_before: [], before: %{"description" => "javno"}} = deleted
      assert Enum.all?([created, changed, deleted], &(&1.actor_id == ctx.owner.id))
    end

    test "a deleted one takes its app's records along, each of them kept", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "App",
          "description" => "<p>app</p>",
          "uses_api" => true
        })

      {:ok, _} = Social.create_data_value(ctx.member, ctx.group, %{"content" => "1"}, alt)
      {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)

      assert [%{op: :created}, %{op: :deleted} = deleted] = changes(ctx.group, "record")
      assert deleted.before["content"] == "1"
      assert deleted.alt_description_id == alt.id
      assert deleted.actor_id == ctx.owner.id
      assert deleted.creator_id == ctx.member.id
    end

    test "trading places with the default takes the history of its records along", ctx do
      value = record!(ctx)

      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "App",
          "description" => "<p>app</p>",
          "uses_api" => true
        })

      {:ok, _, _} = Social.promote_alt_description(ctx.owner, ctx.group, alt, "Stari")

      assert Enum.all?(changes(ctx.group, "record"), &(&1.alt_description_id == alt.id))
      assert [%{fields: ["moved"]}] = changes(ctx.group, "app")
      # Nothing of the trade is told of the records themselves, and the row
      # that held their place for a moment left no trace.
      assert [_config, %{op: :created, subject_id: id}] = changes(ctx.group, "record")
      assert id == value.id
      assert [%{op: :created}, %{op: :changed}] = changes(ctx.group, "description")
      refute Repo.exists?(from(d in GroupAltDescription, where: d.position < 0))
    end

    test "a kind put in place of a description leaves its versions to the editors", ctx do
      {:ok, _} =
        Social.update_group_description(ctx.owner, ctx.group, %{"description" => "<p>2</p>"})

      {:ok, %{parked: parked}} =
        Social.change_group_preset(
          ctx.owner,
          Repo.get!(Group, ctx.group.id),
          "page",
          "Stari opis"
        )

      assert parked
      described = Enum.filter(changes(ctx.group, "group"), &("description" in &1.fields))
      assert described != []
      assert Enum.all?(described, &(&1.keys_before == ["admin"]))
      # What the description is now is everyone's.
      assert List.last(described).keys_after == nil
      assert List.last(described).cause == %{"via" => "kind"}
    end
  end

  describe "an app's records" do
    test "made, changed and deleted, and by whom", ctx do
      value = record!(ctx, %{"molbe" => %{"edit_own" => true}}, %{"naslov" => "A"})

      {:ok, _, _} =
        AppData.update(ctx.member, ctx.group, nil, value.id, %{"naslov" => "B"}, nil)

      {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, value.id)

      assert [created, changed, deleted] =
               ctx.group |> changes("record") |> Enum.filter(&(&1.subject_id == value.id))

      assert %{op: :created, before: nil, collection: "molbe"} = created
      assert created.actor_id == ctx.member.id
      assert changed.before == %{"data" => %{"naslov" => "A"}}
      assert changed.actor_id == ctx.member.id
      assert deleted.before["data"] == %{"naslov" => "B"}
      assert deleted.actor_id == ctx.owner.id
      assert deleted.creator_id == ctx.member.id
    end

    test "a whole collection is one act", ctx do
      record!(ctx)
      {:ok, _, _} = AppData.insert(ctx.owner, ctx.owner_account, ctx.group, nil, "molbe", %{})
      {:ok, 2} = AppData.delete_collection(ctx.owner, ctx.group, nil, "molbe")

      deleted = ctx.group |> changes("record") |> Enum.filter(&(&1.op == :deleted))
      assert [%{op_id: op}, %{op_id: op}] = deleted
      assert op
      # One of them stands for both.
      assert [%{cause: %{"count" => 2}}] = Enum.filter(deleted, & &1.listed)
      assert Enum.all?(deleted, &(&1.actor_id == ctx.owner.id))
    end

    test "the author of an anonymous one stays one", ctx do
      value =
        record!(ctx, %{"molbe" => %{"edit_own" => true, "anonymous" => true}}, %{"t" => 1})

      {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, value.id, %{"t" => 2}, nil)

      mine = ctx.group |> changes("record") |> Enum.filter(&(&1.subject_id == value.id))
      assert length(mine) == 2
      assert Enum.all?(mine, &(is_nil(&1.actor_id) and &1.anonymous))
    end

    test "the secret part of a config is never kept", ctx do
      config!(ctx, %{"form" => 1, "secret" => %{"kljuc" => "x"}}, 0)
      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")

      {:ok, _} =
        AppData.save_config(
          ctx.member,
          ctx.group,
          nil,
          %{"form" => 1, "secret" => %{"kljuc" => "y"}},
          0
        )

      assert [_created, %{fields: ["secret"], before: nil}] = changes(ctx.group, "record")

      {:ok, _} = AppData.save_config(ctx.owner, ctx.group, nil, %{"form" => 2}, 1)
      assert [_, _, %{fields: fields, before: before}] = changes(ctx.group, "record")
      assert fields == ["data", "secret"]
      assert before["data"]["form"] == 1
      refute Map.has_key?(before["data"], "secret")
    end

    test "asking for pushes is nobody's history", ctx do
      record!(ctx)
      count = length(changes(ctx.group))
      :ok = ok(AppData.set_notifications(ctx.owner, ctx.group, nil, "molbe", true))
      :ok = ok(AppData.set_notifications(ctx.owner, ctx.group, nil, "molbe", false))
      assert length(changes(ctx.group)) == count
    end
  end

  defp ok(:ok), do: :ok
  defp ok({:ok, _}), do: :ok

  describe "messages and reactions" do
    test "only that a message was changed or deleted, never its text", ctx do
      {:ok, value} = Social.create_value(ctx.member, ctx.group, %{"content" => "prvi tekst"})
      {:ok, value} = Social.update_value(ctx.member, value, %{"content" => "drugi tekst"})
      {:ok, _} = Social.delete_value(ctx.owner, value)

      assert [changed, deleted] = changes(ctx.group, "message")
      assert %{op: :changed, before: nil, fields: []} = changed
      assert changed.actor_id == ctx.member.id
      assert deleted.actor_id == ctx.owner.id
      assert deleted.creator_id == ctx.member.id
      assert Map.keys(deleted.before) == ["inserted_at"]

      %{rows: rows} = Repo.query!("SELECT c::text FROM group_changes c")
      refute Enum.any?(List.flatten(rows), &String.contains?(&1, "tekst"))
    end

    test "a reaction given and taken back, without the emoji", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "x"})
      {:ok, value} = Social.toggle_value_reaction(ctx.member, ctx.group, value, "👍")
      {:ok, _} = Social.toggle_value_reaction(ctx.member, ctx.group, value, "👍")
      {:ok, _} = Social.toggle_group_reaction(ctx.member, ctx.group, "🎉")

      assert [%{op: :created} = given, %{op: :deleted}] = changes(ctx.group, "reaction")
      assert {given.actor_id, given.subject_id} == {ctx.member.id, value.id}
      assert [%{op: :created}] = changes(ctx.group, "group_reaction")

      %{rows: rows} = Repo.query!("SELECT c::text FROM group_changes c")
      refute Enum.any?(List.flatten(rows), &String.contains?(&1, "👍"))
    end

    test "a message's reactions go with it and say nothing", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "x"})
      {:ok, value} = Social.toggle_value_reaction(ctx.member, ctx.group, value, "👍")
      {:ok, _} = Social.delete_value(ctx.owner, value)
      assert [%{op: :created}] = changes(ctx.group, "reaction")
    end
  end

  describe "polls" do
    test "a vote leaves nothing, in a secret poll and in an open one", ctx do
      for secret <- ["true", "false"] do
        poll = create_poll!(ctx.owner, ctx.group, %{"secret" => secret})
        count = length(changes(ctx.group))
        vote!(ctx.member, ctx.member_account, poll)
        vote!(ctx.owner, ctx.owner_account, poll, 1)
        assert length(changes(ctx.group)) == count
      end
    end

    test "changed, its answers too, closed and opened again without its outcome", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      [sea, mountains] = option_ids(poll)

      {:ok, poll} =
        Polls.update_poll(
          ctx.owner,
          poll,
          poll_attrs(%{
            "question" => "Kuda?",
            "options" => %{
              "0" => %{"id" => to_string(sea), "text" => "More"},
              "1" => %{"id" => to_string(mountains), "text" => "Planina"}
            }
          }),
          zone()
        )

      vote!(ctx.member, ctx.member_account, poll)
      {:ok, poll} = Polls.close_poll(ctx.owner, poll)
      {:ok, _} = Polls.reopen_poll(ctx.owner, poll)

      rows = changes(ctx.group, "poll")
      assert Enum.map(rows, & &1.op) == [:created, :changed, :changed, :changed, :changed]
      assert [_, question, options, closed, reopened] = rows
      assert question.before["question"] == "Where do we go?"

      assert options.before == %{
               "options" => [%{"text" => "Sea"}, %{"text" => "Mountains"}]
             }

      assert closed.fields == ["closed_at"]
      assert reopened.fields == ["closed_at"]
      assert Enum.all?(rows, &(&1.actor_id == ctx.owner.id))
    end

    test "closed at its deadline by nobody", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"closes_local" => local_in(2)})
      later = DateTime.add(DateTime.utc_now(:second), 3, :hour)
      assert [%Poll{id: id}] = Polls.Deadlines.close_due(later)
      assert id == poll.id

      assert %{actor_id: nil, cause: %{"via" => "deadline"}} =
               List.last(changes(ctx.group, "poll"))
    end

    test "deleted with its answers, and its message without its text", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{}, announce: true)
      {:ok, _} = Polls.delete_poll(ctx.owner, poll)

      deleted = List.last(changes(ctx.group, "poll"))
      assert deleted.op == :deleted
      assert deleted.actor_id == ctx.owner.id
      assert deleted.before["question"] == "Where do we go?"
      assert deleted.before["options"] == [%{"text" => "Sea"}, %{"text" => "Mountains"}]
      refute Map.has_key?(deleted.before, "voters_count")
      refute Map.has_key?(deleted.before, "outcome")
      assert [%{op: :deleted}] = changes(ctx.group, "message")
    end

    test "an answer a member added does not say whose it is", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"allow_member_options" => "true"})
      {:ok, _} = Polls.add_option(ctx.member, poll, %{"text" => "Jezero"})

      assert %{actor_id: nil, cause: %{"via" => "member_option"}, before: before} =
               List.last(changes(ctx.group, "poll"))

      assert before == %{"options" => [%{"text" => "Sea"}, %{"text" => "Mountains"}]}
    end

    test "a new question is no change of the message that carries it", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{}, announce: true)
      attrs = poll_attrs(%{"question" => "Q2"}) |> Map.delete("options")
      {:ok, _} = Polls.update_poll(ctx.owner, poll, attrs, zone())
      assert changes(ctx.group, "message") == []
    end
  end

  describe "events, notices, shortcuts and templates" do
    test "an event changed and cancelled; answers to it leave nothing", ctx do
      event = create_event!(ctx.owner, ctx.group, event_attrs(Date.add(today(), 3)))
      {:ok, event} = Events.update_event(ctx.owner, event, %{"title" => "Trening"})
      {:ok, _} = Events.respond(ctx.member, event, Date.add(today(), 3), :going)
      {:ok, _} = Events.cancel_event(ctx.owner, event)

      assert [created, changed, cancelled] = changes(ctx.group, "event")
      assert created.op == :created
      assert changed.before == %{"title" => "Training"}
      assert cancelled.fields == ["cancelled_at"]
      assert Enum.all?([created, changed, cancelled], &(&1.actor_id == ctx.owner.id))
    end

    test "the place of an event that is gone names nobody", ctx do
      place =
        group_with_members!(ctx.owner, [ctx.member], %{
          "is_public" => true,
          "latitude" => "44.8",
          "longitude" => "20.4",
          "pin_icon" => "place"
        })

      attrs =
        event_attrs(Date.add(today(), 3), %{
          "place" => "group",
          "place_group_id" => to_string(place.id)
        })

      event = create_event!(ctx.owner, ctx.group, attrs)
      assert Repo.reload!(event).place_group_id == place.id
      {:ok, _} = Social.delete_group(ctx.owner, Repo.get!(Group, place.id))

      assert %{op: :changed, actor_id: nil, cause: %{"via" => "gone"}} =
               List.last(changes(ctx.group, "event"))
    end

    test "a notice deleted, without its text", ctx do
      access = Access.for_profile(ctx.owner, ctx.group)
      {:ok, notice} = Notices.send_notice(ctx.owner, ctx.group, access, %{"body" => "Važno"})
      assert changes(ctx.group, "notice") == []
      {:ok, _} = Notices.delete_notice(ctx.owner, ctx.group, access, notice.id)

      assert [%{op: :deleted, before: nil, actor_id: actor_id}] = changes(ctx.group, "notice")
      assert actor_id == ctx.owner.id
    end

    test "a shortcut, by the group it leads to", ctx do
      target = group_with_members!(ctx.owner, [], %{"is_public" => true})
      {:ok, shortcut} = Social.create_group_shortcut(ctx.owner, ctx.group, target.id)
      {:ok, _} = Social.delete_group_shortcut(ctx.owner, shortcut.id)

      assert [%{op: :created, subject_id: id}, %{op: :deleted, subject_id: id}] =
               changes(ctx.group, "shortcut")

      assert id == target.id
    end

    test "a template", ctx do
      attrs = %{"name" => "Vest", "purpose" => "", "html" => "<p>1</p>", "fields" => []}
      {:ok, template} = GroupTemplates.create(ctx.owner, ctx.group, attrs)

      {:ok, template} =
        GroupTemplates.update(ctx.owner, ctx.group, template, %{"html" => "<p>2</p>"})

      {:ok, _} = GroupTemplates.delete(ctx.owner, ctx.group, template)

      assert [%{op: :created}, changed, deleted] = changes(ctx.group, "template")
      assert changed.before == %{"html" => "<p>1</p>"}
      assert deleted.before["html"] == "<p>2</p>"
    end
  end

  describe "processes" do
    defp graph do
      %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "polje",
            "type" => "serviceTask",
            "action" => "set",
            "field" => "stanje",
            "value" => "\"ok\""
          },
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "polje"},
          %{"from" => "polje", "to" => "kraj"}
        ]
      }
    end

    test "drawn, switched on, changed and deleted; off it is the editors' alone", ctx do
      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "Prijava",
          "graph" => graph(),
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)

      {:ok, process} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          process.id,
          %{"name" => "Prijava 2", "graph" => graph()},
          process.lock_version
        )

      {:ok, _} = DrawnProcesses.delete(ctx.owner, ctx.group, process.id)

      assert [created, changed | _] = rows = changes(ctx.group, "process")
      assert %{op: :created, keys_after: ["admin"]} = created
      # Switched on and renamed within five minutes: one row, with both.
      assert changed.keys_before == ["admin"]
      assert changed.before["active"] == false
      assert changed.before["name"] == "Prijava"
      assert List.last(rows).op == :deleted
      assert List.last(rows).before["graph"]["v"] == 2
      assert Enum.all?(rows, &(&1.actor_id == ctx.owner.id))

      # The field its drawing sets came with it, by the same hand.
      assert [%{op: :created, actor_id: actor_id}] = changes(ctx.group, "field")
      assert actor_id == ctx.owner.id
    end

    test "fields and entities, by the editor who signs", ctx do
      access = Access.for_profile(ctx.owner, ctx.group)

      {:ok, field} =
        GroupFields.declare(ctx.group, access, %{"name" => "broj", "type" => "number"}, ctx.owner)

      {:ok, _} = GroupFields.delete(ctx.group, access, field.id, ctx.owner)

      {:ok, entity} =
        GroupEntities.create(
          ctx.group,
          access,
          %{"name" => "Stan", "attributes" => [%{"name" => "broj", "type" => "number"}]},
          ctx.owner
        )

      {:ok, _} = GroupEntities.update(ctx.group, access, entity, %{"name" => "Kuća"}, ctx.owner)

      assert [%{op: :created}, %{op: :deleted, before: %{"name" => "broj"}}] =
               changes(ctx.group, "field")

      assert [%{op: :created}, %{before: %{"name" => "Stan"}}] = changes(ctx.group, "entity")
      assert Enum.all?(changes(ctx.group), &(&1.actor_id == ctx.owner.id))
    end
  end

  describe "signing" do
    test "a signature inside another adds to it, and goes when it is through", ctx do
      rename = fn name ->
        Repo.update_all(from(g in Group, where: g.id == ^ctx.group.id), set: [name: name])
      end

      {:ok, _} =
        History.transaction([actor: ctx.owner, process: 7], fn ->
          rename.("1")
          History.within([actor: ctx.member], fn -> rename.("2") end)
          rename.("3")
        end)

      rename.("4")

      assert [one, two, three, four] = changes(ctx.group)
      assert {one.actor_id, one.cause} == {ctx.owner.id, %{"process" => 7}}
      assert {two.actor_id, two.cause} == {ctx.member.id, %{"process" => 7}}
      assert {three.actor_id, three.cause} == {ctx.owner.id, %{"process" => 7}}
      assert {four.actor_id, four.cause, four.op_id} == {nil, nil, nil}
      assert one.op_id == two.op_id
    end

    test "an error takes the change back, and the next signs afresh", ctx do
      assert {:error, :no} =
               History.signed([actor: ctx.owner], fn ->
                 Repo.update_all(from(g in Group, where: g.id == ^ctx.group.id),
                   set: [name: "ne"]
                 )

                 {:error, :no}
               end)

      assert changes(ctx.group) == []
      assert Repo.get!(Group, ctx.group.id).name == ctx.group.name

      {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "da"})
      assert [%{actor_id: actor_id}] = changes(ctx.group)
      assert actor_id == ctx.owner.id
    end

    test "a write that raised leaves no signature behind", ctx do
      assert_raise RuntimeError, fn ->
        History.transaction([actor: ctx.owner], fn -> raise "ne" end)
      end

      Repo.update_all(from(g in Group, where: g.id == ^ctx.group.id), set: [name: "posle"])
      assert [%{actor_id: nil}] = changes(ctx.group)
    end

    test "switched off, nothing is kept", ctx do
      {:ok, _} =
        History.off(fn ->
          Repo.update_all(from(g in Group, where: g.id == ^ctx.group.id), set: [name: "x"])
          Repo.delete_all(from(v in Value, where: v.group_id == ^ctx.group.id))
        end)

      assert changes(ctx.group) == []
    end
  end
end
