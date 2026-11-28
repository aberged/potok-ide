defmodule PotokIde.Social.SiteDocTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.SiteDoc

  # What potok-sajt's `encodeDoc` wrote for the same blocks (src/model/blocks.ts,
  # 2026-11-28): everything after the marker, and the hash of the HTML. The app
  # opens the blocks again only while that hash agrees.
  @expected_rest ~s(<meta name="description" content="Zbor je u četvrtak u 18 časova, u Domu kulture. Lipe uz stazu Rasveta Jedan Dva Deca su klupe isprobala. Koncert u 19 časova Radionice Turnir Imaš predlog? Napiši ga ispod."><p>Zbor je u <strong>četvrtak</strong> u 18 časova, u <a href="https://example.org/dom">Domu kulture</a>.</p>\n<h3>Šta sledi</h3>\n<ol><li>Lipe uz stazu</li><li>Rasveta</li></ol>\n<ul><li>Jedan</li><li>Dva</li></ul>\n<blockquote><p>Deca su klupe isprobala.</p><p><small>— Luka &amp; savet</small></p></blockquote>\n<figure data-potok-block="wide"><img src="https://potok.example/pictures/abc.def" alt="Obala &quot;kanala&quot;"><figcaption>Obala <em>kanala</em></figcaption></figure>\n<figure><a href="https://example.org"><img src="/pictures/x" alt=""></a></figure>\n<div data-potok-gallery="polaroid"><div><figure><img src="https://p.example/1" alt="Jedan"><figcaption>Prvi</figcaption></figure><figure><img src="https://p.example/2" alt="Dva"></figure></div></div>\n<p data-potok-block="button"><a href="https://potok.example/pomoc#sajt">Pomoć</a></p>\n<div data-potok-block="buttons"><a href="https://a.example">A</a><a href="mailto:b@example.org">B</a></div>\n<hr>\n<table><thead><tr><th>Klub</th><th>Bodovi</th></tr></thead><tbody><tr><td>FK Topolik</td><td><strong>21</strong></td></tr></tbody></table>\n<div data-potok-block="columns"><div data-potok-block="column"><h4>Subota</h4>\n<p>Koncert u 19 časova</p></div><div data-potok-block="column"><ul><li>Radionice</li><li>Turnir</li></ul></div></div>\n<div data-potok-block="callout"><p>Imaš predlog? Napiši ga ispod.</p></div>\n<figure data-potok-block="cover"><img src="https://p.example/cover" alt="Bina"><figcaption>Leto u parku</figcaption></figure>)
  @expected_hash "585c4ac0"

  @blocks [
    %{
      "type" => "paragraph",
      "text" =>
        ~s(Zbor je u <strong>četvrtak</strong> u 18 časova, u <a href="https://example.org/dom">Domu kulture</a>.)
    },
    %{"type" => "heading", "level" => 3, "text" => "Šta sledi"},
    %{"type" => "list", "ordered" => true, "items" => ["Lipe uz stazu", " Rasveta ", ""]},
    %{"type" => "list", "items" => ["Jedan", "Dva"]},
    %{"type" => "quote", "text" => "Deca su klupe isprobala.", "cite" => "Luka & savet"},
    %{
      "type" => "image",
      "src" => "https://potok.example/pictures/abc.def",
      "alt" => ~s(Obala "kanala"),
      "caption" => "Obala <em>kanala</em>",
      "align" => "wide"
    },
    %{"type" => "image", "src" => "/pictures/x", "link" => "https://example.org"},
    %{
      "type" => "gallery",
      "look" => "polaroid",
      "images" => [
        %{"src" => "https://p.example/1", "alt" => "Jedan", "caption" => "Prvi"},
        %{"src" => "https://p.example/2", "alt" => "Dva", "caption" => ""}
      ]
    },
    %{
      "type" => "buttons",
      "items" => [%{"label" => "Pomoć", "url" => "https://potok.example/pomoc#sajt"}]
    },
    %{
      "type" => "buttons",
      "items" => [
        %{"label" => "A", "url" => "https://a.example"},
        %{"label" => "B", "url" => "mailto:b@example.org"}
      ]
    },
    %{"type" => "separator"},
    %{
      "type" => "table",
      "rows" => [["Klub", "Bodovi"], ["FK Topolik", "<strong>21</strong>"], ["", ""]]
    },
    %{
      "type" => "columns",
      "columns" => [
        [
          %{"type" => "heading", "level" => 4, "text" => "Subota"},
          %{"type" => "paragraph", "text" => "Koncert u 19 časova"}
        ],
        [%{"type" => "list", "items" => ["Radionice", "Turnir"]}]
      ]
    },
    %{"type" => "callout", "text" => "Imaš predlog? Napiši ga ispod."},
    %{
      "type" => "cover",
      "src" => "https://p.example/cover",
      "alt" => "Bina",
      "text" => "Leto u parku"
    }
  ]

  defp split(description) do
    ["<!--potok-site " <> marker, rest] = String.split(description, "-->\n", parts: 2)
    {Jason.decode!(marker), rest}
  end

  test "writes what the Sajt app writes for every kind of block" do
    {marker, rest} = split(SiteDoc.encode("article", "", @blocks))

    assert rest == @expected_rest
    assert marker["hash"] == @expected_hash
    assert marker["v"] == 1 and marker["kind"] == "article" and marker["excerpt"] == ""
  end

  test "the marker keeps whole blocks with ids, those in columns too" do
    {marker, _rest} = split(SiteDoc.encode("article", "", @blocks))
    blocks = marker["blocks"]

    assert Enum.map(blocks, & &1["id"]) ==
             Enum.map(Enum.reject(1..18, &(&1 in 14..16)), &"b#{&1}")

    assert %{"columns" => [[%{"id" => "b14"}, %{"id" => "b15"}], [%{"id" => "b16"}]]} =
             Enum.at(blocks, 12)

    assert %{"align" => "none", "caption" => "", "alt" => "", "link" => "https://example.org"} =
             Enum.at(blocks, 6)

    assert %{"ordered" => false} = Enum.at(blocks, 3)
  end

  test "the marker holds no end of a comment" do
    description = SiteDoc.encode("page", "", [%{"type" => "paragraph", "text" => "a --> b"}])
    [_marker, html] = String.split(description, "-->\n", parts: 2)

    assert html =~ "<p>a --"
    refute description |> String.split("\n") |> hd() |> String.trim_trailing("-->") =~ "-->"
  end

  test "the card is the excerpt, trimmed and escaped" do
    {marker, rest} = split(SiteDoc.encode("page", ~s( Kratko o "nama" ), Enum.take(@blocks, 2)))

    assert rest ==
             ~s(<meta name="description" content="Kratko o &quot;nama&quot;"><p>Zbor je u <strong>četvrtak</strong> u 18 časova, u <a href="https://example.org/dom">Domu kulture</a>.</p>\n<h3>Šta sledi</h3>)

    assert marker["excerpt"] == ~s( Kratko o "nama" )
  end

  test "a long text is cut between words for the card" do
    text =
      "Mesna zajednica Topolik okuplja komšije iz šest ulica između kanala i pruge. Savet bira zbor građana, a sednice saveta su javne i svako može da dođe. U Potoku imamo razgovor zbora, mapu prijava i kalendar događaja, pa piši šta treba popraviti u kraju."

    {_marker, rest} =
      split(SiteDoc.encode("article", "", [%{"type" => "paragraph", "text" => text}]))

    assert rest ==
             ~s(<meta name="description" content="Mesna zajednica Topolik okuplja komšije iz šest ulica između kanala i pruge. Savet bira zbor građana, a sednice saveta su javne i svako može da dođe. U Potoku imamo razgovor zbora, mapu prijava i…"><p>#{text}</p>)
  end

  test "hash/1 ignores line endings and outer spaces" do
    assert SiteDoc.hash("<p>a</p>\n<p>b</p>") == SiteDoc.hash("  <p>a</p>\r\n<p>b</p>\n")
  end
end
