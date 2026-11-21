defmodule PotokIdeWeb.PostTemplates.CustomTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.GroupTemplate
  alias PotokIdeWeb.PostTemplates.Custom

  defp template(html, fields) do
    %GroupTemplate{id: 7, name: "Vest", rev: 2, html: html, fields: fields}
  end

  defp field(key, kind, extra \\ %{}) do
    Map.merge(
      %{
        "key" => key,
        "label" => String.capitalize(key),
        "kind" => kind,
        "required" => false,
        "hint" => "",
        "options" => []
      },
      extra
    )
  end

  test "writes each field's text, escaped" do
    t = template(~s(<h2 title="{{naslov}}">{{naslov}}</h2>), [field("naslov", "text")])

    assert Custom.render(t, %{"naslov" => ~s(<b>"a" & 'b'</b>)}) ==
             ~s(<h2 title="&lt;b&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/b&gt;">&lt;b&gt;&quot;a&quot; &amp; &#39;b&#39;&lt;/b&gt;</h2>)
  end

  test "turns no field into markup" do
    hostile = "<img src=x onerror=alert(1)>"

    fields = for kind <- ~w(text textarea url image video), do: field(kind, kind)

    html =
      Enum.map_join(fields, fn %{"key" => key} ->
        "<p>{{#{key}}}{{#{key}|inline}}{{#{key}|paragraphs}}</p><a href=\"{{#{key}|url}}\">x</a><img src=\"{{#{key}|image}}\"><video src=\"{{#{key}|video}}\"></video>"
      end)

    t = template(html, fields)
    rendered = Custom.render(t, Map.new(fields, &{&1["key"], hostile}))

    refute rendered =~ "<img src=x"
    refute rendered =~ ~r/<[^>]*onerror/
  end

  test "lets addresses through only by their filters" do
    t =
      template(
        ~s(<a href="{{link|url}}">l</a><img src="{{slika|image}}"><video src="{{video|video}}"></video>),
        [field("link", "url"), field("slika", "image"), field("video", "video")]
      )

    assert Custom.render(t, %{
             "link" => "example.com/a",
             "slika" => "javascript:alert(1)",
             "video" => "https://a.test/v.mp4"
           }) ==
             ~s(<a href="https://example.com/a">l</a><img src=""><video src="https://a.test/v.mp4"></video>)
  end

  test "repeats a list's section per row, and shows the empty one when it is" do
    t =
      template(
        "{{#stavke}}<li>{{.|inline}}</li>{{/stavke}}{{^stavke}}<p>prazno</p>{{/stavke}}{{#slike}}<img src=\"{{picture|image}}\" alt=\"{{caption}}\">{{/slike}}",
        [field("stavke", "items"), field("slike", "pictures")]
      )

    assert Custom.render(t, %{
             "stavke" => ["**prva**", " ", "druga"],
             "slike" => ["javascript:x", "https://a.test/1.jpg"],
             "slike_captions" => ["loša", "Prva"]
           }) ==
             ~s(<li><strong>prva</strong></li><li>druga</li><img src="https://a.test/1.jpg" alt="Prva">)

    assert Custom.render(t, %{}) == "<p>prazno</p>"
  end

  test "spells a date, and leaves what is no date as it is" do
    t = template("{{dan|date}}", [field("dan", "date")])
    assert Custom.render(t, %{"dan" => "2026-11-14"}) =~ "14"
    assert Custom.render(t, %{"dan" => "sutra"}) == "sutra"
  end

  test "names a post by its first required text, and cards it by its first longer text" do
    t =
      template("", [
        field("podnaslov", "text"),
        field("naslov", "text", %{"required" => true}),
        field("uvod", "textarea")
      ])

    assert Custom.name(t, %{"naslov" => " Most "}) == "Most"
    assert Custom.name(t, %{}) == "Vest"
    assert Custom.card(t, %{"uvod" => "**Kratko** o mostu."}) == "Kratko o mostu."
    assert Custom.missing_fields(t, %{}) == ["Naslov"]
  end

  test "its thumbnail goes through the sanitizer, and says what the sanitizer drops" do
    t =
      template(
        ~s(<div style="position: absolute; color: #111111;" class="x"><iframe src="https://a.test"></iframe>{{naslov}}</div>),
        [field("naslov", "text")]
      )

    refute Custom.thumbnail(t) =~ "iframe"
    refute Custom.thumbnail(t) =~ "position"

    dropped = Custom.dropped(t)
    assert {:tag, "<iframe>"} in dropped
    assert {:attribute, "div class"} in dropped
    assert {:style, "position:absolute"} in dropped
    refute {:style, "color:#111111"} in dropped
  end

  test "knows its id in a post" do
    assert Custom.id(template("", [])) == "custom:7"
    assert Custom.template_id("custom:7") == 7
    assert Custom.template_id("custom:x") == nil
    assert Custom.template_id("article") == nil
  end
end
