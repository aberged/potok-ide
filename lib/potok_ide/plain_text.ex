defmodule PotokIde.PlainText do
  @moduledoc """
  Markdown or html as one line of plain text, for the places that show no
  formatting: reply quotes, thread names and the cards of shared links.
  """

  alias PotokIde.UTF8

  # Stands in for the end of a heading until the text is one line and what
  # follows the heading is known. A private use character, so no text has it.
  @heading_end "\u{E000}"
  # Where one piece of text ends and another begins.
  @block_end ~r{<(?:br|hr|/(?:p|div|li|ul|ol|dt|dd|tr|td|th|pre|blockquote|figure|figcaption|article|section|header|footer|aside|nav|main))\b[^>]*>}iu

  @doc """
  `text` as one line: markdown syntax and html tags are stripped, whitespace
  is collapsed, a heading gets a full stop if text follows it, and the text is
  cut to `max_length` characters. nil when no readable text is left.

  With `without_heading: name` a heading that says just `name` is left out, for
  places that show the name right above the text.
  """
  def excerpt(text, format, max_length, opts \\ [])
      when is_binary(text) and is_integer(max_length) and max_length > 1 do
    text
    |> UTF8.replace_invalid()
    |> plain_text(format)
    |> String.replace(~r/\s+/u, " ")
    |> drop_heading(opts[:without_heading])
    |> end_headings()
    |> String.trim()
    |> truncate(max_length)
  end

  @doc "`text` cut to `max_length` characters, the last one an ellipsis; nil for an empty text."
  def truncate("", _max_length), do: nil

  def truncate(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.trim_trailing(String.slice(text, 0, max_length - 1)) <> "…"
    end
  end

  defp plain_text(html, :html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}isu, " ")
    # Block boundaries would otherwise glue neighbouring words together.
    |> String.replace(~r{</h[1-6]\b[^>]*>}iu, @heading_end <> " ")
    |> String.replace(@block_end, " ")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_html_entities()
  end

  defp plain_text(markdown, _format) do
    markdown
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^[ \t]*#+[ \t].*$/mu, "\\0" <> @heading_end)
    |> String.replace(~r/^[ \t]*(?:#+|>+|[-*+]|\d+[.)])[ \t]+/mu, "")
    |> String.replace(~r/\*\*|__|~~|`+/u, "")
  end

  defp drop_heading(text, nil), do: text

  defp drop_heading(text, heading) do
    name = heading |> String.replace(~r/\s+/u, " ") |> String.trim() |> Regex.escape()

    String.replace(text, Regex.compile!("#{name}\\s*\\x{E000}\\s*", "u"), "", global: false)
  end

  # On one line a heading would run into the text after it.
  defp end_headings(text) do
    text
    |> String.replace(
      ~r/(?<=[^\s.!?:;,…\x{E000}])\s*\x{E000}(?=[\s\x{E000}]*[^\s\x{E000}])/u,
      "."
    )
    |> String.replace(@heading_end, "")
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace(["&#39;", "&#x27;", "&apos;"], "'")
    |> String.replace("&amp;", "&")
  end
end
