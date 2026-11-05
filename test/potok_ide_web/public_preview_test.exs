defmodule PotokIdeWeb.PublicPreviewTest do
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Events
  alias PotokIde.Events.Format
  alias PotokIde.LinkPreviews
  alias PotokIde.Repo
  alias PotokIde.Social

  @huge_id "99999999999999999999999"

  setup do
    {account, owner} = account_with_profile!("preview-owner")
    %{account: account, owner: owner}
  end

  defp public_group!(owner, attrs \\ %{}),
    do: group_with_members!(owner, [], Map.merge(%{"is_public" => true}, attrs))

  defp public_event!(owner, group, attrs \\ %{}) do
    create_event!(
      owner,
      group,
      event_attrs(Date.add(today(), 3), Map.merge(%{"is_public" => "true"}, attrs))
    )
  end

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp found?(document, selector), do: Enum.count(LazyHTML.query(document, selector)) == 1

  defp meta(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute("content") |> List.first()
  end

  defp og(document, property), do: meta(document, ~s(meta[property="og:#{property}"]))

  defp assert_sent_to_login(conn) do
    assert redirected_to(conn) == ~p"/accounts/log-in"
    conn.resp_body
  end

  describe "a public group" do
    test "shows guests a preview on every tab and with any query", %{conn: conn, owner: owner} do
      group = public_group!(owner, %{"name" => "Komšije", "description" => "Dogovaramo akcije."})

      for path <- [
            ~p"/groups/#{group.id}",
            ~p"/groups/#{group.id}/values",
            ~p"/groups/#{group.id}/group_home",
            ~p"/groups/#{group.id}/calendar",
            ~p"/groups/#{group.id}/values?#{[value: 1]}"
          ] do
        document = conn |> get(path) |> document()

        assert found?(document, "#public-group-login[href='/accounts/log-in']")
        assert found?(document, "#public-group-invitation-note")
        assert found?(document, "#public-group-image")
        assert found?(document, ~s(meta[name="robots"][content="noindex"]))
        assert og(document, "title") == "Komšije"
        assert og(document, "description") == "Dogovaramo akcije."
        assert og(document, "url") == url(~p"/groups/#{group.id}")
      end
    end

    test "the card can be read back like any page Potok previews", %{conn: conn, owner: owner} do
      group = public_group!(owner, %{"name" => "Komšije", "description" => "Dogovaramo akcije."})
      page_url = url(~p"/groups/#{group.id}")

      assert {:ok, preview} =
               conn
               |> get(~p"/groups/#{group.id}")
               |> html_response(200)
               |> LinkPreviews.parse(page_url)

      assert preview["title"] == "Komšije"
      assert preview["description"] == "Dogovaramo akcije."
      assert preview["site_name"] == "Potok"
    end

    test "a guest comes back to the link after logging in", %{conn: conn, owner: owner} do
      group = public_group!(owner)
      conn = get(conn, ~p"/groups/#{group.id}/values")

      assert html_response(conn, 200)
      assert get_session(conn, :account_return_to) == ~p"/groups/#{group.id}/values"
    end

    test "turns its description into plain text and cuts it", %{conn: conn, owner: owner} do
      markdown =
        public_group!(owner, %{"description" => "# Naslov\n\n**Jako** i [link](https://a.b)"})

      assert conn |> get(~p"/groups/#{markdown.id}") |> document() |> og("description") ==
               "Naslov. Jako i link"

      html =
        public_group!(owner, %{
          "description" => "<p>Prvi</p><p>drugi</p><script>alert(1)</script>",
          "description_format" => :html
        })

      assert conn |> get(~p"/groups/#{html.id}") |> document() |> og("description") ==
               "Prvi drugi"

      long = public_group!(owner, %{"description" => String.duplicate("reč ", 200)})
      description = conn |> get(~p"/groups/#{long.id}") |> document() |> og("description")

      assert String.length(description) <= 200
      assert String.ends_with?(description, "…")
    end

    test "without a description says what the link is", %{conn: conn, owner: owner} do
      group = public_group!(owner)

      assert conn |> get(~p"/groups/#{group.id}") |> document() |> og("description") ==
               "A group on Potok."
    end

    test "never shows the code of an app", %{conn: conn, owner: owner} do
      group =
        public_group!(owner, %{
          "description" => "<div>tajna aplikacija</div><script>potok.init()</script>",
          "uses_api" => true
        })

      body = conn |> get(~p"/groups/#{group.id}") |> html_response(200)

      assert body |> LazyHTML.from_document() |> og("description") == "An app on Potok."
      refute body =~ "tajna aplikacija"
      refute body =~ "potok.init"
    end

    test "shows what an app says about itself, and none of its code", %{
      conn: conn,
      owner: owner
    } do
      group =
        public_group!(owner, %{
          "description" => """
          <meta name="description" content="Igra pamćenja za dvoje.">
          <div>tajna aplikacija</div>
          <script>potok.init()</script>
          """,
          "uses_api" => true
        })

      body = conn |> get(~p"/groups/#{group.id}") |> html_response(200)
      document = LazyHTML.from_document(body)

      assert og(document, "description") == "Igra pamćenja za dvoje."
      assert meta(document, ~s(meta[name="description"])) == "Igra pamćenja za dvoje."
      refute body =~ "tajna aplikacija"
      refute body =~ "potok.init"
    end

    test "cuts what an app says about itself", %{conn: conn, owner: owner} do
      text = String.duplicate("reč ", 200)

      group =
        public_group!(owner, %{
          "description" => ~s(<meta name="description" content="#{text}">),
          "uses_api" => true
        })

      description = conn |> get(~p"/groups/#{group.id}") |> document() |> og("description")

      assert String.length(description) <= 200
      assert String.ends_with?(description, "…")
    end

    test "says what the link is when an app says nothing", %{conn: conn, owner: owner} do
      for description <- [
            "",
            "<title>Igra</title>",
            ~s(<meta name="description" content="   ">),
            ~s|<script>document.write('<meta name="description" content="iz skripte">')</script>|
          ] do
        group = public_group!(owner, %{"description" => description, "uses_api" => true})

        assert conn |> get(~p"/groups/#{group.id}") |> document() |> og("description") ==
                 "An app on Potok."
      end
    end

    test "reads an app's own words from the default description only", %{
      conn: conn,
      owner: owner
    } do
      group = public_group!(owner, %{"uses_api" => true})

      {:ok, _alt} =
        Social.create_alt_description(owner, group, %{
          "name" => "Samo za upravu",
          "description" => ~s(<meta name="description" content="Samo za upravu">),
          "description_format" => :html,
          "uses_api" => true
        })

      body = conn |> get(~p"/groups/#{group.id}") |> html_response(200)

      assert body |> LazyHTML.from_document() |> og("description") == "An app on Potok."
      refute body =~ "Samo za upravu"
    end

    test "takes what an html description says of itself over its first lines", %{
      conn: conn,
      owner: owner
    } do
      group =
        public_group!(owner, %{
          "description" => """
          <meta name="description" content="Zmaj je izronio iz Dunava.">
          <p>iz kraja</p><h1>Vest</h1>
          """,
          "description_format" => :html
        })

      assert conn |> get(~p"/groups/#{group.id}") |> document() |> og("description") ==
               "Zmaj je izronio iz Dunava."
    end

    test "does not repeat its name under its name", %{conn: conn, owner: owner} do
      group =
        public_group!(owner, %{
          "name" => "Desilo se čudo",
          "description" => "<h1>Desilo se čudo</h1><p>Zmaj je izronio.</p>",
          "description_format" => :html
        })

      assert conn |> get(~p"/groups/#{group.id}") |> document() |> og("description") ==
               "Zmaj je izronio."
    end

    test "a meta tag in markdown is only text", %{conn: conn, owner: owner} do
      group =
        public_group!(owner, %{"description" => ~s(<meta name="description" content="skriveno">)})

      refute conn |> get(~p"/groups/#{group.id}") |> document() |> og("description") == "skriveno"
    end

    test "has a card of its own, with or without a picture", %{conn: conn, owner: owner} do
      plain = public_group!(owner, %{"name" => "Komšije"})

      pictured =
        public_group!(owner, %{
          "name" => "Čamci",
          "group_picture_url" => "https://example.com/grupa.png"
        })

      for {group, name} <- [{plain, "Komšije"}, {pictured, "Čamci"}] do
        document = conn |> get(~p"/groups/#{group.id}") |> document()

        assert og(document, "image") =~ "/cards/group/#{group.id}.jpg?v="
        assert og(document, "image:type") == "image/jpeg"
        assert og(document, "image:width") == "1200"
        assert og(document, "image:height") == "630"
        assert og(document, "image:alt") == name
        assert meta(document, ~s(meta[name="twitter:card"])) == "summary_large_image"
      end
    end

    test "gives its card a new address when the card changes", %{conn: conn, owner: owner} do
      group = public_group!(owner)
      image = fn -> conn |> get(~p"/groups/#{group.id}") |> document() |> og("image") end
      first = image.()

      assert image.() == first

      {:ok, _group} =
        Social.update_group(owner, group, %{"group_picture_url" => "https://example.com/a.png"})

      assert image.() != first
    end

    test "shows on its page an SVG that its card cannot", %{conn: conn, owner: owner} do
      for picture <- [
            "https://deoba.example/favicon.svg",
            "https://deoba.example/FAVICON.SVG?v=2",
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4="
          ] do
        group = public_group!(owner, %{"group_picture_url" => picture})
        document = conn |> get(~p"/groups/#{group.id}") |> document()

        assert og(document, "image") =~ "/cards/group/#{group.id}.jpg?v="

        # Browsers read it, so the page itself shows it.
        assert found?(document, "#public-group-image[src^='/avatar/group/#{group.id}']")
      end
    end

    test "keeps the chat and the members to itself", %{conn: conn, owner: owner} do
      {_member_account, member} = account_with_profile!("preview-member")
      group = group_with_members!(owner, [member], %{"is_public" => true})

      {:ok, value} = Social.create_value(owner, group, %{"content" => "razgovor iza logina"})

      body =
        conn |> get(~p"/groups/#{group.id}/values?#{[value: value.id]}") |> html_response(200)

      refute body =~ "razgovor iza logina"
      refute body =~ owner.username
      refute body =~ member.username
    end

    test "shows signed-in accounts the group itself", ctx do
      group = public_group!(ctx.owner, %{"name" => "Komšije"})

      conn = ctx.conn |> log_in_account(ctx.account) |> get(~p"/groups/#{group.id}")
      document = document(conn)

      refute found?(document, "#public-group")
      assert found?(document, "[data-phx-main]")
      refute get_session(conn, :account_return_to)
    end

    test "follows the guest's language", %{owner: owner} do
      group = public_group!(owner)

      english = Phoenix.ConnTest.build_conn() |> get(~p"/groups/#{group.id}?#{[locale: "en"]}")
      assert og(document(english), "locale") == "en_US"

      # A crawler has no session and asks for no language.
      crawler = Phoenix.ConnTest.build_conn() |> get(~p"/groups/#{group.id}")
      assert og(document(crawler), "locale") == "sr_RS"
      assert og(document(crawler), "description") == "Grupa na Potoku."
    end
  end

  describe "a link into an app" do
    setup %{owner: owner} do
      app =
        public_group!(owner, %{
          "name" => "Vesti",
          "description" => "<p>app</p>",
          "description_format" => :html,
          "uses_api" => true
        })

      %{app: app}
    end

    defp story!(owner, app, attrs) do
      {:ok, feed} =
        Social.create_group(owner, app, %{
          "name" => ".feed",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, story} =
        Social.create_group(
          owner,
          feed,
          Map.merge(
            %{
              "name" => "Most",
              "description" => "Most je otvoren.",
              "description_format" => :markdown
            },
            attrs
          )
        )

      story
    end

    test "shows a guest the group it opens on", %{conn: conn, owner: owner, app: app} do
      story = story!(owner, app, %{"is_public" => true})
      path = ~p"/groups/#{app.id}/group_home?#{[at: story.id]}"

      document = conn |> get(path) |> document()

      assert og(document, "title") == "Most"
      assert og(document, "description") == "Most je otvoren."
      assert og(document, "url") == PotokIdeWeb.Endpoint.url() <> path
    end

    test "keeps the alternative description in the address of the card", ctx do
      story = story!(ctx.owner, ctx.app, %{"is_public" => true})
      path = ~p"/groups/#{ctx.app.id}/group_home?#{[at: story.id, d: 5]}"

      document = ctx.conn |> get(path) |> document()

      assert og(document, "title") == "Most"
      assert og(document, "url") == PotokIdeWeb.Endpoint.url() <> path
    end

    test "a guest comes back to the same link after logging in", ctx do
      story = story!(ctx.owner, ctx.app, %{"is_public" => true})
      path = ~p"/groups/#{ctx.app.id}/group_home?#{[at: story.id]}"

      assert ctx.conn |> get(path) |> get_session(:account_return_to) == path
    end

    test "says nothing about a private group, and shows the app", ctx do
      story = story!(ctx.owner, ctx.app, %{"is_public" => false})

      document =
        ctx.conn
        |> get(~p"/groups/#{ctx.app.id}/group_home?#{[at: story.id]}")
        |> document()

      assert og(document, "title") == "Vesti"
      assert og(document, "url") == url(~p"/groups/#{ctx.app.id}")
      refute document |> LazyHTML.to_html() |> String.contains?("Most")
    end

    test "shows the app for what is no group", %{conn: conn, app: app} do
      for at <- ["nope", "0", @huge_id] do
        document = conn |> get(~p"/groups/#{app.id}/group_home?#{[at: at]}") |> document()

        assert og(document, "title") == "Vesti"
      end
    end

    test "counts on the tab of the description only", %{conn: conn, owner: owner, app: app} do
      story = story!(owner, app, %{"is_public" => true})

      document = conn |> get(~p"/groups/#{app.id}/values?#{[at: story.id]}") |> document()

      assert og(document, "title") == "Vesti"
    end

    test "leaves signed-in accounts to the app", ctx do
      story = story!(ctx.owner, ctx.app, %{"is_public" => true})

      document =
        ctx.conn
        |> log_in_account(ctx.account)
        |> get(~p"/groups/#{ctx.app.id}/group_home?#{[at: story.id]}")
        |> document()

      refute found?(document, "#public-group-login")
    end
  end

  describe "other groups" do
    test "send guests to log in without a word about them", %{conn: conn, owner: owner} do
      private = group_with_members!(owner, [], %{"name" => "Tajna grupa"})

      body = conn |> get(~p"/groups/#{private.id}") |> assert_sent_to_login()
      refute body =~ "Tajna grupa"

      conn |> get(~p"/groups/#{private.id}/values") |> assert_sent_to_login()
    end

    test "a thread of a public group stays behind the login", %{conn: conn, owner: owner} do
      group = public_group!(owner)
      {:ok, value} = Social.create_value(owner, group, %{"content" => "tema"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "nit"})

      assert thread.is_public
      conn |> get(~p"/groups/#{thread.id}") |> assert_sent_to_login()
    end

    test "the root stays behind the login", %{conn: conn} do
      conn |> get(~p"/groups/#{Social.get_root_group!().id}") |> assert_sent_to_login()
    end

    # Direct chats are never public, but nothing in the database says so.
    test "a direct chat stays behind the login, even a public one", %{conn: conn, owner: owner} do
      {_other_account, other} = account_with_profile!("preview-other")
      {:ok, direct} = Social.get_or_create_direct_group(owner, other)

      conn |> get(~p"/groups/#{direct.id}") |> assert_sent_to_login()

      direct |> Ecto.Changeset.change(is_public: true) |> Repo.update!()

      conn |> get(~p"/groups/#{direct.id}") |> assert_sent_to_login()
    end

    test "a link to nothing looks the same", %{conn: conn} do
      for id <- ["0", "-1", "abc", "1.5", @huge_id] do
        conn |> get("/groups/#{id}") |> assert_sent_to_login()
      end
    end
  end

  describe "a public event" do
    test "shows guests a preview", %{conn: conn, owner: owner} do
      group = public_group!(owner, %{"name" => "Komšije"})

      event =
        public_event!(owner, group, %{
          "title" => "Čišćenje obale",
          "location" => "Ada",
          "description" => "Skupljamo se **kod mosta**."
        })

      conn = get(conn, ~p"/groups/#{group.id}/calendar?#{[event: event.id]}")
      document = document(conn)

      assert found?(document, "#public-event-login[href='/accounts/log-in']")
      assert found?(document, "#public-event-location")
      assert found?(document, "#public-event-description")
      refute found?(document, "#public-event-recurrence")
      assert found?(document, ~s(meta[name="robots"][content="noindex"]))

      assert og(document, "title") == "Čišćenje obale"
      assert og(document, "description") =~ "18:00–19:30"
      assert og(document, "description") =~ "Ada"
      assert og(document, "description") =~ "Skupljamo se kod mosta."
      assert og(document, "image") =~ "/cards/event/#{event.id}.jpg?v="
      assert og(document, "image:alt") == "Čišćenje obale"

      assert og(document, "url") ==
               url(~p"/groups/#{group.id}/calendar?#{[event: event.id]}")

      assert get_session(conn, :account_return_to) ==
               ~p"/groups/#{group.id}/calendar?#{[event: event.id]}"
    end

    test "does not need a description or a place", %{conn: conn, owner: owner} do
      group = public_group!(owner)
      event = public_event!(owner, group, %{"location" => ""})

      document = conn |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}") |> document()

      refute found?(document, "#public-event-details")
      assert og(document, "description") =~ "18:00–19:30"
    end

    test "says when the next occurrence is and how it repeats", %{conn: conn, owner: owner} do
      group = public_group!(owner)
      # Tomorrow is the next occurrence at any time of day; today's could be
      # either side of 18:00.
      start = Date.add(today(), -13)

      event =
        create_event!(
          owner,
          group,
          event_attrs(start, %{
            "is_public" => "true",
            "recurrence" => "weekly",
            "recurrence_weekdays" => [Integer.to_string(Date.day_of_week(start))]
          })
        )

      document = conn |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}") |> document()
      description = og(document, "description")

      assert found?(document, "#public-event-recurrence")
      assert description =~ Format.date(Date.add(today(), 1), today())
      refute description =~ Format.date(start, today())
    end

    test "still shows when it took place", %{conn: conn, owner: owner} do
      group = public_group!(owner)

      event =
        create_event!(owner, group, event_attrs(Date.add(today(), -30), %{"is_public" => "true"}))

      document = conn |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}") |> document()

      assert og(document, "description") =~ "18:00–19:30"
    end

    test "shows through any calendar, and hides a private group", %{conn: conn, owner: owner} do
      group = group_with_members!(owner, [], %{"name" => "Tajna grupa"})
      event = public_event!(owner, group, %{"title" => "Otvoreni dan"})

      for path <- [
            ~p"/groups/#{group.id}/calendar?#{[event: event.id]}",
            ~p"/groups/#{Social.get_root_group!().id}/calendar?#{[event: event.id]}"
          ] do
        body = conn |> get(path) |> html_response(200)
        document = LazyHTML.from_document(body)

        assert og(document, "title") == "Otvoreni dan"
        refute body =~ "Tajna grupa"
        refute body =~ owner.username
      end
    end

    test "only opens from a calendar link", %{conn: conn, owner: owner} do
      group = group_with_members!(owner, [])
      event = public_event!(owner, group)

      conn |> get(~p"/groups/#{group.id}/values?#{[event: event.id]}") |> assert_sent_to_login()
    end
  end

  describe "other events" do
    test "a private event of a public group shows the group", %{conn: conn, owner: owner} do
      group = public_group!(owner, %{"name" => "Komšije"})
      event = create_event!(owner, group, event_attrs(today(), %{"title" => "Sastanak uprave"}))

      body =
        conn |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}") |> html_response(200)

      assert body |> LazyHTML.from_document() |> og("title") == "Komšije"
      refute body =~ "Sastanak uprave"
    end

    test "a private event of a private group sends guests to log in", %{conn: conn, owner: owner} do
      group = group_with_members!(owner, [])
      event = create_event!(owner, group, event_attrs(today(), %{"title" => "Sastanak uprave"}))

      body =
        conn
        |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}")
        |> assert_sent_to_login()

      refute body =~ "Sastanak uprave"
    end

    test "a cancelled event is gone", %{conn: conn, owner: owner} do
      group = group_with_members!(owner, [])
      event = public_event!(owner, group, %{"title" => "Otkazano"})
      {:ok, _event} = Events.cancel_event(owner, event)

      conn |> get(~p"/groups/#{group.id}/calendar?#{[event: event.id]}") |> assert_sent_to_login()
    end

    test "a broken event link falls back to the group", %{conn: conn, owner: owner} do
      public = public_group!(owner, %{"name" => "Komšije"})
      private = group_with_members!(owner, [])

      for query <- ["event=abc", "event=#{@huge_id}", "event[]=1", "event=0"] do
        assert conn |> get("/groups/#{public.id}/calendar?#{query}") |> document() |> og("title") ==
                 "Komšije"

        conn |> get("/groups/#{private.id}/calendar?#{query}") |> assert_sent_to_login()
      end
    end
  end
end
