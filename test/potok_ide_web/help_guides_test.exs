defmodule PotokIdeWeb.HelpGuidesTest do
  @moduledoc """
  The help's pages on how Potok works inside (`PotokIdeWeb.HelpGuides`)
  describe the code, so a change to the code can make them wrong. These hold
  against the code what a test can: the app API, the steps and triggers of a
  process, the calculator of access rights, where each page says its facts
  come from, and the links. The arrows and sentences of the diagrams need a
  reader: `mix potok.sync_reminder` names the page when the code it was drawn
  from changes.
  """
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.AccountsFixtures

  alias Expo.Message
  alias Expo.PO
  alias PotokIde.Processes.{Engine, GraphEdit, Triggers}
  alias PotokIde.Social.GroupRole
  alias PotokIdeWeb.GroupLive.Show.{AppApi, ProcessEditor}
  alias PotokIdeWeb.HelpDoc
  alias PotokIdeWeb.HelpGuides

  @sdk "assets/js/potok_app_sdk.js"

  # Every method of `window.potok` with the calls its source makes on the page.
  defp sdk_methods do
    [_, body] = Regex.run(~r/\nconst potok = \{\n(.*?)\n\}\n/s, File.read!(@sdk))

    # A method starts at two spaces of indent; what follows up to the next one is its source.
    [_before | sources] = Regex.split(~r/^  (?=\w+[:(])/m, body)

    Map.new(sources, fn source ->
      [name] = Regex.run(~r/^\w+/, source)

      {name,
       ~r/call\(\s*"([a-z_]+)"/ |> Regex.scan(source, capture: :all_but_first) |> List.flatten()}
    end)
  end

  defp page_methods, do: Enum.flat_map(HelpGuides.api(), & &1.methods)

  defp in_locale(locale, fun) do
    previous = Gettext.get_locale(PotokIdeWeb.Gettext)
    Gettext.put_locale(PotokIdeWeb.Gettext, locale)

    try do
      fun.()
    after
      Gettext.put_locale(PotokIdeWeb.Gettext, previous)
    end
  end

  defp page(conn, slug, locale \\ "sr") do
    conn
    |> init_test_session(%{locale: locale})
    |> get(~p"/pomoc/#{slug}")
    |> html_response(200)
    |> LazyHTML.from_document()
  end

  defp count(document, selector), do: document |> LazyHTML.query(selector) |> Enum.count()

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp links(document, selector \\ "a[href]"),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  describe "the app API" do
    test "is every method of the SDK, once: a new one has to be placed in a family" do
      sdk = sdk_methods() |> Map.keys() |> Enum.sort()
      shown = page_methods() |> Enum.map(& &1.name) |> Enum.sort()

      assert map_size(sdk_methods()) > 50
      assert shown == Enum.uniq(shown)
      assert sdk -- shown == [], "methods of #{@sdk} that the page does not list"
      assert shown -- sdk == [], "methods the page lists that #{@sdk} no longer has"
    end

    test "names for each method the call it makes on the page" do
      sdk = sdk_methods()

      for %{name: name, call: call} <- page_methods() do
        case call do
          nil -> assert sdk[name] == [], "#{name} makes a call, the page says it only listens"
          call -> assert call in sdk[name], "#{name} does not call #{call}"
        end
      end
    end

    test "marks for a guest what the server lets a guest call, and what a guest's frame keeps" do
      shown = for %{guest?: true, call: call} <- page_methods(), do: call

      assert Enum.sort(shown) ==
               Enum.sort(AppApi.guest_methods() ++ AppApi.local_guest_methods())
    end

    test "gives the limits of the personal memory as the frame of a guest keeps them" do
      app = File.read!("assets/js/app.js")
      [_, keys] = Regex.run(~r/const PERSONAL_MAX_KEYS = (\d+)\n/, app)
      [_, bytes] = Regex.run(~r/const PERSONAL_MAX_BYTES = (\d+)\n/, app)

      assert String.to_integer(keys) == PotokIde.Social.AppProfileStore.max_keys()
      assert String.to_integer(bytes) == PotokIde.Social.AppProfileStore.max_value_bytes()
    end

    test "gives the limit of an app's localStorage as the page keeps it" do
      [_, kb] =
        Regex.run(
          ~r/const APP_FRAME_STORAGE_MAX_CHARS = (\d+) \* 1024\n/,
          File.read!("assets/js/app.js")
        )

      assert HelpGuides.facts().storage_kb == String.to_integer(kb)
    end

    test "shows a chip for every method, and the limits with their numbers", %{conn: conn} do
      document = page(conn, "arhitektura-aplikacije")
      facts = HelpGuides.facts()

      assert count(document, "#hg-api [data-method]") == length(page_methods())

      assert count(document, "#hg-api [data-method] .hg-chip-guest") ==
               length(AppApi.guest_methods() ++ AppApi.local_guest_methods())

      assert count(document, "#hg-limits li") == length(HelpGuides.limits())
      assert text(document, "#hg-limit-sizes b") == "#{facts.value_kb} KB · #{facts.config_kb} KB"
      assert text(document, "#hg-limit-children b") == "#{facts.children}"
    end
  end

  describe "the steps and triggers of a process" do
    test "the page names every step the editor offers, which are all there are", %{conn: conn} do
      kinds = for {kind, _icon, _name, _text, _class} <- ProcessEditor.insert_kinds(), do: kind

      assert Enum.sort(kinds) == Enum.sort(GraphEdit.kinds())

      document = page(conn, "procesi-i-aplikacije")
      assert count(document, "#hg-steps .hg-step-name") == length(GraphEdit.kinds())
    end

    # The first diagram draws four triggers and its note names the other
    # three. When this fails, a trigger was added or dropped: draw it there.
    test "the triggers are the seven the first diagram shows" do
      assert Triggers.all() == ~w(value message subgroup schedule manual process signal)
    end

    test "the example's link leads to a step of the building's tutorial", %{conn: conn} do
      assert "/pomoc/zgrada#kvar" in links(page(conn, "procesi-i-aplikacije"))

      {:ok, tutorial} = HelpDoc.tutorial("zgrada", "sr")
      assert "kvar" in tutorial.ids
      assert "majstor" in tutorial.ids
    end
  end

  describe "the calculator of access rights" do
    # A profile of the example: how many permissions the outcomes give it.
    defp permissions_of(calc, held) do
      says = fn role, permission ->
        cond do
          permission in role.allowed -> "allow"
          permission in role.denied -> "deny"
          true -> "none"
        end
      end

      [_admin, council, tenant, everyone] = calc.roles

      Enum.count(calc.permissions, fn %{key: permission} ->
        index =
          HelpGuides.member_index(
            held,
            says.(council, permission),
            says.(tenant, permission),
            says.(everyone, permission)
          )

        String.at(calc.outcomes.member[permission], index) == "1"
      end)
    end

    test "has every permission, by its name in the roles tab" do
      calc = HelpGuides.calc()

      assert Enum.map(calc.permissions, & &1.key) == GroupRole.permissions()
      assert Enum.all?(calc.permissions, &(&1.label != ""))
    end

    test "its example gives \"everyone\" what the app gives it, and knows only real permissions" do
      [admin, council, tenant, everyone] = HelpGuides.calc().roles

      assert admin.locked and everyone.allow_only
      assert everyone.allowed == GroupRole.default_everyone_permissions()
      assert everyone.denied == []

      for role <- [council, tenant] do
        assert (role.allowed ++ role.denied) -- GroupRole.permissions() == []
        assert role.name != ""
      end
    end

    test "gives the people of the example what the app would" do
      calc = HelpGuides.calc()
      all = length(GroupRole.permissions())

      held = Map.new(calc.presets, &{&1.key, &1.held})

      assert permissions_of(calc, held["ana"]) == all
      assert permissions_of(calc, held["marko"]) == 18
      assert permissions_of(calc, held["jelena"]) == 10
      assert permissions_of(calc, held["petar"]) == 7
      assert permissions_of(calc, held["vesna"]) == 15

      assert Enum.map(calc.presets, &{&1.key, &1.account, &1.member}) |> Enum.take(-2) ==
               [{"neighbor", true, false}, {"guest", false, false}]

      assert calc.start in Map.keys(held)
    end

    test "holds an outcome for every case of a member" do
      calc = HelpGuides.calc()

      for permission <- GroupRole.permissions() do
        marks = calc.outcomes.member[permission]

        # 8 sets of roles, 3 x 3 states of the two roles' fields, 2 of everyone's.
        assert String.length(marks) == 144
        assert String.at(marks, HelpGuides.member_index([], "none", "none", "none")) == "0"
        assert String.at(marks, HelpGuides.member_index([], "none", "none", "allow")) == "1"

        # A denial beats an allowance, of the same role's or another's.
        assert String.at(marks, HelpGuides.member_index(["savet"], "deny", "none", "allow")) ==
                 "0"

        assert String.at(marks, HelpGuides.member_index(["podstanar"], "allow", "deny", "allow")) ==
                 "0"

        # A role says nothing for a profile that does not hold it, and nothing denies admin.
        assert String.at(marks, HelpGuides.member_index([], "deny", "deny", "allow")) == "1"

        assert String.at(
                 marks,
                 HelpGuides.member_index(["admin", "savet"], "deny", "deny", "none")
               ) ==
                 "1"
      end
    end

    test "holds what a profile that is not a member may do: react, read, write" do
      marks = HelpGuides.calc().outcomes.outsider
      at = fn args -> String.slice(marks, apply(HelpGuides, :outsider_index, args), 3) end

      assert String.length(marks) == 3 * 32
      assert at.([true, true, false, true, true]) == "111"
      # A block stops writing and reacting, not reading an open chat.
      assert at.([true, true, true, true, true]) == "010"
      # With the chat closed, only the group's reactions are left.
      assert at.([true, false, false, true, true]) == "100"
      # What "everyone" may not do, a profile that is not a member may not either.
      assert at.([true, true, false, false, false]) == "010"
      # A group that is not public gives nothing, open chat or not.
      assert at.([false, true, false, true, true]) == "000"
    end

    test "is drawn with the example's manifest, for the script to take over", %{conn: conn} do
      document = page(conn, "prava-pristupa")
      [data] = document |> LazyHTML.query("#help-access-calc") |> LazyHTML.attribute("data-calc")
      calc = Jason.decode!(data)

      assert length(calc["permissions"]) == length(GroupRole.permissions())
      assert count(document, "#hg-calc-body tr") == length(GroupRole.permissions())
      assert count(document, "#hg-calc-presets button[data-preset]") == length(calc["presets"])
      assert count(document, "#hg-calc-presets button[aria-pressed=true]") == 1

      for role <- calc["roles"] do
        assert count(document, "#hg-calc-role-#{role["key"]}") == 1
        assert count(document, "#hg-calc-th-#{role["key"]}") == 1
      end

      for id <- ~w(account member public openchat blocked summary reset) do
        assert count(document, "#hg-calc-#{id}") == 1, id
      end
    end

    test "its script is installed" do
      assert File.read!("assets/js/app.js") =~
               ~s(import { installHelpAccess } from "./help_access")

      assert File.read!("assets/js/app.js") =~ ~s("DOMContentLoaded", installHelpAccess)
    end
  end

  describe "where the pages say their facts come from" do
    # Too busy to follow: every feature changes them.
    @unwatched ~w(lib/potok_ide/social/group.ex lib/potok_ide/social.ex)

    test "is there, and followed by the reminder" do
      for guide <- HelpGuides.guides() do
        for path <- guide.sources ++ guide.watch do
          assert File.exists?(path), "#{guide.slug} names #{path}, which is not there"
        end

        for path <- guide.sources -- @unwatched do
          assert String.starts_with?(path, guide.watch),
                 "#{guide.slug} names #{path}, which the reminder does not follow"
        end
      end
    end

    test "is listed on each page", %{conn: conn} do
      for guide <- HelpGuides.guides() do
        document = page(conn, guide.slug)

        assert count(document, "##{guide.id}-sources .hg-source-list code") ==
                 length(guide.sources)
      end
    end
  end

  describe "the pages" do
    test "are under the help, apart from its tutorials" do
      assert HelpGuides.slugs() ==
               ~w(procesi-i-aplikacije arhitektura-aplikacije prava-pristupa)

      assert HelpGuides.slugs() -- HelpDoc.tutorial_slugs() == HelpGuides.slugs()
      assert HelpGuides.guide("zgrada") == :error
    end

    test "each has its title, its diagrams, a way back and the other two", %{conn: conn} do
      for guide <- HelpGuides.guides() do
        document = page(conn, guide.slug)

        {:ok, in_serbian} = in_locale("sr", fn -> HelpGuides.guide(guide.slug) end)
        assert text(document, "##{guide.id}-top h1") == in_serbian.title
        assert count(document, "##{guide.id}-help-link[href='/pomoc']") == 1
        assert count(document, "##{guide.id} figure.hg-fig svg[role=img][aria-label]") == 3
        assert count(document, "#guest-about-link") == 1

        for other <- HelpGuides.slugs() -- [guide.slug] do
          assert count(document, "##{guide.id}-other-#{other}[href='/pomoc/#{other}']") == 1
        end

        ids = document |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
        assert ids == Enum.uniq(ids), "an id repeats on #{guide.slug}"

        # Every arrow has its head.
        heads = document |> LazyHTML.query("[marker-end]") |> LazyHTML.attribute("marker-end")
        assert heads != []

        for "url(#" <> head <- Enum.uniq(heads) do
          assert count(document, "##{String.trim_trailing(head, ")")}") == 1, head
        end
      end
    end

    test "are in Cyrillic, with the code in Latin, and in English", %{conn: conn} do
      for guide <- HelpGuides.guides() do
        cyrillic = page(conn, guide.slug, "sr_Cyrl")

        # Tag by tag: a chip's name and its mark are two words, not one.
        words =
          cyrillic
          |> LazyHTML.query("##{guide.id}")
          |> LazyHTML.to_html()
          |> String.replace(~r/<[^>]+>/, " ")

        assert text(cyrillic, "##{guide.id}-top h1") =~ ~r/\p{Cyrillic}/u
        refute words =~ ~r/\p{Cyrillic}[a-zA-Z]|[a-zA-Z]\p{Cyrillic}/u

        english = page(conn, guide.slug, "en")
        {:ok, in_english} = in_locale("en", fn -> HelpGuides.guide(guide.slug) end)
        assert text(english, "##{guide.id}-top h1") == in_english.title
        assert in_english.title != text(cyrillic, "##{guide.id}-top h1")
      end

      assert text(page(conn, "arhitektura-aplikacije", "sr_Cyrl"), "#hg-fig-call") =~
               "hook GroupAppFrame"
    end

    test "lead accounts that are logged in back to the app", %{conn: conn} do
      document =
        conn
        |> log_in_account(account_fixture())
        |> get(~p"/pomoc/prava-pristupa")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert count(document, "#guest-header #guide-access-back-link[href='/groups']") == 1
      assert count(document, "#guest-about-link") == 0
    end

    test "are also under /help", %{conn: conn} do
      assert conn |> get(~p"/help/prava-pristupa") |> redirected_to() == ~p"/pomoc/prava-pristupa"
    end

    test "the help page leads to each of them, in every language" do
      for locale <- HelpDoc.locales() do
        hrefs = HelpDoc.get(locale).html |> LazyHTML.from_fragment() |> links()

        for slug <- HelpGuides.slugs() do
          assert "/pomoc/#{slug}" in hrefs, "the help page (#{locale}) does not lead to #{slug}"
        end
      end
    end
  end

  describe "the words" do
    test "split into text, code, links and terms" do
      assert HelpGuides.parts("A <b>thread</b> uses `Access` (<a1>steps 9 and 10</a1>).") == [
               {:text, "A "},
               {:strong, "thread"},
               {:text, " uses "},
               {:code, "Access"},
               {:text, " ("},
               {:link, "a1", "steps 9 and 10"},
               {:text, ")."}
             ]

      assert HelpGuides.plain("Mleko (`potok-mleko`), <b>an app</b>") ==
               "Mleko (potok-mleko), an app"
    end

    test "the Serbian of the pages is complete" do
      %{messages: messages} = PO.parse_file!("priv/gettext/sr/LC_MESSAGES/help_guides.po")

      assert length(messages) > 400

      for %Message.Singular{} = message <- messages do
        assert IO.iodata_to_binary(message.msgstr) != "", inspect(message.msgid)
        refute Message.has_flag?(message, "fuzzy"), inspect(message.msgid)
      end
    end

    test "say thousands as the language does" do
      steps = Integer.to_string(Engine.max_steps())

      for {locale, separator} <- [{"sr", "."}, {"sr_Cyrl", "."}, {"en", ","}] do
        shown = in_locale(locale, fn -> HelpGuides.facts().max_steps end)

        assert String.replace(shown, separator, "") == steps
        assert shown =~ ~r/^\d{1,3}(\D\d{3})*$/
      end
    end
  end
end
