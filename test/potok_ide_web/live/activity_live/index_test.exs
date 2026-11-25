defmodule PotokIdeWeb.ActivityLive.IndexTest do
  @moduledoc """
  The page of one's activity: what it shows, by the day, what it leads to, and
  how it follows the profile in use.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.ActivityFixtures
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.{Accounts, Events, Repo, Social, Tags}
  alias PotokIde.Social.DrawnProcesses

  defp unique, do: System.unique_integer([:positive])

  setup %{conn: conn} do
    {account, me} = account_with_profile!("al#{unique()}")
    {_, owner} = account_with_profile!("al#{unique()}")
    group = group_with_members!(owner, [me], %{"name" => "Zgrada #{unique()}"})

    %{conn: log_in_account(conn, account), account: account, me: me, owner: owner, group: group}
  end

  defp open(conn, path \\ ~p"/activity"), do: conn |> live(path) |> elem(1)

  # With a browser's time zone, as app.js sends it.
  defp open_in(conn, zone, path \\ ~p"/activity") do
    conn |> put_connect_params(%{"time_zone" => zone}) |> live(path) |> elem(1)
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity-list > li")
    |> LazyHTML.attribute("id")
  end

  defp link_of(view, key) do
    view
    |> element("#activity-#{key}-link")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("href")
    |> hd()
  end

  describe "opening it" do
    test "a guest is sent to log in, an account with no profile to make one" do
      assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(build_conn(), ~p"/activity")

      account = PotokIde.AccountsFixtures.account_fixture()

      assert {:error, {_kind, %{to: "/profiles"}}} =
               build_conn() |> log_in_account(account) |> live(~p"/activity")
    end

    test "the first HTML holds outlines, the connected page the list", ctx do
      message = message!(ctx.me, ctx.group, at(1))

      html = ctx.conn |> get(~p"/activity") |> html_response(200)
      document = LazyHTML.from_document(html)
      refute Enum.empty?(LazyHTML.query(document, "#activity-loading"))
      assert Enum.empty?(LazyHTML.query(document, "#activity-message-#{message.id}"))

      view = open(ctx.conn)
      refute has_element?(view, "#activity-loading")
      assert has_element?(view, "#activity-message-#{message.id}")
    end

    test "is in the menu, on the page of profiles and on one's own card", ctx do
      view = open(ctx.conn)
      assert has_element?(view, "#app-sidebar [data-nav-link][href='/activity']")

      {:ok, profiles, _html} = live(ctx.conn, ~p"/profiles")
      assert has_element?(profiles, "#profiles-current #profiles-activity[href='/activity']")
      refute has_element?(profiles, "#profiles-default #profiles-activity")

      {:ok, card, _html} = live(ctx.conn, ~p"/u/#{ctx.me.username}")
      assert has_element?(card, "#profile-card-activity[href='/activity']")
      {:ok, card, _html} = live(ctx.conn, ~p"/u/#{ctx.owner.username}")
      assert has_element?(card, "#profile-card")
      refute has_element?(card, "#profile-card-activity")
    end

    test "says that the holders of a shared profile see it", ctx do
      only_me = ctx.conn |> open() |> element("#activity-header") |> render()
      ctx.me |> Ecto.Changeset.change(sharing: :shared) |> Repo.update!()
      shared = ctx.conn |> open() |> element("#activity-header") |> render()
      assert shared != only_me
    end

    test "with nothing in it says so, by what is looked for", ctx do
      # The group joined in the setup is there, but no message.
      view = open(ctx.conn, ~p"/activity?kind=messages")
      assert has_element?(view, "#activity-empty")
      refute has_element?(view, "#activity-end")
      refute has_element?(view, "#activity-more")
    end
  end

  describe "a row" do
    test "of a message leads to it, with the group and the hour of the reader", ctx do
      message = message!(ctx.me, ctx.group, at(0), %{content: "Sastanak je u četvrtak"})

      view = open_in(ctx.conn, "Europe/Belgrade")
      row = "#activity-message-#{message.id}"
      assert has_element?(view, row <> "-text", "Sastanak je u četvrtak")
      assert has_element?(view, row <> "-place", ctx.group.name)
      assert has_element?(view, row <> " time", "11:00")

      view = open_in(ctx.conn, "Etc/UTC")
      assert has_element?(view, row <> " time", "10:00")

      assert link_of(view, "message-#{message.id}") ==
               "/groups/#{ctx.group.id}/values?value=#{message.id}"
    end

    test "of the reactions of others counts and names them", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      reaction!(ctx.owner, message, at(2), "❤️")

      view = open(ctx.conn, ~p"/activity?kind=received")
      row = "#activity-received-#{message.id}"
      assert has_element?(view, row <> "-reactions", "❤️")
      assert has_element?(view, row <> "-reactions", ctx.owner.username)
      # A name leads nowhere: who may open a card, the card decides.
      refute has_element?(view, row <> "-reactions a")
    end

    test "of one's reaction names the author and the emoji", ctx do
      message = message!(ctx.owner, ctx.group, at(1), %{content: "Evo zapisnika"})
      reaction!(ctx.me, message, at(2), "🎉")

      view = open(ctx.conn, ~p"/activity?kind=given")
      row = "#activity-given-#{message.id}"
      assert has_element?(view, row <> "-text", ctx.owner.username)
      assert has_element?(view, row <> "-emoji", "🎉")
    end

    test "of a vote says what was chosen, unless the poll is secret", ctx do
      open = create_poll!(ctx.owner, ctx.group)
      secret = create_poll!(ctx.owner, ctx.group, %{"secret" => "true", "question" => "Tajno?"})
      vote!(ctx.me, ctx.account, open, 1)
      vote!(ctx.me, ctx.account, secret, 1)

      view = open(ctx.conn, ~p"/activity?kind=votes")
      assert view |> element("#activity-list") |> render() =~ "Tajno?"

      choices = for id <- rows(view), has_element?(view, "##{id}-choice"), do: id
      assert [with_choice] = choices
      assert has_element?(view, "##{with_choice}-choice", "Mountains")

      assert has_element?(
               view,
               "##{with_choice}-link[href='/groups/#{ctx.group.id}/polls?poll=#{open.id}']"
             )
    end

    test "of an answer to an event leads to its day and says the answer", ctx do
      date = Date.add(today(), 7)
      event = create_event!(ctx.owner, ctx.group, event_attrs(date))
      {:ok, response} = Events.respond(ctx.me, event, date, :going)

      view = open(ctx.conn, ~p"/activity?kind=events")
      assert has_element?(view, "#activity-rsvp-#{response.id}-mark")

      assert link_of(view, "rsvp-#{response.id}") ==
               "/groups/#{ctx.group.id}/calendar?event=#{event.id}&on=#{date}"
    end

    test "of records counts them and leads to the app", ctx do
      for n <- 1..3, do: record!(ctx.me, ctx.group, at(n), %{data: %{"tajna" => "lozinka"}})

      view = open(ctx.conn, ~p"/activity?kind=work")
      assert [_day, row] = rows(view)
      assert has_element?(view, "##{row}", "3")
      refute render(view) =~ "lozinka"

      assert has_element?(
               view,
               "##{row}-link[href='/groups/#{ctx.group.id}/group_home?d=default']"
             )
    end

    test "of a run leads to the processes, of a tag to what it is on", ctx do
      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "Molbe",
          "graph" => %{
            "v" => 2,
            "nodes" => [
              %{"id" => "start", "type" => "startEvent"},
              %{"id" => "kraj", "type" => "endEvent"}
            ],
            "flows" => [%{"from" => "start", "to" => "kraj"}]
          },
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)

      {:ok, _run} =
        DrawnProcesses.start(ctx.me, ctx.group, process.id, %{"title" => "T", "text" => "t"})

      {:ok, _} = Tags.add_tag(ctx.me, :group, ctx.group.id, "moje", :private)

      view = open(ctx.conn, ~p"/activity?kind=work")
      assert [_day, run] = rows(view)
      assert has_element?(view, "##{run}-link[href='/groups/#{ctx.group.id}/processes']")
      assert has_element?(view, "##{run}-text", "Molbe")

      view = open(ctx.conn, ~p"/activity?kind=notices")
      assert has_element?(view, "#activity-tag-group-#{ctx.group.id}", "#moje")
      assert link_of(view, "tag-group-#{ctx.group.id}") == "/groups/#{ctx.group.id}"
    end

    test "in a thread and in a direct conversation says where", ctx do
      root = message!(ctx.owner, ctx.group, at(0))

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.me, ctx.group, root, %{"name" => "O krovu"})

      in_thread = message!(ctx.me, thread, at(1))
      {:ok, direct} = Social.get_or_create_direct_group(ctx.me, ctx.owner)
      in_direct = message!(ctx.me, direct, at(2))

      view = open(ctx.conn, ~p"/activity?kind=messages")

      assert has_element?(
               view,
               "#activity-message-#{in_thread.id}-place",
               "#{ctx.group.name} › O krovu"
             )

      assert has_element?(view, "#activity-message-#{in_direct.id}-place", ctx.owner.username)
    end
  end

  describe "days and pages" do
    test "each day once, in the reader's zone, with the newest first", ctx do
      first = message!(ctx.me, ctx.group, ~U[2026-03-02 22:30:00Z])
      second = message!(ctx.me, ctx.group, ~U[2026-03-02 23:30:00Z])

      assert ctx.conn |> open_in("Etc/UTC", ~p"/activity?kind=messages") |> rows() == [
               "activity-day-2026-03-02",
               "activity-message-#{second.id}",
               "activity-message-#{first.id}"
             ]

      assert ctx.conn |> open_in("Europe/Belgrade", ~p"/activity?kind=messages") |> rows() == [
               "activity-day-2026-03-03",
               "activity-message-#{second.id}",
               "activity-day-2026-03-02",
               "activity-message-#{first.id}"
             ]
    end

    test "older ones come below, without the day told again or a row twice", ctx do
      messages = for n <- 1..40, do: message!(ctx.me, ctx.group, at(n))
      newest = Enum.reverse(messages)

      view = open(ctx.conn, ~p"/activity?kind=messages")
      assert length(rows(view)) == 1 + PotokIde.Activity.page_size()
      refute has_element?(view, "#activity-end")

      view |> element("#activity-more") |> render_click()

      assert rows(view) ==
               ["activity-day-2026-03-02" | Enum.map(newest, &"activity-message-#{&1.id}")]

      refute has_element?(view, "#activity-more")
      assert has_element?(view, "#activity-end")
    end

    test "a row that fell below the page meanwhile is not there twice", ctx do
      moved = message!(ctx.me, ctx.group, at(0))
      old = reaction!(ctx.owner, moved, at(1), "👍")
      {_, other} = account_with_profile!("al#{unique()}")
      newest = reaction!(other, moved, at(500), "🎉")

      for n <- 1..35 do
        message = message!(ctx.me, ctx.group, at(2))
        reaction!(ctx.owner, message, at(10 + n))
      end

      view = open(ctx.conn, ~p"/activity?kind=received")
      assert "activity-received-#{moved.id}" in rows(view)

      Repo.delete!(newest)
      view |> element("#activity-more") |> render_click()

      # LiveViewTest raises on two elements of one id; the row is there once.
      assert Enum.count(rows(view), &(&1 == "activity-received-#{moved.id}")) == 1
      assert old.value_id == moved.id
    end

    test "up to a day, kept in the address and taken back", ctx do
      early = message!(ctx.me, ctx.group, ~U[2026-03-02 22:30:00Z])
      late = message!(ctx.me, ctx.group, ~U[2026-03-02 23:30:00Z])

      view = open_in(ctx.conn, "Europe/Belgrade", ~p"/activity?kind=messages")
      view |> form("#activity-until-form", %{"until" => "2026-03-02"}) |> render_change()
      assert_patch(view, "/activity?kind=messages&until=2026-03-02")

      assert rows(view) == ["activity-day-2026-03-02", "activity-message-#{early.id}"]

      view |> element("#activity-until-clear") |> render_click()
      assert_patch(view, "/activity?kind=messages")
      assert "activity-message-#{late.id}" in rows(view)

      view |> form("#activity-until-form", %{"until" => "2026-03-01"}) |> render_change()
      assert has_element?(view, "#activity-empty")
    end

    test "a kind is picked by a tap and kept in the address; made up ones mean all", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      reaction!(ctx.owner, message, at(2))

      view = open(ctx.conn)
      assert has_element?(view, "#activity-kind-all[aria-current='page']")
      view |> element("#activity-kind-received") |> render_click()
      assert_patch(view, "/activity?kind=received")
      assert rows(view) == ["activity-day-2026-03-02", "activity-received-#{message.id}"]

      view = open(ctx.conn, ~p"/activity?kind=ništa&until=juče")
      assert has_element?(view, "#activity-kind-all[aria-current='page']")
      assert "activity-message-#{message.id}" in rows(view)

      for until <- ["99999-01-01", "0001-01-01", "-9999-01-01"] do
        view = open(ctx.conn, ~p"/activity?until=#{until}")
        assert "activity-message-#{message.id}" in rows(view)
      end
    end

    test "every kind opens", ctx do
      for kind <- PotokIde.Activity.filters() do
        view = open(ctx.conn, ~p"/activity?kind=#{kind}")
        assert has_element?(view, "#activity-kind-#{kind}[aria-current='page']")
      end
    end
  end

  describe "the profile in use" do
    test "another one picked elsewhere brings its own list", ctx do
      message = message!(ctx.me, ctx.group, at(1))

      {:ok, second} =
        Social.create_profile_for_account(ctx.account, %{
          username: "al#{unique()}",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      add_member!(ctx.owner, ctx.group, second)
      theirs = message!(second, ctx.group, at(2))

      view = open(ctx.conn, ~p"/activity?kind=messages")
      assert "activity-message-#{message.id}" in rows(view)

      {:ok, _} = Accounts.set_current_profile(Accounts.get_account!(ctx.account.id), second)

      assert rows(view) == ["activity-day-2026-03-02", "activity-message-#{theirs.id}"]
      assert has_element?(view, "#activity-kind-messages[aria-current='page']")
    end

    test "another holder of a shared profile reads the same, another profile nothing", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      {other_account, _other} = account_with_profile!("al#{unique()}")
      conn = log_in_account(build_conn(), other_account)
      refute "activity-message-#{message.id}" in (conn |> open() |> rows())

      share_profile!(ctx.me, other_account)
      {:ok, _} = Accounts.set_current_profile(Accounts.get_account!(other_account.id), ctx.me)
      assert "activity-message-#{message.id}" in (conn |> open() |> rows())
    end

    test "left a group: its rows are gone on the next opening", ctx do
      message = message!(ctx.me, ctx.group, at(1))
      assert "activity-message-#{message.id}" in (ctx.conn |> open() |> rows())
      {:ok, _} = Social.leave_group(ctx.me, ctx.group)
      refute "activity-message-#{message.id}" in (ctx.conn |> open() |> rows())
    end
  end
end
