defmodule PotokIdeWeb.GroupLive.ComponentsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PotokIdeWeb.GroupLive.Show.Components

  describe "formatted_content/1" do
    test "preserves valid emoji in markdown content" do
      html =
        render_component(&Components.formatted_content/1,
          content: "Hvala za paradajz, bubo ❤️🍅",
          content_format: :markdown
        )

      assert String.valid?(html)
      assert html =~ "❤️🍅"
      refute html =~ "❤️�"
    end

    test "renders malformed utf-8 markdown without crashing" do
      malformed = <<240, 159, 141, 60>>

      html =
        render_component(&Components.formatted_content/1,
          content: malformed,
          content_format: :markdown
        )

      assert String.valid?(html)
      assert html =~ "�"
    end

    test "renders markdown blocks inside the styled wrapper" do
      doc =
        render_component(&Components.formatted_content/1,
          content: "# Naslov\n\n- jedan\n  - dva\n\n~~staro~~\n\n```elixir\nline1\nline2\n```",
          content_format: :markdown
        )
        |> LazyHTML.from_fragment()

      assert count(doc, ".rich-content > h1") == 1
      assert count(doc, ".rich-content > ul > li > ul > li") == 1
      assert count(doc, ".rich-content del") == 1

      assert doc |> LazyHTML.query(".rich-content > pre > code") |> LazyHTML.text() ==
               "line1\nline2"
    end

    test "keeps layout tags and safe inline styles in html content" do
      doc =
        render_component(&Components.formatted_content/1,
          content:
            ~s|<div style="color: red; position: fixed; z-index: 9"><details open><summary>Više</summary><p>H<sub>2</sub>O</p></details></div>|,
          content_format: :html
        )
        |> LazyHTML.from_fragment()

      [style] = doc |> LazyHTML.query(".rich-content > div") |> LazyHTML.attribute("style")

      assert style =~ "color: red"
      refute style =~ "position"
      refute style =~ "z-index"
      assert count(doc, ".rich-content details[open] > summary") == 1
      assert count(doc, ".rich-content sub") == 1
    end

    test "drops classes, ids, handlers, unsafe links and script text from html content" do
      html =
        render_component(&Components.formatted_content/1,
          content:
            ~s|<p class="fixed inset-0" id="group-panel-description" onclick="steal()">x</p>| <>
              ~s|<a href="javascript:steal()">link</a><script>steal()</script><style>body{}</style>|,
          content_format: :html
        )

      doc = LazyHTML.from_fragment(html)

      assert count(doc, ".rich-content > p") == 1
      assert count(doc, "#group-panel-description, .fixed, [onclick], [href]") == 0
      refute html =~ "steal()"
      refute html =~ "body{}"
    end
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()
end
