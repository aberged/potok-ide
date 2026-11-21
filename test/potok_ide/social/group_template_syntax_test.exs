defmodule PotokIde.Social.GroupTemplateSyntaxTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.GroupTemplate.Syntax

  @fields [
    %{"key" => "naslov", "kind" => "text"},
    %{"key" => "stavke", "kind" => "items"},
    %{"key" => "slike", "kind" => "pictures"}
  ]

  defp parse(html), do: Syntax.parse(html, @fields)

  test "reads text, fields, filters and sections into a tree" do
    assert {:ok,
            [
              {:text, "<h2>"},
              {:var, "naslov", nil},
              {:text, "</h2>"},
              {:section, "stavke", false, [{:text, "<li>"}, {:var, ".", "inline"}]},
              {:section, "slike", true, [{:text, "bez slika"}]}
            ]} =
             parse(
               "<h2>{{ naslov }}</h2>{{#stavke}}<li>{{.|inline}}{{/stavke}}{{^slike}}bez slika{{/slike}}"
             )
  end

  test "a row's names stand only inside its list's section" do
    assert {:ok, _tree} = parse("{{#slike}}<img src=\"{{picture|image}}\">{{caption}}{{/slike}}")
    assert {:error, message} = parse("{{caption}}")
    assert message =~ "caption"
    assert {:error, _message} = parse("{{.}}")
  end

  test "says what is wrong" do
    assert {:error, message} = parse("{{autor}}")
    assert message =~ "autor"

    assert {:error, message} = parse("{{naslov|velika}}")
    assert message =~ "velika"

    assert {:error, message} = parse("{{#stavke}}<li>")
    assert message =~ "{{/stavke}}"

    assert {:error, _message} = parse("{{#stavke}}{{#slike}}{{/stavke}}{{/slike}}")
    assert {:error, _message} = parse("{{/stavke}}")
    assert {:error, _message} = parse("{{#stavke|inline}}{{/stavke}}")
    assert {:error, _message} = parse("{{ naslov autor }}")

    deep =
      "{{#stavke}}{{#slike}}{{#naslov}}{{#stavke}}x{{/stavke}}{{/naslov}}{{/slike}}{{/stavke}}"

    assert {:error, _message} = parse(deep)
  end

  test "plain HTML is plain text" do
    assert {:ok, [{:text, "<p>bez polja</p>"}]} = parse("<p>bez polja</p>")
    assert {:ok, []} = parse("")
  end
end
