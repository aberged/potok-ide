defmodule PotokIdeWeb.GalleriesTest do
  use ExUnit.Case, async: true

  alias PotokIdeWeb.Galleries
  alias PotokIdeWeb.GroupLive.Show.Components

  defp gallery(look, slides),
    do: ~s|<div data-potok-gallery="#{look}"><div>#{slides}</div></div>|

  defp figure(n), do: ~s|<figure><img src="https://a.test/#{n}.jpg" alt="#{n}"></figure>|

  defp tree(html), do: html |> LazyHTML.from_fragment()

  test "leaves HTML without a gallery as it was" do
    html = ~S|<p>Tekst <img src="https://a.test/1.jpg" alt=""></p>|

    assert Galleries.decorate(html) == html
    assert Galleries.decorate({:safe, html}) == {:safe, html}
  end

  test "gives a gallery its strip, counters, lazy pictures and buttons" do
    html = Galleries.decorate(gallery("cards", figure(1) <> figure(2) <> figure(3)))
    doc = tree(html)

    assert Enum.count(LazyHTML.query(doc, ~s|[data-potok-gallery="cards"][role="region"]|)) == 1
    assert Enum.count(LazyHTML.query(doc, "[data-gallery-strip][tabindex='0'] > figure")) == 3

    assert doc |> LazyHTML.query("[data-gallery-count]") |> Enum.map(&LazyHTML.text/1) ==
             ["1 / 3", "2 / 3", "3 / 3"]

    assert Enum.count(LazyHTML.query(doc, "img[loading='lazy']")) == 3

    assert doc
           |> LazyHTML.query("button[data-gallery-step]")
           |> LazyHTML.attribute("data-gallery-step") ==
             ["-1", "1"]
  end

  test "a gallery written by hand may hold its pictures directly" do
    doc =
      tree(
        Galleries.decorate(~s|<div data-potok-gallery="slides">#{figure(1)}#{figure(2)}</div>|)
      )

    assert Enum.count(LazyHTML.query(doc, "[data-gallery-strip] > figure")) == 2
  end

  test "one picture needs no buttons or counter" do
    doc = tree(Galleries.decorate(gallery("cinema", figure(1))))

    assert Enum.empty?(LazyHTML.query(doc, "button"))
    assert Enum.empty?(LazyHTML.query(doc, "[data-gallery-count]"))
  end

  test "a description shows it so, after the sanitizer" do
    group = %PotokIde.Social.Group{
      id: 1,
      description: gallery("polaroid", figure(1) <> figure(2)) <> "<script>x()</script>",
      description_format: :html
    }

    doc = tree(Components.description_html(group))

    assert Enum.count(LazyHTML.query(doc, ~s|[data-potok-gallery="polaroid"] button|)) == 2
    assert Enum.empty?(LazyHTML.query(doc, "script"))
  end
end
