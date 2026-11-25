defmodule PotokIde.Activity.PageTest do
  @moduledoc """
  The timeline of a profile a page at a time: its order, what a row says, and
  that nothing is told twice or lost between pages.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.ActivityFixtures
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{Activity, Social}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {account, me} = account_with_profile!("ap#{unique()}")
    {_, ana} = account_with_profile!("ana#{unique()}")
    {_, marko} = account_with_profile!("marko#{unique()}")
    group = group_with_members!(ana, [me, marko])

    %{me: me, account: account, ana: ana, marko: marko, group: group}
  end

  describe "a row" do
    test "a message says where it is and how it starts", ctx do
      message = message!(ctx.me, ctx.group, at(1), %{content: "**Sastanak** je u četvrtak"})

      assert [entry] = entries(ctx.me, ctx.account, filter: :messages)
      assert entry.key == "message-#{message.id}"
      assert entry.source == :message
      assert entry.group.id == ctx.group.id
      assert entry.value.text == "Sastanak je u četvrtak"
      assert entry.value.mine?
      assert DateTime.compare(entry.at, at(1)) == :eq
    end

    test "one with only files is told by their names, and alone by its filter", ctx do
      plain = message!(ctx.me, ctx.group, at(1))
      with_file = message!(ctx.me, ctx.group, at(2), %{content: ""})
      file!(with_file, "zapisnik.pdf")
      file!(with_file, "slika.png")

      assert [entry] = entries(ctx.me, ctx.account, filter: :files)
      assert entry.key == "message-#{with_file.id}"
      assert entry.value.text == "📎 zapisnik.pdf +1"

      assert keys(ctx.me, ctx.account, filter: :messages) ==
               ["message-#{with_file.id}", "message-#{plain.id}"]

      assert Enum.count(keys(ctx.me, ctx.account), &(&1 == "message-#{with_file.id}")) == 1
    end

    test "a message longer than what is read is cut without a broken tag", ctx do
      html =
        "<p>Zdravo</p>" <> "<img src=\"data:image/png;base64,#{String.duplicate("A", 9_000)}\">"

      message!(ctx.me, ctx.group, at(1), %{content: html, content_format: :html})

      assert [%{value: %{text: "Zdravo"}}] = entries(ctx.me, ctx.account, filter: :messages)
    end

    test "the reactions of others: one row for a message, at the newest", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      later = message!(ctx.me, ctx.group, at(2))
      reaction!(ctx.ana, message, at(3), "❤️")
      reaction!(ctx.marko, later, at(4))
      reaction!(ctx.marko, message, at(5), "❤️")
      reaction!(ctx.marko, message, at(6), "👍")
      # One's own does not count among them.
      reaction!(ctx.me, message, at(7), "🎉")

      assert [first, second] = entries(ctx.me, ctx.account, filter: :received)
      assert first.key == "received-#{message.id}"
      assert DateTime.compare(first.at, at(6)) == :eq
      assert first.reactions == [{"❤️", 2}, {"👍", 1}]
      assert first.people == [ctx.marko.username, ctx.ana.username]
      assert first.people_count == 2
      assert second.key == "received-#{later.id}"
    end

    test "names the last three who reacted and counts the rest", ctx do
      message = message!(ctx.me, ctx.group, at(1))

      names =
        for n <- 1..5 do
          {_, profile} = account_with_profile!("r#{n}x#{unique()}")
          reaction!(profile, message, at(1 + n))
          profile.username
        end

      assert [entry] = entries(ctx.me, ctx.account, filter: :received)
      assert entry.people == names |> Enum.reverse() |> Enum.take(3)
      assert entry.people_count == 5
    end

    test "one's own reactions: one row for a message, with all the emoji", ctx do
      message = message!(ctx.ana, ctx.group, at(1), %{content: "Evo zapisnika"})
      reaction!(ctx.me, message, at(2), "❤️")
      reaction!(ctx.me, message, at(3), "👍")

      assert [entry] = entries(ctx.me, ctx.account, filter: :given)
      assert entry.emoji == ["❤️", "👍"]
      assert entry.value.author.id == ctx.ana.id
      refute entry.value.mine?
      assert entry.value.text == "Evo zapisnika"
      assert DateTime.compare(entry.at, at(3)) == :eq
    end

    test "an event and a poll are not told as the messages that announce them", ctx do
      create_event!(ctx.me, ctx.group, event_attrs(Date.add(today(), 7)), announce: true)
      create_poll!(ctx.me, ctx.group, %{}, announce: true)
      assert length(Social.list_group_values(ctx.group)) == 2

      assert entries(ctx.me, ctx.account, filter: :messages) == []
    end

    test "a direct conversation comes with who is on the other side", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.me, ctx.ana)
      message!(ctx.me, direct, at(1))

      assert [%{group: %{members: members}}] = entries(ctx.me, ctx.account, filter: :messages)
      assert ctx.ana.id in Enum.map(members, & &1.id)
    end
  end

  describe "pages" do
    test "every row once, whatever the page, with many at one second", ctx do
      theirs = message!(ctx.ana, ctx.group, at(0))

      for n <- 1..7 do
        # Four to a second: two messages, a reaction received and one given.
        own = message!(ctx.me, ctx.group, at(n))
        message!(ctx.me, ctx.group, at(n))
        reaction!(ctx.ana, own, at(n))
        given = message!(ctx.marko, ctx.group, at(0))
        reaction!(ctx.me, given, at(n))
      end

      reaction!(ctx.me, theirs, at(3))

      whole = all_keys(ctx.me, ctx.account, limit: 200)
      assert length(Enum.uniq(whole)) == length(whole)
      assert Enum.count(whole, &String.starts_with?(&1, "message-")) == 14
      assert Enum.count(whole, &String.starts_with?(&1, "given-")) == 8
      assert Enum.count(whole, &String.starts_with?(&1, "received-")) == 7

      for limit <- [1, 2, 3, 5, 7] do
        assert all_keys(ctx.me, ctx.account, limit: limit) == whole
      end
    end

    test "the newest first, over groups", ctx do
      other = group_with_members!(ctx.me, [ctx.ana])
      first = message!(ctx.me, ctx.group, at(1))
      second = message!(ctx.me, other, at(2))
      # Written later, of an earlier time, as an import may be.
      third = message!(ctx.me, ctx.group, at(0))

      assert keys(ctx.me, ctx.account, filter: :messages) ==
               Enum.map([second, first, third], &"message-#{&1.id}")
    end

    test "a full page with nothing after it has no next one", ctx do
      for n <- 1..3, do: message!(ctx.me, ctx.group, at(n))

      assert {:ok, %{entries: [_, _, _], cursor: nil}} =
               Activity.page(ctx.me, ctx.account, filter: :messages, limit: 3)

      assert {:ok, %{entries: [_, _], cursor: %{}}} =
               Activity.page(ctx.me, ctx.account, filter: :messages, limit: 2)
    end

    test "up to a moment: what counts is what was there before it", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      reaction!(ctx.ana, message, at(2), "❤️")
      reaction!(ctx.marko, message, at(20), "👍")
      message!(ctx.me, ctx.group, at(10))
      theirs = message!(ctx.ana, ctx.group, at(1))
      reaction!(ctx.me, theirs, at(3), "❤️")
      reaction!(ctx.me, theirs, at(30), "👍")

      opts = [until: at(10), limit: 200]

      assert keys(ctx.me, ctx.account, opts) ==
               ["given-#{theirs.id}", "received-#{message.id}", "message-#{message.id}"]

      [given, received, _message] = entries(ctx.me, ctx.account, opts)
      assert given.emoji == ["❤️"]
      assert DateTime.compare(given.at, at(3)) == :eq
      assert received.reactions == [{"❤️", 1}]
      assert received.people == [ctx.ana.username]
      assert DateTime.compare(received.at, at(2)) == :eq
    end
  end
end
