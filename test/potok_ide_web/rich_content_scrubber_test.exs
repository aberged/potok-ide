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
end
