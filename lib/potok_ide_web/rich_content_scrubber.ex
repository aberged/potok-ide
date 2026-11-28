defmodule PotokIdeWeb.RichContentScrubber do
  @moduledoc """
  `HtmlSanitizeEx` scrubber for Markdown and HTML that members write (group
  descriptions and values outside app groups).

  Builds on `HtmlSanitizeEx.Scrubber.MarkdownHTML` with layout and text-level
  tags, and lets `style` through `HtmlSanitizeEx.Scrubber.CSS`, which drops
  `position`, `z-index`, `transform` and `url()`. `class` and `id` are never
  kept, so content cannot borrow the app's classes or clash with its DOM ids.
  The attributes of Potok's own it keeps are `data-potok-gallery` on a
  `div`, with one of a few looks (`PotokIdeWeb.Galleries`), and
  `data-potok-block` on a `div`, `p` or `figure`, with one of the kinds of
  `blocks/0`: what a site's block editor says each block is, for its theme
  (and `app.css`) to give it a look.

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

  # What a block of a site's article is (`blocks/0` holds the same list).
  Meta.allow_tag_with_this_attribute_values("div", "data-potok-block", [
    "button",
    "buttons",
    "columns",
    "column",
    "cover",
    "callout",
    "wide",
    "full",
    "left",
    "right"
  ])

  Meta.allow_tag_with_this_attribute_values("p", "data-potok-block", [
    "button",
    "callout",
    "wide",
    "full"
  ])

  Meta.allow_tag_with_this_attribute_values("figure", "data-potok-block", [
    "cover",
    "wide",
    "full",
    "left",
    "right"
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

  @doc """
  The kinds of block `data-potok-block` may say, by tag: a button or a row
  of them, columns, a picture with words over it (`cover`), a box that
  stands out (`callout`), and how wide a block stands (`wide`, `full`) or
  which side a picture floats to (`left`, `right`).
  """
  def blocks do
    %{
      "div" => ~w(button buttons columns column cover callout wide full left right),
      "p" => ~w(button callout wide full),
      "figure" => ~w(cover wide full left right)
    }
  end
end
