defmodule PotokIdeWeb.RichContentScrubber do
  @moduledoc """
  `HtmlSanitizeEx` scrubber for Markdown and HTML that members write (group
  descriptions and values outside app groups).

  Builds on `HtmlSanitizeEx.Scrubber.MarkdownHTML` with layout and text-level
  tags, and lets `style` through `HtmlSanitizeEx.Scrubber.CSS`, which drops
  `position`, `z-index`, `transform` and `url()`. `class` and `id` are never
  kept, so content cannot borrow the app's classes or clash with its DOM ids.
  The one attribute of Potok's own it keeps is `data-potok-gallery` on a
  `div`, with one of a few looks (`PotokIdeWeb.Galleries`).

  The `Meta` macros need literal tag lists. `use HtmlSanitizeEx` removes
  CDATA sections and strips every tag and attribute not allowed here.
  """

  use HtmlSanitizeEx

  alias HtmlSanitizeEx.Scrubber.Meta

  @valid_schemes ["http", "https", "mailto"]

  # `use` makes `scrub/1` overridable, and the clauses below replace its
  # comment clause, so comments are stripped here again. Without this a
  # comment in member content crashes the scrubber.
  Meta.strip_comments()

  Meta.allow_tags_with_style_attributes([
    "abbr",
    "article",
    "b",
    "blockquote",
    "caption",
    "code",
    "dd",
    "del",
    "details",
    "div",
    "dl",
    "dt",
    "em",
    "figcaption",
    "figure",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "i",
    "kbd",
    "li",
    "mark",
    "ol",
    "p",
    "pre",
    "s",
    "section",
    "small",
    "span",
    "strong",
    "sub",
    "summary",
    "sup",
    "table",
    "tbody",
    "td",
    "th",
    "thead",
    "tr",
    "u",
    "ul"
  ])

  Meta.allow_tag_with_uri_attributes("a", ["href"], @valid_schemes)
  Meta.allow_tag_with_this_attribute_values("a", "target", ["_blank"])
  Meta.allow_tag_with_this_attribute_values("a", "rel", ["noopener", "noreferrer"])
  Meta.allow_tag_with_these_attributes("a", ["name", "title"])

  Meta.allow_tag_with_uri_attributes("img", ["src"], @valid_schemes)
  Meta.allow_tag_with_these_attributes("img", ["width", "height", "title", "alt"])

  # A video plays in place, with its controls, never by itself: no autoplay,
  # and its file only from the web.
  Meta.allow_tag_with_uri_attributes("video", ["src", "poster"], ["http", "https"])
  Meta.allow_tag_with_this_attribute_values("video", "preload", ["none", "metadata"])

  Meta.allow_tag_with_these_attributes("video", [
    "controls",
    "playsinline",
    "width",
    "height",
    "title"
  ])

  # A gallery and its look; `PotokIdeWeb.Galleries.looks/0` holds the same.
  Meta.allow_tag_with_this_attribute_values("div", "data-potok-gallery", [
    "slides",
    "cards",
    "cinema",
    "polaroid"
  ])

  Meta.allow_tag_with_these_attributes("abbr", ["title"])
  Meta.allow_tag_with_these_attributes("details", ["open"])
  Meta.allow_tag_with_these_attributes("td", ["colspan", "rowspan"])
  Meta.allow_tag_with_these_attributes("th", ["colspan", "rowspan"])

  Meta.allow_tags_and_scrub_their_attributes([
    "article",
    "b",
    "blockquote",
    "br",
    "caption",
    "code",
    "dd",
    "del",
    "div",
    "dl",
    "dt",
    "em",
    "figcaption",
    "figure",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "hr",
    "i",
    "kbd",
    "li",
    "mark",
    "ol",
    "p",
    "pre",
    "s",
    "section",
    "small",
    "span",
    "strong",
    "sub",
    "summary",
    "sup",
    "table",
    "tbody",
    "thead",
    "tr",
    "u",
    "ul"
  ])

  # Other stripped tags keep their text; the text of these is code or metadata.
  def scrub({tag, _attributes, _children})
      when tag in ["script", "style", "template", "noscript", "title"],
      do: ""
end
