defmodule PotokIdeWeb.PostTemplates.PostTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.Group
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.PostTemplates.Post

  # What FeedCreator made of the same fields (`feed_creator_posts.ts`).
  @fixture "test/support/fixtures/feed_creator_posts.json"
           |> File.read!()
           |> Jason.decode!()

  setup do
    Gettext.put_locale(PotokIdeWeb.Gettext, "sr")
    :ok
  end

  describe "the hash" do
    test "matches FeedCreator's on the values it was checked with" do
      assert Post.hash("") == "811c9dc5"
      assert Post.hash("a") == "e40c292c"
      assert Post.hash("č") == "080aced8"
      assert Post.hash("🌊") == "10556fdd"
    end

    test "ignores line endings and outer spaces" do
      assert Post.hash("a\r\nb") == "28e4c710"
      assert Post.hash("a\nb") == "28e4c710"
      assert Post.hash(" \n a\nb \n") == "28e4c710"
    end
  end

  describe "against FeedCreator" do
    for {post, index} <- Enum.with_index(@fixture["posts"]) do
      @post post
      test "writes the same #{post["template"]} (#{index})" do
        %{"template" => template, "fields" => fields, "html" => html, "hash" => hash} = @post

        assert Post.html(template, fields) == html
        assert Post.hash(html) == hash
      end

      test "opens #{post["template"]} (#{index})" do
        %{"template" => template, "fields" => fields, "description" => description} = @post

        assert Post.decode(description) == {:post, %{template: template, fields: fields}}
      end

      test "gives #{post["template"]} (#{index}) a form to come back to" do
        %{"template" => template, "fields" => fields} = @post

        assert Post.decode(Post.encode(template, fields)) ==
                 {:post, %{template: template, fields: fields}}
      end
    end

    test "has the same samples" do
      for %{id: id, sample: sample} <- PostTemplates.templates() do
        expected = @fixture["samples"][id]

        if id == PostTemplates.free_text(),
          do: assert(sample["source"] == expected["source"]),
          else: assert(sample == expected)
      end
    end
  end

  describe "decode/1" do
    test "reads text changed by hand as changed, with what it was made from" do
      description = Post.encode("quote", %{"quote" => "Citat"})

      assert {:changed, %{template: "quote", fields: %{"quote" => "Citat"}}} =
               Post.decode(description <> "<p>dodato</p>")
    end

    test "does not mind the line endings a form sends back" do
      description = Post.encode("article", %{"title" => "Naslov", "body" => "a\n\nb"})

      assert {:post, _post} = Post.decode(String.replace(description, "\n", "\r\n"))
    end

    test "reads everything else as free" do
      for description <- [
            nil,
            "",
            "**markdown**",
            "<!--potok-post nije json-->\n<p>a</p>",
            ~s|<!--potok-post {"v":1,"template":"nepoznat","fields":{},"hash":"0"}-->\n<p>a</p>|,
            ~s|<!--potok-post {"v":1,"template":"text","fields":{},"hash":"0"}-->\n<p>a</p>|,
            ~s|<!--potok-post {"v":1,"template":"quote","fields":[],"hash":"0"}-->\n<p>a</p>|
          ] do
        assert Post.decode(description) == :free
      end
    end

    test "survives fields a form never wrote" do
      fields = %{"title" => 7, "items" => [1, "a", nil], "level" => %{}, "image" => ["x"]}

      for %{id: id} <- PostTemplates.templates(), PostTemplates.form?(id) do
        assert {:post, _post} = id |> Post.encode(fields) |> Post.decode()
      end
    end

    test "keeps a comment from being closed from inside" do
      description = Post.encode("quote", %{"quote" => "a --> b <!-- c"})

      assert [_comment, "<" <> _html] = String.split(description, "-->\n", parts: 2)
      assert {:post, %{fields: %{"quote" => "a --> b <!-- c"}}} = Post.decode(description)
    end
  end

  describe "what a viewer gets" do
    test "has neither the comment nor the card's tag" do
      html = "article" |> Post.encode(%{"title" => "Naslov", "lead" => "Uvod"}) |> shown()

      refute html =~ "potok-post"
      refute html =~ "<meta"
      assert html =~ "Naslov"
    end

    test "keeps every template's look" do
      for {post, index} <- Enum.with_index(@fixture["posts"]) do
        lost = declarations(post["html"]) -- declarations(shown(post["html"]))

        assert lost == [], "post #{index} lost #{inspect(lost)}"
      end
    end

    test "turns no field into markup" do
      hostile = "<img src=x onerror=alert(1)>"

      for %{id: id, fields: fields} <- PostTemplates.templates(), PostTemplates.form?(id) do
        values =
          Map.new(fields, fn %{key: key, kind: kind} ->
            {key, if(kind == :items, do: [hostile], else: hostile)}
          end)

        html = PostTemplates.render(id, values)

        refute html =~ "<img src=x"
        refute html =~ "<script"
      end
    end
  end

  defp shown(description),
    do: Components.description_html(%Group{description: description, description_format: :html})

  # Every declaration of every style. The sanitizer writes them back with
  # spacing of its own.
  defp declarations(html) do
    ~r/ style="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [style] -> String.split(style, ";", trim: true) end)
    |> Enum.map(&String.replace(&1, " ", ""))
    |> Enum.reject(&(&1 == ""))
  end
end
