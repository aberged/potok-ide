defmodule PotokIde.PlainTextTest do
  use ExUnit.Case, async: true

  alias PotokIde.PlainText

  defp excerpt(text, format), do: PlainText.excerpt(text, format, 200)

  describe "excerpt/3 with a heading" do
    test "ends a markdown heading before the text after it" do
      assert excerpt("# Dobro došli\n\nDogovaramo akcije", :markdown) ==
               "Dobro došli. Dogovaramo akcije"
    end

    test "ends an html heading before the text after it" do
      assert excerpt("<h1>Dobro <b>došli</b> </h1>\n<p>Dogovaramo akcije</p>", :html) ==
               "Dobro došli. Dogovaramo akcije"
    end

    test "keeps the punctuation a heading has" do
      assert excerpt("## Ko smo?\nGrupa komšija", :markdown) == "Ko smo? Grupa komšija"
      assert excerpt("<h2>Pravila:</h2><p>Budi fin</p>", :html) == "Pravila: Budi fin"
    end

    test "adds nothing when no text follows the heading" do
      assert excerpt("# Samo naslov\n\n", :markdown) == "Samo naslov"
      assert excerpt("# Sa slikom\n![](http://x/y.png)", :markdown) == "Sa slikom"
      assert excerpt("<h1>Samo naslov</h1><p> </p>", :html) == "Samo naslov"
    end

    test "ends every heading of a row" do
      assert excerpt("# Prvi\n## Drugi\nTekst", :markdown) == "Prvi. Drugi. Tekst"
    end

    test "reads through markdown inside the heading and Windows line ends" do
      assert excerpt("# **Važno**\r\n\r\nTekst", :markdown) == "Važno. Tekst"
    end

    test "an empty heading adds nothing" do
      assert excerpt("<h1> </h1><p>Tekst</p>", :html) == "Tekst"
    end

    test "leaves other blocks and hashes alone" do
      assert excerpt("Prvi red\nDrugi red", :markdown) == "Prvi red Drugi red"
      assert excerpt("<p>Prvi</p><p>Drugi</p>", :html) == "Prvi Drugi"
      assert excerpt("#hashtag\ni tekst", :markdown) == "#hashtag i tekst"
    end

    test "counts the added stop in the length" do
      assert PlainText.excerpt("# Naslov\nTekst", :markdown, 9) == "Naslov.…"
    end
  end
end
