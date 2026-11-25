defmodule PotokIde.Social.ScheduledValuesTest do
  @moduledoc """
  Messages that go out later: who may schedule one, what waits and to whom it
  shows, that it goes out once and as an ordinary message, what happens when
  it cannot, and what goes with a membership, a group and an account.
  """

  use PotokIde.DataCase

  import ExUnit.CaptureLog
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts.Deletion
  alias PotokIde.Processes.ValueProcess
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    DrawnProcesses,
    GroupMembership,
    Profile,
    ScheduledValue,
    ScheduledValues,
    Value,
    ValueAttachment
  }

  alias PotokIde.Storage

  @zone "Europe/Belgrade"

  setup do
    {author_account, author} = account_with_profile!("sv-author")
    {reader_account, reader} = account_with_profile!("sv-reader")
    group = group_with_members!(author, [reader], %{"name" => "sv-group"})
    {:ok, _manifest} = Social.create_own_group_manifest(author, group)

    %{
      author_account: author_account,
      author: author,
      reader_account: reader_account,
      reader: reader,
      group: Social.get_group!(group.id)
    }
  end

  defp in_minutes(minutes), do: DateTime.add(DateTime.utc_now(:second), minutes, :minute)

  defp schedule!(profile, group, content, opts \\ []) do
    attrs = Map.merge(%{"content" => content}, Map.new(opts[:attrs] || %{}))

    {:ok, scheduled} =
      ScheduledValues.schedule(
        profile,
        group,
        attrs,
        opts[:files] || [],
        opts[:at] || in_minutes(10)
      )

    scheduled
  end

  # A file in storage, as the composer hands it over.
  defp file!(group, name) do
    key = Storage.new_key(group.id)
    path = Path.join(System.tmp_dir!(), "sv-#{System.unique_integer([:positive])}")
    File.write!(path, "content")
    :ok = Storage.put_file(key, path)
    File.rm(path)
    %{storage_key: key, filename: name, content_type: "text/plain", byte_size: 7}
  end

  defp run_after(scheduled, seconds),
    do: ScheduledValues.run_due(DateTime.add(scheduled.send_at, seconds, :second))

  defp contents(group), do: group |> Social.list_group_values() |> Enum.map(& &1.content)

  defp waiting?(scheduled), do: Repo.get(ScheduledValue, scheduled.id) != nil

  defp deny!(ctx, permission) do
    {:ok, _role} =
      Social.set_group_role_permission(ctx.author, ctx.group, "everyone", permission, :neutral)
  end

  defp stored?(file), do: match?({:ok, _size}, Storage.stat(file.storage_key))

  describe "schedule/5" do
    test "keeps the message out of the chat until its time", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "later")

      assert contents(ctx.group) == []
      assert [%ScheduledValue{content: "later"}] = ScheduledValues.list(ctx.author, ctx.group)
      assert ScheduledValues.list(ctx.reader, ctx.group) == []
      assert ScheduledValues.next_at() == scheduled.send_at
    end

    test "takes only a time still to come, up to a year ahead", ctx do
      schedule = &ScheduledValues.schedule(ctx.author, ctx.group, %{"content" => "x"}, [], &1)

      assert {:error, :past} = schedule.(DateTime.utc_now(:second))
      assert {:error, :past} = schedule.(in_minutes(-1))
      assert {:error, :too_far} = schedule.(in_minutes(60 * 24 * 368))
      assert {:ok, _scheduled} = schedule.(in_minutes(60 * 24 * 365))
    end

    test "needs text or a file", ctx do
      schedule =
        &ScheduledValues.schedule(ctx.author, ctx.group, %{"content" => &1}, &2, in_minutes(5))

      assert {:error, %Ecto.Changeset{}} = schedule.("", [])
      assert {:error, %Ecto.Changeset{}} = schedule.("  \n", [])
      assert {:ok, %ScheduledValue{content: ""}} = schedule.("", [file!(ctx.group, "a.txt")])
    end

    test "is for members who may post, and files for those who may send them", ctx do
      {_account, stranger} = account_with_profile!("sv-stranger")

      schedule =
        &ScheduledValues.schedule(&1, ctx.group, %{"content" => "x"}, &2, in_minutes(5))

      assert {:error, :not_permitted} = schedule.(stranger, [])

      deny!(ctx, :attach_files)
      assert {:error, :not_permitted} = schedule.(ctx.reader, [file!(ctx.group, "a.txt")])
      assert {:ok, _scheduled} = schedule.(ctx.reader, [])

      deny!(ctx, :post_values)
      assert {:error, :not_permitted} = schedule.(ctx.reader, [])
    end

    test "someone outside the group may not, though its chat is open", ctx do
      {_account, stranger} = account_with_profile!("sv-outsider")

      {:ok, group} =
        Social.update_group(ctx.author, ctx.group, %{
          "is_public" => true,
          "has_public_chat" => true
        })

      assert {:ok, _value} = Social.create_value(stranger, group, %{"content" => "hello"})

      assert {:error, :not_permitted} =
               ScheduledValues.schedule(stranger, group, %{"content" => "x"}, [], in_minutes(5))
    end

    test "answers only a message of the group", ctx do
      {:ok, value} = Social.create_value(ctx.reader, ctx.group, %{"content" => "question"})
      other = group_with_members!(ctx.author, [])
      {:ok, elsewhere} = Social.create_value(ctx.author, other, %{"content" => "elsewhere"})

      schedule = fn parent_id ->
        ScheduledValues.schedule(
          ctx.author,
          ctx.group,
          %{"content" => "x", "parent_id" => parent_id},
          [],
          in_minutes(5)
        )
      end

      assert {:ok, %ScheduledValue{}} = schedule.(value.id)
      assert {:error, :invalid_parent} = schedule.(elsewhere.id)
    end

    test "a profile has at most so many waiting", ctx do
      now = DateTime.utc_now(:second)

      rows =
        for _ <- 1..ScheduledValues.max_waiting() do
          %{
            group_id: ctx.group.id,
            profile_id: ctx.author.id,
            content: "x",
            send_at: in_minutes(60),
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(ScheduledValue, rows)

      assert {:error, :too_many_scheduled} =
               ScheduledValues.schedule(
                 ctx.author,
                 ctx.group,
                 %{"content" => "x"},
                 [],
                 in_minutes(5)
               )
    end
  end

  describe "run_due/1" do
    test "sends what is due, once, and leaves the rest", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "due")
      later = schedule!(ctx.author, ctx.group, "later", at: in_minutes(20))

      assert run_after(scheduled, -1) == 0
      assert run_after(scheduled, 0) == 1
      assert run_after(scheduled, 1) == 0

      assert contents(ctx.group) == ["due"]
      refute waiting?(scheduled)
      assert waiting?(later)

      [value] = Social.list_group_values(ctx.group)
      assert value.creator_id == ctx.author.id
      assert value.content_format == :markdown
    end

    test "sends those of one minute in the order they were written", ctx do
      at = in_minutes(10)
      for text <- ~w(one two three), do: schedule!(ctx.author, ctx.group, text, at: at)

      assert ScheduledValues.run_due(at) == 3
      assert contents(ctx.group) == ~w(one two three)
    end

    test "goes out as any message: a quote, mentions, pushes and the files", ctx do
      capture_push_requests!()
      device = push_device!(ctx.reader_account)
      own_device = push_device!(ctx.author_account)
      {:ok, question} = Social.create_value(ctx.reader, ctx.group, %{"content" => "question"})
      _ = pushed_endpoints()
      file = file!(ctx.group, "plan.txt")

      scheduled =
        schedule!(ctx.author, ctx.group, "answer for @sv-reader",
          attrs: %{"parent_id" => question.id},
          files: [file]
        )

      assert pushed_endpoints() == []
      assert run_after(scheduled, 0) == 1

      value = ctx.group |> Social.list_group_values() |> List.last()
      assert value.parent_id == question.id
      assert value.mentioned_profile_ids == [ctx.reader.id]

      assert [%ValueAttachment{filename: "plan.txt", byte_size: 7} = attachment] =
               value.attachments

      assert attachment.storage_key == file.storage_key
      assert stored?(file)

      assert device in pushed_endpoints()
      refute own_device in pushed_endpoints()
    end

    test "starts the processes drawn on its words", ctx do
      {:ok, row} =
        DrawnProcesses.create(ctx.author, ctx.group, %{
          "trigger" => "message",
          "trigger_config" => %{"words" => "kvar"},
          "name" => "Na poruku",
          "graph" => %{
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              %{"id" => "da", "type" => "userTask", "role" => "admin", "outcomes" => ["Da"]},
              %{"id" => "kraj", "type" => "endEvent"}
            ],
            "flows" => [
              %{"from" => "start", "to" => "da"},
              %{"from" => "da", "to" => "kraj", "outcome" => "Da"}
            ]
          }
        })

      {:ok, _row} = DrawnProcesses.activate(ctx.author, ctx.group, row.id)
      scheduled = schedule!(ctx.reader, ctx.group, "Kvar na liftu")
      assert Repo.aggregate(ValueProcess, :count) == 0

      assert run_after(scheduled, 0) == 1
      assert Repo.aggregate(ValueProcess, :count) == 1
    end

    test "tells the author's pages before the message itself", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "due")
      Social.subscribe_profile(ctx.author)
      Social.subscribe_group(ctx.group)

      run_after(scheduled, 0)

      profile_id = ctx.author.id
      group_id = ctx.group.id
      {:messages, messages} = Process.info(self(), :messages)

      kinds =
        for message <- messages,
            elem(message, 0) in [:scheduled_values_changed, :value_created],
            do: elem(message, 0)

      assert kinds == [:scheduled_values_changed, :value_created]
      assert_receive {:value_created, ^group_id, %Value{id: value_id}}
      assert_receive {:scheduled_values_changed, ^profile_id, ^group_id, ^value_id}
    end

    test "late by an hour it still goes out, past that it waits for its author", ctx do
      capture_push_requests!()
      device = push_device!(ctx.author_account)
      {:ok, _question} = Social.create_value(ctx.reader, ctx.group, %{"content" => "q"})
      _ = pushed_endpoints()

      on_time = schedule!(ctx.author, ctx.group, "still")
      assert run_after(on_time, 59 * 60) == 1

      late = schedule!(ctx.author, ctx.group, "too late")
      assert run_after(late, 61 * 60) == 0

      assert contents(ctx.group) == ["q", "still"]
      assert Repo.get!(ScheduledValue, late.id).failure == :late
      assert pushed_endpoints() == [device]
      assert ScheduledValues.next_at() == nil

      # It is not tried again.
      assert run_after(late, 62 * 60) == 0
      assert pushed_endpoints() == []
    end

    test "without the right to post any more it waits for its author", ctx do
      scheduled = schedule!(ctx.reader, ctx.group, "x")
      deny!(ctx, :post_values)

      assert run_after(scheduled, 0) == 0
      assert Repo.get!(ScheduledValue, scheduled.id).failure == :not_permitted
      assert contents(ctx.group) == []
    end

    test "without the right to send files any more it waits with its files", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.reader, ctx.group, "x", files: [file])
      deny!(ctx, :attach_files)

      assert run_after(scheduled, 0) == 0
      assert Repo.get!(ScheduledValue, scheduled.id).failure == :not_permitted
      assert stored?(file)
    end

    test "one that cannot be written does not hold the next one back", ctx do
      broken = schedule!(ctx.author, ctx.group, "broken", files: [file!(ctx.group, "a.txt")])

      # A file another message already holds: the write itself is refused.
      {:ok, _value} =
        Social.create_value(
          ctx.author,
          ctx.group,
          %{"content" => "holds it"},
          ScheduledValue.attachments(broken)
        )

      next = schedule!(ctx.author, ctx.group, "next", at: broken.send_at)

      log = capture_log(fn -> assert run_after(next, 0) == 1 end)

      assert log =~ "Scheduled message #{broken.id} was refused"
      refute log =~ "broken"
      assert Repo.get!(ScheduledValue, broken.id).failure == :error
      assert contents(ctx.group) == ["holds it", "next"]
    end

    test "a crash while it is sent is the same, and the log keeps its text to itself", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "private words")

      # A key no column takes.
      file = %{
        "storage_key" => %{},
        "filename" => "a.txt",
        "content_type" => "text/plain",
        "byte_size" => 1
      }

      Repo.update_all(from(s in ScheduledValue, where: s.id == ^scheduled.id),
        set: [files: [file]]
      )

      log = capture_log(fn -> assert run_after(scheduled, 0) == 0 end)

      assert log =~ "Scheduled message #{scheduled.id} failed: Ecto."
      refute log =~ "private words"
      assert Repo.get!(ScheduledValue, scheduled.id).failure == :error
      assert contents(ctx.group) == []
    end

    test "goes out without the quote when the message it answers is deleted", ctx do
      {:ok, question} = Social.create_value(ctx.reader, ctx.group, %{"content" => "question"})
      scheduled = schedule!(ctx.author, ctx.group, "answer", attrs: %{"parent_id" => question.id})
      {:ok, _value} = Social.delete_value(ctx.reader, question)

      assert run_after(scheduled, 0) == 1
      assert [%Value{content: "answer", parent_id: nil}] = Social.list_group_values(ctx.group)
    end

    test "reaches no one whose other side deleted their account", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reader)
      scheduled = schedule!(ctx.author, direct, "hello")

      Repo.update_all(from(p in Profile, where: p.id == ^ctx.reader.id), set: [kind: :deleted])

      assert run_after(scheduled, 0) == 0
      assert Repo.get!(ScheduledValue, scheduled.id).failure == :not_permitted

      assert {:error, :not_permitted} =
               ScheduledValues.schedule(
                 ctx.author,
                 direct,
                 %{"content" => "x"},
                 [],
                 in_minutes(5)
               )

      assert {:error, :not_permitted} =
               ScheduledValues.send_now(ctx.author, direct, scheduled.id)
    end

    test "works in a thread", ctx do
      {:ok, value} = Social.create_value(ctx.author, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.author, ctx.group, value, %{"name" => "nit"})

      :ok = Social.join_thread(ctx.reader, thread)
      scheduled = schedule!(ctx.reader, thread, "in the thread")

      assert run_after(scheduled, 0) == 1
      assert contents(thread) == ["in the thread"]
    end
  end

  describe "the author's read marker" do
    test "moves with the message when nothing else is unread", ctx do
      {:ok, _value} = Social.create_value(ctx.author, ctx.group, %{"content" => "mine"})
      scheduled = schedule!(ctx.author, ctx.group, "later")

      assert run_after(scheduled, 0) == 1
      assert Social.count_root_group_unread_values(ctx.author) == 0
      assert Social.count_root_group_unread_values(ctx.reader) == 2
    end

    test "stays before what others wrote and the author has not read", ctx do
      {:ok, _value} = Social.create_value(ctx.author, ctx.group, %{"content" => "mine"})
      scheduled = schedule!(ctx.author, ctx.group, "later")
      {:ok, unread} = Social.create_value(ctx.reader, ctx.group, %{"content" => "unread"})

      assert run_after(scheduled, 0) == 1

      # The message itself counts along with what was not read.
      assert %{value_id: value_id, count: 2} = Social.unread_start(ctx.author, ctx.group)
      assert value_id == unread.id
    end

    test "moves when the author sends it themselves", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "now")
      {:ok, _unread} = Social.create_value(ctx.reader, ctx.group, %{"content" => "unread"})

      assert {:ok, _value} = ScheduledValues.send_now(ctx.author, ctx.group, scheduled.id)
      assert Social.count_root_group_unread_values(ctx.author) == 0
    end
  end

  describe "update/5" do
    test "changes the text and the time", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "first")

      local =
        in_minutes(120) |> DateTime.shift_zone!(@zone) |> Calendar.strftime("%Y-%m-%dT%H:%M")

      assert {:ok, updated} =
               ScheduledValues.update(
                 ctx.author,
                 ctx.group,
                 scheduled.id,
                 %{"content" => "second", "send_local" => local},
                 @zone
               )

      assert updated.content == "second"

      assert updated.send_at |> DateTime.shift_zone!(@zone) |> Calendar.strftime("%Y-%m-%dT%H:%M") ==
               local
    end

    test "one that failed needs a new time, and then waits again", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "x")
      run_after(scheduled, 61 * 60)

      Repo.update_all(from(s in ScheduledValue, where: s.id == ^scheduled.id),
        set: [send_at: in_minutes(-90)]
      )

      update = &ScheduledValues.update(ctx.author, ctx.group, scheduled.id, &1, @zone)

      assert {:error, %Ecto.Changeset{} = changeset} = update.(%{"content" => "y"})
      assert "must be in the future" in errors_on(changeset).send_local

      local = in_minutes(30) |> DateTime.shift_zone!(@zone) |> Calendar.strftime("%Y-%m-%dT%H:%M")
      assert {:ok, %ScheduledValue{failure: nil}} = update.(%{"send_local" => local})
      assert ScheduledValues.next_at() != nil
    end

    test "one that is all files may lose its text, others may not", ctx do
      update = fn scheduled ->
        ScheduledValues.update(ctx.author, ctx.group, scheduled.id, %{"content" => ""}, @zone)
      end

      files = schedule!(ctx.author, ctx.group, "x", files: [file!(ctx.group, "a.txt")])
      assert {:ok, %ScheduledValue{content: ""}} = update.(files)
      assert {:error, %Ecto.Changeset{}} = update.(schedule!(ctx.author, ctx.group, "x"))
    end
  end

  describe "cancel/3 and send_now/3" do
    test "cancelling deletes the files too", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.author, ctx.group, "x", files: [file])

      assert :ok = ScheduledValues.cancel(ctx.author, ctx.group, scheduled.id)
      refute waiting?(scheduled)
      refute stored?(file)
      assert {:error, :not_found} = ScheduledValues.cancel(ctx.author, ctx.group, scheduled.id)
    end

    test "sending now posts it at once, also one that failed", ctx do
      scheduled = schedule!(ctx.author, ctx.group, "x")
      run_after(scheduled, 61 * 60)

      assert {:ok, %Value{content: "x"}} =
               ScheduledValues.send_now(ctx.author, ctx.group, scheduled.id)

      refute waiting?(scheduled)
      assert contents(ctx.group) == ["x"]
      assert {:error, :not_found} = ScheduledValues.send_now(ctx.author, ctx.group, scheduled.id)
    end

    test "sending now is refused without the right to post, and it stays", ctx do
      scheduled = schedule!(ctx.reader, ctx.group, "x")
      deny!(ctx, :post_values)

      assert {:error, :not_permitted} =
               ScheduledValues.send_now(ctx.reader, ctx.group, scheduled.id)

      assert waiting?(scheduled)
    end

    test "nobody else can touch it, an admin neither", ctx do
      scheduled = schedule!(ctx.reader, ctx.group, "x")
      other = group_with_members!(ctx.reader, [])

      for {profile, group} <- [{ctx.author, ctx.group}, {ctx.reader, other}] do
        assert {:error, :not_found} = ScheduledValues.cancel(profile, group, scheduled.id)
        assert {:error, :not_found} = ScheduledValues.send_now(profile, group, scheduled.id)

        assert {:error, :not_found} =
                 ScheduledValues.update(profile, group, scheduled.id, %{"content" => "y"}, @zone)
      end

      assert waiting?(scheduled)
    end
  end

  describe "what goes with a membership, a group and an account" do
    test "leaving the group takes its messages and their files", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.reader, ctx.group, "x", files: [file])
      {:ok, _} = Social.leave_group(ctx.reader, ctx.group)

      refute waiting?(scheduled)
      refute stored?(file)
    end

    test "being removed takes them too, and leaves those of others", ctx do
      scheduled = schedule!(ctx.reader, ctx.group, "x")
      own = schedule!(ctx.author, ctx.group, "y")
      {:ok, _} = Social.remove_group_member(ctx.author, ctx.group, ctx.reader)

      refute waiting?(scheduled)
      assert waiting?(own)
    end

    test "a membership gone another way takes them when their time comes", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.reader, ctx.group, "x", files: [file])

      Repo.delete_all(
        from(m in GroupMembership,
          where: m.group_id == ^ctx.group.id and m.profile_id == ^ctx.reader.id
        )
      )

      assert run_after(scheduled, 0) == 0
      refute waiting?(scheduled)
      refute stored?(file)
      assert contents(ctx.group) == []
    end

    test "a deleted group takes the files that wait", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.author, ctx.group, "x", files: [file])
      {:ok, _group} = Social.delete_group(ctx.author, ctx.group)

      refute waiting?(scheduled)
      refute stored?(file)
    end

    test "a deleted account takes what it had waiting", ctx do
      file = file!(ctx.group, "a.txt")
      scheduled = schedule!(ctx.reader, ctx.group, "x", files: [file])
      other = schedule!(ctx.author, ctx.group, "y")

      assert {:ok, _deleted} = Deletion.delete(ctx.reader_account)

      refute waiting?(scheduled)
      refute stored?(file)
      assert waiting?(other)
    end

    test "a shared profile keeps what one of its accounts scheduled", ctx do
      {second_account, _profile} = account_with_profile!("sv-second")

      Repo.insert!(%PotokIde.Social.AccountProfile{
        account_id: second_account.id,
        profile_id: ctx.reader.id
      })

      scheduled = schedule!(ctx.reader, ctx.group, "from the family")
      assert {:ok, _deleted} = Deletion.delete(ctx.reader_account)

      assert waiting?(scheduled)
      assert run_after(scheduled, 0) == 1
      assert contents(ctx.group) == ["from the family"]
    end
  end
end
