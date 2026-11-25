defmodule PotokIde.Activity.SourcesTest do
  @moduledoc """
  The timeline past messages: what each source tells, to whom, and what it
  leaves out because it is told elsewhere or is not the profile's doing.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.ActivityFixtures
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{Accounts, Events, Notices, Repo, Social, Tags}
  alias PotokIde.Polls.PollBallot
  alias PotokIde.Processes.Engine

  alias PotokIde.Social.{
    Access,
    AppProcess,
    DrawnProcesses,
    GroupAccessChange,
    GroupMembership,
    GroupRequests,
    GroupRoleRequest
  }

  defp unique, do: System.unique_integer([:positive])

  setup do
    {account, me} = account_with_profile!("so#{unique()}")
    {owner_account, owner} = account_with_profile!("so#{unique()}")
    {other_account, other} = account_with_profile!("so#{unique()}")
    group = group_with_members!(owner, [me, other])
    # What the fixtures do themselves: joining a group a moment after it was
    # made. The tests of joining do it by hand.
    %{
      me: me,
      account: account,
      owner: owner,
      owner_account: owner_account,
      other: other,
      other_account: other_account,
      group: Social.get_group!(group.id)
    }
  end

  defp of(ctx, filter, opts \\ []), do: entries(ctx.me, ctx.account, [{:filter, filter} | opts])
  defp sources(ctx, filter), do: ctx |> of(filter) |> Enum.map(& &1.source)
  defp update!(struct, changes), do: struct |> Ecto.Changeset.change(changes) |> Repo.update!()

  describe "polls" do
    test "a vote with what was chosen, at the last change of it", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      vote!(ctx.me, ctx.account, poll, 1)

      assert [entry] = of(ctx, :votes)
      assert entry.source == :ballot
      assert entry.poll == %{id: poll.id, question: "Where do we go?", secret?: false}
      assert entry.choice == ["Mountains"]
      assert entry.group.id == ctx.group.id

      ballot = Repo.get_by!(PollBallot, poll_id: poll.id, profile_id: ctx.me.id)
      update!(ballot, inserted_at: at(1), changed_at: at(9))
      assert [%{at: moved}] = of(ctx, :votes)
      assert DateTime.compare(moved, at(9)) == :eq
      assert of(ctx, :votes, until: at(5)) == []
    end

    test "a secret one says only that one voted", ctx do
      poll = create_poll!(ctx.owner, ctx.group, %{"secret" => "true"})
      vote!(ctx.me, ctx.account, poll, 1)

      assert [%{source: :ballot, choice: nil, poll: %{secret?: true}}] = of(ctx, :votes)
    end

    test "the ones one started, but not one a request raised in one's name", ctx do
      mine = create_poll!(ctx.me, ctx.group)
      assert [%{source: :poll, poll: %{id: id}}] = of(ctx, :votes)
      assert id == mine.id

      update!(mine, from_request: true)
      assert of(ctx, :votes) == []
    end

    test "a holder who votes for themself through a shared profile sees only their own", ctx do
      share_profile!(ctx.me, ctx.other_account)
      poll = create_poll!(ctx.owner, ctx.group)
      [sea, mountains] = option_ids(poll)

      mine =
        Repo.insert!(%PollBallot{
          poll_id: poll.id,
          profile_id: ctx.me.id,
          account_id: ctx.account.id,
          by_holder: true,
          option_ids: [sea],
          inserted_at: at(1)
        })

      theirs =
        Repo.insert!(%PollBallot{
          poll_id: poll.id,
          profile_id: ctx.me.id,
          account_id: ctx.other_account.id,
          by_holder: true,
          option_ids: [mountains],
          inserted_at: at(2)
        })

      assert [%{id: id, choice: ["Sea"]}] = entries(ctx.me, ctx.account, filter: :votes)
      assert id == mine.id

      assert [%{id: id, choice: ["Mountains"]}] =
               entries(ctx.me, ctx.other_account, filter: :votes)

      assert id == theirs.id

      # With the account gone, nobody is the one who gave it.
      update!(theirs, account_id: nil)
      assert entries(ctx.me, ctx.other_account, filter: :votes) == []
      assert [%{choice: ["Sea"]}] = entries(ctx.me, ctx.account, filter: :votes)
    end

    test "a public poll stays with whoever is no member, one for members does not", ctx do
      group = group_with_members!(ctx.owner, [ctx.me], %{"is_public" => true})
      for_members = create_poll!(ctx.owner, group)
      public = create_poll!(ctx.owner, group, %{"is_public" => "true"})
      vote!(ctx.me, ctx.account, for_members)
      vote!(ctx.me, ctx.account, public)
      assert length(of(ctx, :votes)) == 2

      {:ok, _} = Social.leave_group(ctx.me, group)
      assert [%{poll: %{id: id}}] = of(ctx, :votes)
      assert id == public.id

      update!(Social.get_group!(group.id), is_public: false)
      assert of(ctx, :votes) == []
    end
  end

  describe "events" do
    test "one's answers, at the last one, and the events one made", ctx do
      event = create_event!(ctx.owner, ctx.group, event_attrs(Date.add(today(), 7)))
      date = Date.add(today(), 7)
      {:ok, response} = Events.respond(ctx.me, event, date, :going)
      update!(response, updated_at: at(4))

      assert [entry] = of(ctx, :events)
      assert entry.source == :rsvp
      assert {entry.status, entry.on, entry.event.title} == {:going, date, "Training"}
      assert DateTime.compare(entry.at, at(4)) == :eq

      made = create_event!(ctx.me, ctx.group, event_attrs(date, %{"title" => "Moj"}))
      assert [%{source: :event, event: %{id: id}}, %{source: :rsvp}] = of(ctx, :events)
      assert id == made.id

      {:ok, nil} = Events.respond(ctx.me, event, date, nil)
      assert sources(ctx, :events) == [:event]
    end

    test "those of a group one left, only when public", ctx do
      date = Date.add(today(), 7)
      private = create_event!(ctx.owner, ctx.group, event_attrs(date))
      public = create_event!(ctx.owner, ctx.group, event_attrs(date, %{"is_public" => "true"}))
      {:ok, _} = Events.respond(ctx.me, private, date, :going)
      {:ok, _} = Events.respond(ctx.me, public, date, :maybe)
      assert length(of(ctx, :events)) == 2

      {:ok, _} = Social.leave_group(ctx.me, ctx.group)
      assert [%{event: %{id: id}}] = of(ctx, :events)
      assert id == public.id
    end
  end

  describe "groups" do
    test "made ones, without threads, direct conversations and records", ctx do
      group = group_with_members!(ctx.me, [])
      value = message!(ctx.owner, ctx.group, at(1))
      {:ok, _} = Social.get_or_create_value_thread(ctx.me, ctx.group, value, %{"name" => "t"})
      {:ok, _} = Social.get_or_create_direct_group(ctx.me, ctx.other)
      record = group_with_members!(ctx.me, [])
      update!(record, external_key: "r-1")

      assert [%{source: :group_made, group: %{id: id}}] = of(ctx, :groups)
      assert id == group.id
    end

    test "joining, where one did: not as its maker and not through the group above", ctx do
      made_at = ~N[2026-03-01 10:00:00]
      joined_at = ~N[2026-03-02 10:00:00]
      update!(ctx.group, inserted_at: DateTime.from_naive!(made_at, "Etc/UTC"))

      membership =
        Repo.get_by!(GroupMembership, group_id: ctx.group.id, profile_id: ctx.me.id)

      Repo.update_all(
        Ecto.Query.where(
          GroupMembership,
          group_id: ^membership.group_id,
          profile_id: ^membership.profile_id
        ),
        set: [inserted_at: DateTime.from_naive!(joined_at, "Etc/UTC")]
      )

      below =
        group_with_members!(ctx.owner, [], %{:parent => ctx.group, "inherits_members" => true})

      assert Access.for_profile(ctx.me, below).member?
      # Long after the group was made, as someone who joins above it later.
      update!(below, inserted_at: DateTime.from_naive!(made_at, "Etc/UTC"))

      assert [%{source: :joined, group: %{id: id}, at: at}] = of(ctx, :groups)
      assert id == ctx.group.id
      assert DateTime.compare(at, DateTime.from_naive!(joined_at, "Etc/UTC")) == :eq
    end

    test "leaving a public one is told, leaving a private one is not", ctx do
      public = group_with_members!(ctx.owner, [ctx.me], %{"is_public" => true})
      {:ok, _} = Social.leave_group(ctx.me, public)
      {:ok, _} = Social.leave_group(ctx.me, ctx.group)
      assert Repo.aggregate(GroupAccessChange, :count) >= 2

      assert [%{source: :left, group: %{id: id}}] = of(ctx, :groups)
      assert id == public.id
    end

    test "being removed is not one's doing", ctx do
      public = group_with_members!(ctx.owner, [ctx.me], %{"is_public" => true})
      {:ok, _} = Social.remove_group_member(ctx.owner, public, ctx.me.id)
      assert of(ctx, :groups) == []
    end

    test "reactions to a group: one row, while one sees the group", ctx do
      group = group_with_members!(ctx.owner, [], %{"is_public" => true})
      {:ok, _} = Social.toggle_group_reaction(ctx.me, ctx.group, "❤️")
      {:ok, _} = Social.toggle_group_reaction(ctx.me, ctx.group, "👍")
      Repo.insert!(%Social.GroupReaction{group_id: group.id, profile_id: ctx.me.id, emoji: "🎉"})

      reactions = of(ctx, :given)
      assert Enum.map(reactions, & &1.source) == [:group_reaction, :group_reaction]
      assert Enum.find(reactions, &(&1.group.id == ctx.group.id)).emoji == ["❤️", "👍"]

      update!(group, is_public: false)
      assert [%{group: %{id: id}}] = of(ctx, :given)
      assert id == ctx.group.id
    end
  end

  describe "records" do
    test "one row for what went into a collection in a day, without what it holds", ctx do
      record!(ctx.me, ctx.group, at(0), %{data: %{"tajna" => "x"}})
      last = record!(ctx.me, ctx.group, at(5))
      record!(ctx.me, ctx.group, at(3), %{collection: "racuni"})
      record!(ctx.owner, ctx.group, at(9))

      assert [molbe, racuni] = of(ctx, :work)

      assert {molbe.source, molbe.id, molbe.collection, molbe.count} ==
               {:record, last.id, "molbe", 2}

      assert {racuni.collection, racuni.count} == {"racuni", 1}
      refute inspect(molbe) =~ "tajna"
      assert molbe.app == nil
    end

    test "by the days of the reader's zone", ctx do
      # 23:30 and 00:30 in Belgrade, the same day in UTC.
      record!(ctx.me, ctx.group, ~U[2026-03-02 22:30:00Z])
      record!(ctx.me, ctx.group, ~U[2026-03-02 23:30:00Z])

      assert [%{count: 2}] = of(ctx, :work, zone: "Etc/UTC")
      assert [first, second] = of(ctx, :work, zone: "Europe/Belgrade")
      assert {first.count, second.count} == {1, 1}
      assert first.key =~ "2026-03-03"
      assert second.key =~ "2026-03-02"
    end

    test "an import of many is one row and does not hide what came before it", ctx do
      now = at(60)

      rows =
        for n <- 1..2_000 do
          %{
            creator_id: ctx.me.id,
            group_id: ctx.group.id,
            is_data: true,
            data: %{"n" => n},
            content: "",
            collection: "uvoz",
            content_format: :markdown,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(Social.Value, rows)
      before = message!(ctx.me, ctx.group, at(1))

      assert [%{source: :record, count: 100}] = of(ctx, :work)

      assert ["record-" <> _rest, message] =
               keys(ctx.me, ctx.account, until: at(120), limit: 5)

      assert message == "message-#{before.id}"
    end

    test "what Potok keeps in collections of its own is no record", ctx do
      for collection <- ~w(config notify files),
          do: record!(ctx.me, ctx.group, at(1), %{collection: collection})

      assert of(ctx, :work) == []
    end

    test "those of an app one does not see any more are gone", ctx do
      {:ok, _} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, role} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "savet"})

      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Savetova",
          "description" => "<p>app</p>",
          "description_format" => :html,
          "uses_api" => true,
          "visible_role_keys" => [role.key]
        })

      record!(ctx.me, ctx.group, at(1), %{alt_description_id: alt.id})
      assert of(ctx, :work) == []

      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.me.id, role.key)
      assert [%{app: %{name: "Savetova"}}] = of(ctx, :work)
    end

    test "of someone outside: a public group's, in a collection", ctx do
      public = group_with_members!(ctx.owner, [], %{"is_public" => true})
      record!(ctx.me, public, at(1))
      record!(ctx.me, public, at(2), %{collection: nil})
      private = group_with_members!(ctx.owner, [])
      record!(ctx.me, private, at(3))

      assert [%{collection: "molbe", group: %{id: id}}] = of(ctx, :work)
      assert id == public.id
    end
  end

  describe "processes" do
    defp graph do
      %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{
            "id" => "odluka",
            "type" => "userTask",
            "label" => "Savet odlučuje",
            "role" => "everyone",
            "outcomes" => ["odobri", "odbij"]
          },
          %{"id" => "kraj", "type" => "endEvent", "label" => "Gotovo"}
        ],
        "flows" => [
          %{"from" => "start", "to" => "odluka"},
          %{"from" => "odluka", "to" => "kraj", "outcome" => "odobri"},
          %{"from" => "odluka", "to" => "kraj", "outcome" => "odbij"}
        ]
      }
    end

    defp process!(ctx) do
      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "Molbe",
          "graph" => graph(),
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)
      process
    end

    defp start!(profile, ctx, process) do
      {:ok, run} =
        DrawnProcesses.start(profile, ctx.group, process.id, %{"title" => "T", "text" => "t"})

      Engine.run(run.id)
      run.id
    end

    test "a run started by hand and a decision, and nothing else of the trace", ctx do
      process = process!(ctx)
      mine = start!(ctx.me, ctx, process)
      {:ok, _} = Engine.complete_task(ctx.other, mine, "odluka", "odobri", "može")
      Engine.run(mine)
      theirs = start!(ctx.other, ctx, process)
      {:ok, _} = Engine.complete_task(ctx.me, theirs, "odluka", "odbij", nil)
      Engine.run(theirs)

      assert [answer, started] = of(ctx, :work)

      assert {answer.source, answer.process, answer.label, answer.outcome} ==
               {:run_answer, "Molbe", "Savet odlučuje", "odbij"}

      assert {started.source, started.process} == {:run_start, "Molbe"}

      # The run's other steps are told in the group, not as one's own doing.
      {:ok, _} = Social.leave_group(ctx.me, ctx.group)
      assert of(ctx, :work) == []
    end

    test "a run that one's message started is not one's doing", ctx do
      process = process!(ctx)
      start!(ctx.me, ctx, process)
      assert sources(ctx, :work) == [:run_start]

      # The same trace, of a process that starts by itself.
      Repo.update_all(Ecto.Query.where(AppProcess, id: ^process.id), set: [trigger: "message"])
      assert of(ctx, :work) == []
    end
  end

  describe "requests" do
    setup ctx do
      group = group_with_members!(ctx.me, [], %{"is_public" => true})
      {:ok, _} = Social.create_own_group_manifest(ctx.me, group)
      {:ok, role} = Social.create_group_role(ctx.me, group, %{"name" => "komsija"})

      {:ok, role} =
        Social.set_role_request_rule(ctx.me, group, role.key, %{"request_mode" => "approve"})

      %{open: Social.get_group!(group.id), role: role}
    end

    test "an admission is told once, and a refusal", ctx do
      {:ok, request} = GroupRequests.request_access(ctx.other, ctx.open, %{})

      {:ok, _} =
        GroupRequests.decide(ctx.me, ctx.open, {:join, request.id}, %{"admission" => "admit"})

      assert [%{source: :admission, person: %{id: id}}] = of(ctx, :work)
      assert id == ctx.other.id

      {:ok, request} = GroupRequests.request_access(ctx.owner, ctx.open, %{})

      {:ok, _} =
        GroupRequests.decide(ctx.me, ctx.open, {:join, request.id}, %{
          "admission" => "refuse",
          "reason" => "zasad"
        })

      refusal = Enum.find(of(ctx, :work), &(&1.source == :decision))
      assert {refusal.decision, refusal.role_key} == {:declined, nil}
      assert refusal.person.id == ctx.owner.id
      assert Enum.count(of(ctx, :work)) == 2
    end

    test "a role given to a member, with its name as it is now", ctx do
      add_member!(ctx.me, ctx.open, ctx.other)

      {:ok, _} =
        GroupRequests.request_roles(ctx.other, ctx.open, %{"role_keys" => [ctx.role.key]})

      request = Repo.get_by!(GroupRoleRequest, group_id: ctx.open.id, profile_id: ctx.other.id)

      {:ok, _} =
        GroupRequests.decide(ctx.me, ctx.open, {:roles, request.id}, %{
          "roles" => %{ctx.role.key => "grant"}
        })

      assert [entry] = of(ctx, :work)
      assert {entry.source, entry.decision, entry.role.name} == {:decision, :granted, "komsija"}

      {:ok, _} = Social.delete_group_role(ctx.me, ctx.open, ctx.role.key)
      assert [%{role: nil, role_key: key}] = of(ctx, :work)
      assert key == ctx.role.key
    end
  end

  describe "notices, follows and tags" do
    test "what one sent and whom one follows, while one sees the group", ctx do
      group = group_with_members!(ctx.me, [], %{"is_public" => true})

      {:ok, notice} =
        Notices.send_notice(ctx.me, group, Access.for_profile(ctx.me, group), %{
          "body" => "**Voda** se vraća u 18"
        })

      followed = group_with_members!(ctx.owner, [], %{"is_public" => true})
      {:ok, _} = Notices.follow(ctx.me, followed)

      assert Enum.sort(sources(ctx, :notices)) == [:follow, :notice]
      entry = Enum.find(of(ctx, :notices), &(&1.source == :notice))
      assert entry.notice == %{id: notice.id, text: "Voda se vraća u 18"}

      update!(followed, is_public: false)
      assert sources(ctx, :notices) == [:notice]
    end

    test "tags: one row for a thing with all one put on it, public and private", ctx do
      message = message!(ctx.owner, ctx.group, at(1), %{content: "Zapisnik"})
      {:ok, _} = Tags.add_tag(ctx.me, :value, message.id, "vazno", :private)
      {:ok, _} = Tags.add_tag(ctx.me, :value, message.id, "zapisnici", :private)
      {:ok, _} = Tags.add_tag(ctx.me, :group, ctx.group.id, "moje", :private)
      {:ok, _} = Tags.add_tag(ctx.other, :value, message.id, "tudja", :private)

      entries = of(ctx, :notices)
      assert Enum.all?(entries, &(&1.source == :tag))
      assert length(entries) == 2

      entry = Enum.find(entries, &(&1.key == "tag-value-#{message.id}"))
      assert Enum.map(entry.tags, & &1.name) == ["vazno", "zapisnici"]
      assert {:value, %{text: "Zapisnik"}} = entry.target

      {:ok, _} = Social.leave_group(ctx.me, ctx.group)
      assert of(ctx, :notices) == []
    end

    test "a tag on someone one no longer finds is gone", ctx do
      {_, hidden} = account_with_profile!("so#{unique()}")
      update!(hidden, discovery: :everyone)
      {:ok, _} = Tags.add_tag(ctx.me, :profile, hidden.id, "majstor", :private)
      assert [%{target: {:profile, %{id: id}}, group: nil}] = of(ctx, :notices)
      assert id == hidden.id

      update!(hidden, discovery: :shared_groups)
      assert of(ctx, :notices) == []
    end
  end

  describe "everything" do
    test "each filter is a part of it, and files are told as messages", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      vote!(ctx.me, ctx.account, poll)
      file!(message!(ctx.me, ctx.group, at(1)))
      record!(ctx.me, ctx.group, at(2))
      {:ok, _} = Notices.follow(ctx.me, ctx.group)
      group_with_members!(ctx.me, [])

      all = keys(ctx.me, ctx.account, limit: 200)

      parts =
        for filter <- PotokIde.Activity.filters(), filter not in [:all, :files] do
          keys(ctx.me, ctx.account, filter: filter, limit: 200)
        end

      assert Enum.sort(all) == parts |> List.flatten() |> Enum.sort()
      assert all == Enum.uniq(all)
      assert [file] = keys(ctx.me, ctx.account, filter: :files)
      assert file in all

      for limit <- [1, 2, 4],
          do: assert(all_keys(ctx.me, ctx.account, limit: limit) == all)
    end

    test "a deleted account leaves others' timelines with a person without a name", ctx do
      message = message!(ctx.other, ctx.group, at(1))
      reaction!(ctx.me, message, at(2))
      {:ok, _} = Accounts.delete_account(ctx.other_account)

      assert [%{value: %{author: author}}] = of(ctx, :given)
      assert author.kind == :deleted
    end
  end
end
