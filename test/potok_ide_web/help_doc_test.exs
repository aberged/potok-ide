defmodule PotokIdeWeb.HelpDocTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.GroupRole
  alias PotokIde.Storage
  alias PotokIdeWeb.HelpDoc
  alias PotokIdeWeb.HelpMarkdown

  @shots Path.expand("../../help_shots/shots.json", __DIR__)

  describe "HelpMarkdown.parse/2" do
    @text """
    <!-- A note for whoever edits this. -->
    # Help

    How it works.

    ## Messages {:#messages}

    Write [to everyone](#roles) or [read more](https://example.com/a?b=1).

    ![Reply with a quote](chat-reply)

    ### Threads {:#threads}

    ![First](one) ![Second](two)

    ## Roles {:#roles}

    | Permission | Who |
    |---|---|
    | Write | Everyone |
    """

    test "keeps the title and lead apart from the text" do
      doc = HelpMarkdown.parse(@text, %{})

      assert doc.title == "Help"
      assert doc.lead == "How it works."
      refute doc.html =~ "How it works."
      refute doc.html =~ "<h1"
      refute doc.html =~ "note for whoever"
    end

    test "gives headings their ids and lists the sections with their subsections" do
      doc = HelpMarkdown.parse(@text, %{})

      assert doc.ids == ~w(messages threads roles)
      assert doc.html =~ ~s(<h2 id="messages">Messages</h2>)

      assert doc.toc == [
               %{
                 id: "messages",
                 title: "Messages",
                 children: [%{id: "threads", title: "Threads", children: []}]
               },
               %{id: "roles", title: "Roles", children: []}
             ]
    end

    test "shows a named picture in a figure with its size and caption" do
      doc = HelpMarkdown.parse(@text, %{"chat-reply" => %{"w" => 390, "h" => 844}})
      document = LazyHTML.from_fragment(doc.html)

      [figure] = document |> LazyHTML.query("figure[data-shot=chat-reply]") |> Enum.to_list()
      assert LazyHTML.attribute(figure, "class") == ["hp-shot"]

      img = LazyHTML.query(figure, "img")
      assert LazyHTML.attribute(img, "src") == ["/images/help/chat-reply.webp"]
      assert LazyHTML.attribute(img, "width") == ["390"]
      assert LazyHTML.attribute(img, "height") == ["844"]
      assert LazyHTML.attribute(img, "loading") == ["lazy"]
      assert LazyHTML.attribute(img, "alt") == [""]
      assert figure |> LazyHTML.query("figcaption") |> LazyHTML.text() == "Reply with a quote"

      assert doc.images == ~w(chat-reply one two)
    end

    test "marks a picture whose size it does not know" do
      document = @text |> HelpMarkdown.parse(%{}) |> Map.fetch!(:html) |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query("figure.hp-missing") |> Enum.count() == 3
    end

    test "puts the pictures of one paragraph side by side" do
      document = @text |> HelpMarkdown.parse(%{}) |> Map.fetch!(:html) |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query(".hp-shots > figure") |> Enum.count() == 2
      assert document |> LazyHTML.query("p figure, p img") |> Enum.count() == 0
    end

    test "opens other sites in a new tab and keeps links inside the page" do
      doc = HelpMarkdown.parse(@text, %{})
      document = LazyHTML.from_fragment(doc.html)

      assert document |> LazyHTML.query("a[href='#roles']:not([target])") |> Enum.count() == 1

      assert document
             |> LazyHTML.query("a[href^='https'][target=_blank][rel~=noopener]")
             |> Enum.count() == 1

      assert doc.anchors == ["roles"]
    end

    test "frames tables without the inline alignment" do
      document = @text |> HelpMarkdown.parse(%{}) |> Map.fetch!(:html) |> LazyHTML.from_fragment()

      assert document |> LazyHTML.query(".or-table.hp-table > table") |> Enum.count() == 1
      assert document |> LazyHTML.query("[style]") |> Enum.count() == 0
    end

    test "escapes HTML written inside a sentence" do
      doc = HelpMarkdown.parse("# T\n\nL.\n\nA <script>alert(1)</script> b.\n", %{})

      assert doc.html =~ "&lt;script&gt;"
      refute doc.html =~ "<script"
    end

    test "refuses what the page cannot show" do
      for {text, message} <- [
            {"Text.\n", "starts with a title"},
            {"# T\n\nL.\n\n<div>raw</div>\n", "raw HTML"},
            {"# T\n\nL.\n\n## No id\n", ~s(needs an id)},
            {"# T\n\nL.\n\nSee ![this](chat-reply) here.\n", "paragraph of its own"},
            {"# T\n\nL.\n\n![Text](Chat_Reply.png)\n", "file name"},
            {"# T\n\nL.\n\n[x](javascript:alert(1))\n", "a link goes to"},
            {"# T\n\nL.\n\n## Bad {:#Bad_Id}\n", "small Latin letters"}
          ] do
        assert_raise ArgumentError, ~r/#{message}/, fn -> HelpMarkdown.parse(text, %{}) end
      end
    end
  end

  describe "the help text" do
    test "is there in every language" do
      assert HelpDoc.locales() == ~w(en sr sr_Cyrl)
    end

    test "has the same sections and pictures in every language, in the same order" do
      sr = HelpDoc.get("sr")

      for locale <- ~w(sr_Cyrl en) do
        doc = HelpDoc.get(locale)
        assert doc.ids == sr.ids, "the sections of #{locale} differ from sr"
        assert doc.images == sr.images, "the pictures of #{locale} differ from sr"
      end
    end

    test "uses each section id once, and its links go to a section" do
      for locale <- HelpDoc.locales() do
        doc = HelpDoc.get(locale)

        assert doc.ids == Enum.uniq(doc.ids), "a section id repeats in #{locale}"
        assert doc.anchors -- doc.ids == [], "a link of #{locale} goes nowhere"
      end
    end

    test "every picture is there, with its size" do
      for name <- HelpDoc.get("sr").images do
        assert File.exists?(Path.join(HelpDoc.images_dir(), "#{name}.webp")), "no #{name}.webp"
        assert %{"w" => _, "h" => _} = HelpDoc.manifest()[name], "#{name} is not in the manifest"
      end
    end

    test "no picture is left over" do
      names = HelpDoc.get("sr").images

      files =
        HelpDoc.images_dir()
        |> Path.join("*.webp")
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".webp"))

      assert files -- names == []
      assert Map.keys(HelpDoc.manifest()) -- names == []
    end

    test "shows the pictures that help_shots takes" do
      taken = @shots |> File.read!() |> Jason.decode!() |> Enum.map(& &1["name"])

      assert Enum.sort(taken) == Enum.sort(Enum.uniq(HelpDoc.get("sr").images))
    end

    test "gives the app's own numbers" do
      permissions = length(GroupRole.permissions())
      files = Storage.max_files()
      size = div(Storage.max_file_size(), 1_000_000)

      for {locale, words} <- [
            {"sr", ~r/\b#{permissions} dozvol/u},
            {"en", ~r/\b#{permissions} permissions/}
          ] do
        assert HelpDoc.get(locale).html =~ words, "#{locale} does not say #{permissions}"
      end

      for locale <- ~w(sr en) do
        html = HelpDoc.get(locale).html
        assert html =~ ~r/\b#{files}\b/
        assert html =~ ~r/\b#{size} MB/
      end
    end
  end
end
