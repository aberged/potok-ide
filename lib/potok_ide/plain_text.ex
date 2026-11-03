defmodule PotokIde.PlainText do
  @moduledoc """
  Markdown or html as one line of plain text, for the places that show no
  formatting: reply quotes, thread names and the cards of shared links.
  """

  alias PotokIde.UTF8

  @doc """
  `text` as one line: markdown syntax and html tags are stripped, whitespace
  is collapsed and the text is cut to `max_length` characters. nil when no
  readable text is left.
  """
  def excerpt(text, format, max_length)
      when is_binary(text) and is_integer(max_length) and max_length > 1 do
    text
    |> UTF8.replace_invalid()
    |> plain_text(format)
    |> String.replace(~r/\s+/u, " ")
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
    |> String.replace(~r{<(?:br|/p|/div|/li|/h[1-6]|/tr|/blockquote)\b[^>]*>}iu, " ")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_html_entities()
  end

  defp plain_text(markdown, _format) do
    markdown
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^[ \t]*(?:#+|>+|[-*+]|\d+[.)])[ \t]+/mu, "")
    |> String.replace(~r/\*\*|__|~~|`+/u, "")
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
