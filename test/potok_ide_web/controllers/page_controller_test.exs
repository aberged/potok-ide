defmodule PotokIdeWeb.PageControllerTest do
  use PotokIdeWeb.ConnCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.GroupRole
  alias PotokIde.Storage
  alias PotokIdeWeb.StackCopy

  test "GET / shows guests the landing page", %{conn: conn} do
    document =
      conn
      |> get(~p"/")
      |> html_response(200)
      |> LazyHTML.from_document()

    for selector <- [
          "#landing-hero",
          "#landing-waves",
          "#landing-features",
          "#landing-perks",
          "#landing-domain",
          "#landing-domain-link[href='/domain']",
          "#landing-join",
          "#landing-join ~ #landing-domain",
          "#landing-join + #landing-origin + #landing-domain",
          "#landing-origin-link[href='/origin']",
          "#landing-login-link[href='/accounts/log-in']",
          "#landing-join-login[href='/accounts/log-in']",
          "#guest-header #landing-login-link",
          "#guest-footer #guest-privacy-link[href='/privacy-policy']",
          "#guest-footer #guest-help-link[href='/pomoc']",
          "#landing-features > a#landing-help-link[href='/pomoc']",
          "meta[name=description]"
        ] do
      assert Enum.count(LazyHTML.query(document, selector)) == 1, "missing #{selector}"
    end

    assert Enum.count(LazyHTML.query(document, "#landing-features article")) == 6
    assert Enum.count(LazyHTML.query(document, "#landing-perks li")) == 5
  end

  # Digits only: the words around them depend on the language.
  test "the numbers on the landing page are the app's own", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
    text = fn selector -> document |> LazyHTML.query(selector) |> LazyHTML.text() end

    assert text.("#landing-feature-roles") =~ ~r/\b#{length(GroupRole.permissions())}\b/
    assert text.("#landing-feature-files") =~ ~r/\b#{Storage.max_files()}\b/
    assert text.("#landing-feature-files") =~ ~r/\b#{div(Storage.max_file_size(), 1_000_000)}\b/
  end

  describe "the domain map" do
    defp domain_page(conn) do
      conn |> get(~p"/domain") |> html_response(200) |> LazyHTML.from_document()
    end

    defp map_data(document) do
      document
      |> LazyHTML.query("#domain-map")
      |> LazyHTML.attribute("data-map")
      |> List.first()
      |> Jason.decode!()
    end

    test "is open to guests, with everything around the diagram", %{conn: conn} do
      document = domain_page(conn)

      for selector <- [
            "#guest-about-link[href='/']",
            "#domain-map",
            "#domain-diagram",
            "#domain-view-core[aria-pressed=true]",
            "#domain-view-tables[aria-pressed=false]",
            "#domain-soft-only",
            "#domain-all-links",
            "#domain-overview",
            "#domain-detail[hidden]",
            "#domain-mechanisms",
            "#domain-apps",
            "#domain-apps-flow",
            "meta[name=description]"
          ] do
        assert Enum.count(LazyHTML.query(document, selector)) == 1, "missing #{selector}"
      end

      assert Enum.count(LazyHTML.query(document, "#domain-chips [data-domain]")) == 9
      assert Enum.count(LazyHTML.query(document, "#domain-mechanisms article")) == 21
      assert Enum.count(LazyHTML.query(document, "#domain-apps-capabilities article")) == 15
      assert Enum.count(LazyHTML.query(document, "#domain-apps-limits li")) == 10
      assert Enum.count(LazyHTML.query(document, "#domain-caption [data-caption]")) == 3

      assert Enum.count(LazyHTML.query(document, "#domain-caption [data-caption]:not([hidden])")) ==
               1
    end

    test "is open to accounts that are logged in", %{conn: conn} do
      conn |> log_in_account(account_fixture()) |> get(~p"/domain") |> html_response(200)
    end

    test "hands the diagram its data", %{conn: conn} do
      data = conn |> domain_page() |> map_data()

      assert map_size(data["entities"]) == 34
      assert data["counts"]["keys"] == Enum.count(data["edges"], &(&1["kind"] == "key"))
      assert data["counts"]["soft"] == 8

      assert %{"name" => "Value", "domain" => "content", "table" => "values"} =
               data["entities"]["Value"]

      assert [%{"from" => "Group", "columns" => ["parent group"]}] =
               data["entities"]["Group"]["deletion"]["blocked_by"]
    end

    test "lists the keys that need a closer look", %{conn: conn} do
      document = domain_page(conn)

      assert document
             |> LazyHTML.query("#domain-overview [data-entity=GroupValueRead]")
             |> Enum.count() == 1

      assert document
             |> LazyHTML.query("#domain-overview [data-entity=GroupMembership]")
             |> Enum.count() == 1
    end

    test "every link in the texts leads to an entity of the map", %{conn: conn} do
      document = domain_page(conn)
      data = map_data(document)

      links =
        document
        |> LazyHTML.query("#domain-map [data-entity]")
        |> LazyHTML.attribute("data-entity")

      assert links != []
      assert Enum.uniq(links) -- Map.keys(data["entities"]) == []
    end

    test "gives an overview of apps without teaching their API", %{conn: conn} do
      body = conn |> get(~p"/domain") |> html_response(200)

      for name <-
            ~w(insertValue listValues onNewValue updateDescription getDescription summarizeValues aggregateValues) do
        refute body =~ name
      end
    end

    test "describes columns instead of naming them", %{conn: conn} do
      body = conn |> get(~p"/domain") |> html_response(200)

      for %{fields: fields, virtual: virtual} <- PotokIde.DomainMap.graph().entities,
          %{name: name} <- fields ++ virtual,
          name = to_string(name),
          String.contains?(name, "_") do
        refute body =~ ~r/\b#{name}\b/, name
      end

      assert body =~ "password hash"
    end

    test "the texts flow without gaps around their links", %{conn: conn} do
      document = domain_page(conn)

      for section <- ["#domain-mechanisms", "#domain-apps-capabilities"] do
        refute document |> LazyHTML.query(section) |> LazyHTML.text() =~ ~r/\s[.,]/
      end
    end

    test "speaks the visitor's language", %{conn: conn} do
      conn = conn |> init_test_session(%{locale: "sr"}) |> get(~p"/domain")
      document = conn |> html_response(200) |> LazyHTML.from_document()

      assert document |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Domen Model Potoka"
      assert map_data(document)["entities"]["Value"]["name"] == "Vrednost"
    end
  end

  describe "the page on what Potok is made of" do
    defp stack_page(conn) do
      conn |> get(~p"/stack") |> html_response(200) |> LazyHTML.from_document()
    end

    defp count(document, selector) do
      document |> LazyHTML.query(selector) |> Enum.count()
    end

    test "the domain map ends in a section that leads to it", %{conn: conn} do
      document = domain_page(conn)

      assert count(document, "#domain-map > .dm-layout + #domain-stack") == 1
      assert count(document, "#domain-stack > a#domain-stack-link[href='/stack']") == 1
      assert count(document, "#domain-stack-tools li svg") == 5

      tools = document |> LazyHTML.query("#domain-stack-tools") |> LazyHTML.text()

      for %{name: name} <- StackCopy.tools() do
        assert tools =~ name
      end
    end

    test "has every tool with its logo, what it solves and how", %{conn: conn} do
      document = stack_page(conn)

      assert count(document, "#stack-domain-link[href='/domain']") == 1

      for tool <- StackCopy.tools() do
        section = "#stack-#{tool.id}"

        assert count(document, "#stack-tools a[href='#{section}'] svg") == 1
        assert count(document, "#{section} h2") == 1
        assert count(document, "#{section} svg") == 1
        assert count(document, "#{section} .st-part") == 1
        assert count(document, "#{section} .st-points article") == length(tool.points)
      end
    end

    test "is open to guests and accounts alike", %{conn: conn} do
      assert conn |> log_in_account(account_fixture()) |> get(~p"/stack") |> html_response(200)
    end

    test "keeps the tools' names in Latin in the Cyrillic version", %{conn: conn} do
      conn = conn |> init_test_session(%{locale: "sr_Cyrl"}) |> get(~p"/stack")
      document = conn |> html_response(200) |> LazyHTML.from_document()
      text = document |> LazyHTML.query("#stack") |> LazyHTML.text()

      assert document |> LazyHTML.query("h1") |> LazyHTML.text() =~ "Поток"

      for name <- ~w(BEAM Elixir Phoenix LiveView PubSub Presence Tailwind daisyUI) do
        assert text =~ name
      end

      refute text =~ ~r/\p{Cyrillic}[a-zA-Z]|[a-zA-Z]\p{Cyrillic}/u
    end
  end

  describe "the overview of where Potok comes from" do
    defp origin_page(conn, locale) do
      conn
      |> init_test_session(%{locale: locale})
      |> get(~p"/origin")
      |> html_response(200)
      |> LazyHTML.from_document()
    end

    defp origin_text(document, selector) do
      document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
    end

    test "renders the document, its tables in frames that scroll", %{conn: conn} do
      document = origin_page(conn, "sr")

      assert origin_text(document, "#origin-text h1") =~ ~r/^Potok — /
      assert count(document, "#origin-text .or-table > table") == 3
      assert count(document, "#origin-text .or-matrix > table") == 1
      assert count(document, "#origin-text .or-matrix td.or-none") > 0
      assert count(document, "#origin-text table[style], #origin-text td[style]") == 0
      assert count(document, "#origin-language-note") == 0

      links = LazyHTML.query(document, "#origin-text a[href^='http']")

      assert Enum.count(links) > 20
      assert Enum.count(links) == count(document, "#origin-text a[target=_blank][rel~=noopener]")
    end

    test "is in Cyrillic, with the English titles of sources and site names in Latin",
         %{conn: conn} do
      document = origin_page(conn, "sr_Cyrl")

      assert origin_text(document, "#origin-text h1") =~ ~r/^Поток — /
      assert origin_text(document, "#origin-text span[lang=en]") =~ "Believe the Hype"
      assert origin_text(document, "#origin-text") =~ "nszbor.org"
      assert origin_text(document, "#origin-text") =~ "Вајбер"
    end

    test "tells English visitors that it is in Serbian", %{conn: conn} do
      document = origin_page(conn, "en")

      assert count(document, "#origin-language-note") == 1
      assert count(document, "article#origin-text[lang=sr]") == 1
      assert origin_text(document, "#origin-text h1") =~ ~r/^Potok — /
    end

    test "is open to accounts that are logged in", %{conn: conn} do
      assert conn |> log_in_account(account_fixture()) |> get(~p"/origin") |> html_response(200)
    end
  end

  describe "the help page" do
    defp help_page(conn, locale) do
      conn
      |> init_test_session(%{locale: locale})
      |> get(~p"/pomoc")
      |> html_response(200)
      |> LazyHTML.from_document()
    end

    defp help_text(document, selector) do
      document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
    end

    test "lists every section in both lists of contents", %{conn: conn} do
      document = help_page(conn, "sr")
      sections = count(document, "#help-text h2[id]")

      assert sections > 0
      assert help_text(document, "#help-top h1") == PotokIdeWeb.HelpDoc.get("sr").title
      assert count(document, "#help-toc .hp-toc-list > li > a") == sections
      assert count(document, "#help-toc-phone .hp-toc-list > li > a") == sections

      for link <- LazyHTML.query(document, "#help-toc a") do
        ["#" <> id] = LazyHTML.attribute(link, "href")
        assert count(document, "#help-text [id='#{id}']") == 1, "no section #{id}"
      end

      assert count(document, "#help-language-note") == 0
      assert count(document, "#guest-about-link[href='/']") == 1
    end

    test "gives every element its own id and every picture its size", %{conn: conn} do
      document = help_page(conn, "sr")
      ids = document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")

      assert ids == Enum.uniq(ids)

      assert count(document, "#help-text figure img") ==
               count(document, "#help-text figure img[width][height][loading=lazy]")
    end

    test "is in Cyrillic, with the same sections", %{conn: conn} do
      document = help_page(conn, "sr_Cyrl")

      assert help_text(document, "#help-top h1") =~ ~r/\p{Cyrillic}/u

      assert count(document, "#help-text h2[id]") ==
               count(help_page(conn, "sr"), "#help-text h2[id]")
    end

    test "tells English visitors that the pictures are in Serbian", %{conn: conn} do
      document = help_page(conn, "en")

      assert count(document, "#help-language-note") == 1
      assert help_text(document, "#help-top h1") == PotokIdeWeb.HelpDoc.get("en").title
    end

    test "leads accounts that are logged in back to the app", %{conn: conn} do
      document =
        conn
        |> log_in_account(account_fixture())
        |> get(~p"/pomoc")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert count(document, "#guest-header #help-back-link[href='/groups']") == 1
      assert count(document, "#guest-about-link") == 0
    end

    test "is also at /help", %{conn: conn} do
      assert conn |> get(~p"/help") |> redirected_to() == ~p"/pomoc"
    end
  end

  describe "the tutorials of the help page" do
    defp tutorial_page(conn, slug, locale) do
      conn
      |> init_test_session(%{locale: locale})
      |> get(~p"/pomoc/#{slug}")
      |> html_response(200)
      |> LazyHTML.from_document()
    end

    test "each lists its steps, leads back to the examples and to the others", %{conn: conn} do
      for slug <- PotokIdeWeb.HelpDoc.tutorial_slugs() do
        document = tutorial_page(conn, slug, "sr")
        {:ok, doc} = PotokIdeWeb.HelpDoc.tutorial(slug, "sr")
        steps = count(document, "#tutorial-text h2[id]")

        assert steps > 0
        assert help_text(document, "#tutorial-top h1") == doc.title
        assert count(document, "#tutorial-toc .hp-toc-list > li > a") == steps
        assert count(document, "#tutorial-toc-phone .hp-toc-list > li > a") == steps
        assert count(document, "#tutorial-examples-link[href='/pomoc#primeri']") == 1

        others = PotokIdeWeb.HelpDoc.tutorial_slugs() -- [slug]
        assert count(document, "#tutorial-others a.hp-other") == length(others)

        for other <- others do
          assert count(document, "#tutorial-other-#{other}[href='/pomoc/#{other}']") == 1
        end

        ids = document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
        assert ids == Enum.uniq(ids), "an id repeats on #{slug}"

        assert count(document, "#tutorial-text figure img") ==
                 count(document, "#tutorial-text figure img[width][height][loading=lazy]")

        assert count(document, "#tutorial-language-note") == 0
      end
    end

    test "are in Cyrillic and in English too", %{conn: conn} do
      cyrillic = tutorial_page(conn, "zgrada", "sr_Cyrl")
      assert help_text(cyrillic, "#tutorial-top h1") =~ ~r/\p{Cyrillic}/u

      english = tutorial_page(conn, "zgrada", "en")
      assert count(english, "#tutorial-language-note") == 1
      {:ok, doc} = PotokIdeWeb.HelpDoc.tutorial("zgrada", "en")
      assert help_text(english, "#tutorial-top h1") == doc.title
    end

    test "lead accounts that are logged in back to the app", %{conn: conn} do
      document =
        conn
        |> log_in_account(account_fixture())
        |> get(~p"/pomoc/zadruga")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert count(document, "#guest-header #tutorial-back-link[href='/groups']") == 1
      assert count(document, "#guest-about-link") == 0
    end

    test "an unknown one is not found", %{conn: conn} do
      assert conn |> get(~p"/pomoc/nema-ga") |> response(404)
    end

    test "are also under /help", %{conn: conn} do
      assert conn |> get(~p"/help/zadruga") |> redirected_to() == ~p"/pomoc/zadruga"
    end
  end

  describe "Potok's card for shared links" do
    defp og(document, property) do
      document
      |> LazyHTML.query(~s(meta[property="og:#{property}"]))
      |> LazyHTML.attribute("content")
      |> List.first()
    end

    test "is on the landing page and the page private links end up on", %{conn: conn} do
      for path <- [~p"/", ~p"/accounts/log-in"] do
        document = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

        assert og(document, "site_name") == "Potok"
        assert og(document, "type") == "website"
        assert og(document, "title") == "Potok · Society for society"
        assert og(document, "description") =~ "Conversations, events, files, roles"
        assert og(document, "url") == PotokIdeWeb.Endpoint.url() <> path
        assert og(document, "image") == url(~p"/images/og.png")
        assert og(document, "image:width") == "1200"
        assert og(document, "image:height") == "630"
        assert og(document, "locale") == "en_US"

        assert Enum.count(LazyHTML.query(document, ~s(meta[name="description"]))) == 1
        assert Enum.empty?(LazyHTML.query(document, ~s(meta[name="robots"])))

        assert document
               |> LazyHTML.query(~s(meta[name="twitter:card"]))
               |> LazyHTML.attribute("content") == ["summary_large_image"]
      end
    end

    test "is in Serbian for crawlers, which ask for no language" do
      document =
        Phoenix.ConnTest.build_conn()
        |> get(~p"/")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert og(document, "title") == "Potok · Društvo društvu"
      assert og(document, "locale") == "sr_RS"
    end

    test "is in Serbian in Cyrillic too", %{conn: conn} do
      document =
        conn |> get(~p"/?locale=sr_Cyrl") |> html_response(200) |> LazyHTML.from_document()

      assert og(document, "locale") == "sr_RS"
    end

    test "has its picture", %{conn: conn} do
      conn = get(conn, ~p"/images/og.png")

      assert response(conn, 200)
      assert response_content_type(conn, :png)
    end
  end

  test "GET / redirects authenticated accounts without a profile to profiles", %{conn: conn} do
    account = account_fixture()

    conn =
      conn
      |> log_in_account(account)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/profiles"
  end

  test "GET / redirects authenticated accounts with a current profile to groups", %{conn: conn} do
    account = account_fixture()

    {:ok, _profile} =
      Social.create_profile_for_account(account, %{
        username: "root-groups",
        description_format: :markdown,
        sharing: :unique
      })

    account = Accounts.get_account!(account.id)

    conn =
      conn
      |> log_in_account(account)
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/groups"
  end

  test "GET /privacy-policy shows the policy in the selected locale", %{conn: conn} do
    heading = fn locale ->
      conn
      |> get(~p"/privacy-policy?#{[locale: locale]}")
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query(".privacy-policy h1")
      |> LazyHTML.text()
      |> String.trim()
    end

    assert heading.("en") == "Privacy Policy for Potok"
    assert heading.("sr") == "Politika privatnosti za Potok"
    assert heading.("sr_Cyrl") == "Политика приватности за Поток"
  end

  test "GET / shows guests the landing page in the selected locale", %{conn: conn} do
    conn = get(conn, ~p"/?locale=sr_Cyrl")

    assert get_session(conn, :locale) == "sr_Cyrl"

    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query(document, "html[lang='sr-Cyrl']")) == 1
    assert Enum.count(LazyHTML.query(document, "#landing-hero")) == 1
  end
end
