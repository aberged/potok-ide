defmodule PotokIdeWeb.RichContentScrubberTest do
  use ExUnit.Case, async: true

  alias PotokIdeWeb.RichContentScrubber

  defp scrub(html), do: HtmlSanitizeEx.Scrubber.scrub(html, RichContentScrubber)

  test "strips comments and CDATA sections" do
    assert scrub("<!-- note --><p>text</p>") == "<p>text</p>"
    assert scrub("<p>a<!-- b -->c</p>") == "<p>ac</p>"
    refute scrub("<![CDATA[<script>x</script>]]><p>cd</p>") =~ "<script"
  end

  test "drops scripts and styles with their text, and other tags but not their text" do
    assert scrub("<script>alert(1)</script>after") == "after"
    assert scrub("<style>body{}</style><template>t</template>ok") == "ok"

    assert scrub("<iframe src=\"https://evil.example\"></iframe><unknown-tag>inner</unknown-tag>") ==
             "inner"
  end

  test "keeps allowed tags and attributes only" do
    assert scrub(~S|<a href="javascript:alert(1)" onclick="x()">x</a>|) == "<a>x</a>"

    assert scrub(~S|<a href="https://example.com" target="_blank" class="btn" id="i">l</a>|) ==
             ~S|<a href="https://example.com" target="_blank">l</a>|

    assert scrub(~S|<p onclick="alert(1)" style="color:red;position:fixed">p</p>|) ==
             ~S|<p style="color: red;">p</p>|
  end

  test "keeps a gallery's look and no other data attribute" do
    for look <- PotokIdeWeb.Galleries.looks() do
      assert scrub(~s|<div data-potok-gallery="#{look}"><div>x</div></div>|) ==
               ~s|<div data-potok-gallery="#{look}"><div>x</div></div>|
    end

    assert scrub(~S|<div data-potok-gallery="fixed inset-0">x</div>|) == "<div>x</div>"
    assert scrub(~S|<p data-potok-gallery="slides" data-x="1">x</p>|) == "<p>x</p>"
  end
end
