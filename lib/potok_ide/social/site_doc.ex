defmodule PotokIde.Social.SiteDoc do
  @moduledoc """
  An article or a page of a site as the Sajt app writes it into its group's
  description (potok-sajt `encodeDoc` in `src/model/blocks.ts`): its blocks in
  a comment on the first line, the text of its card, and the HTML the blocks
  make, with the hash of that HTML. The hash tells the app nobody changed the
  HTML by hand, so its editor opens the blocks again instead of one block of
  HTML.

  For what Potok writes in the app's name: the seeded example site
  (`PotokIde.Social.SiteExample`) and the world of the help page's pictures.

  The text of a block is inline HTML, as in the app's model: plain words, or
  a few marks (`<strong>`, `<em>`, `<a href="…">`). It goes in as it is, so it
  must already be what the app's `sanitizeInline` would leave: no `>` in the
  words and every mark closed.
  """

  @card_length 200

  @defaults %{
    "paragraph" => %{"text" => ""},
    "heading" => %{"level" => 2, "text" => ""},
    "list" => %{"ordered" => false, "items" => []},
    "quote" => %{"text" => "", "cite" => ""},
    "image" => %{"src" => "", "alt" => "", "caption" => "", "align" => "none", "link" => ""},
    "gallery" => %{"look" => "slides", "images" => []},
    "buttons" => %{"items" => []},
    "separator" => %{},
    "table" => %{"header" => true, "rows" => []},
    "columns" => %{"columns" => []},
    "callout" => %{"text" => ""},
    "cover" => %{"src" => "", "alt" => "", "text" => ""}
  }

  @doc """
  The description of an article (`"article"`) or a page (`"page"`): the
  marker, the card's text (`excerpt`, or the blocks' words when it is empty)
  and the HTML. Each block gets the fields of its type it lacks and an id
  (`b1`, `b2`…, the blocks of columns too).
  """
  def encode(kind, excerpt, blocks) when kind in ["article", "page"] and is_list(blocks) do
    blocks = complete(blocks)
    html = html(blocks)
    card = cut(if String.trim(excerpt) == "", do: text(blocks), else: String.trim(excerpt))
    meta = if card == "", do: "", else: ~s(<meta name="description" content="#{attr(card)}">)

    marker =
      [v: 1, kind: kind, blocks: blocks, excerpt: excerpt, hash: hash(html)]
      |> Jason.OrderedObject.new()
      |> Jason.encode!()
      |> String.replace("<", "\\u003c")
      |> String.replace(">", "\\u003e")
      |> String.replace("--", "-\\u002d")

    "<!--potok-site #{marker}-->\n#{meta}#{html}"
  end

  @doc """
  The blocks with the fields of their type they lack and ids, numbered in the
  order they stand, the blocks of a column included.
  """
  def complete(blocks) when is_list(blocks) do
    {blocks, _next} = number(blocks, 1)
    blocks
  end

  defp number(blocks, next) do
    Enum.map_reduce(blocks, next, fn %{"type" => type} = block, next ->
      block = Map.merge(Map.fetch!(@defaults, type), block) |> Map.put("id", "b#{next}")

      case block do
        %{"type" => "columns", "columns" => columns} ->
          {columns, next} = Enum.map_reduce(columns, next + 1, &number/2)
          {Map.put(block, "columns", columns), next}

        block ->
          {block, next + 1}
      end
    end)
  end

  @doc "The HTML of the blocks, one after another (potok-sajt `renderBlocks`)."
  def html(blocks) when is_list(blocks) do
    blocks |> Enum.map(&block_html/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp block_html(%{"type" => "paragraph", "text" => text}), do: wrap("p", text)

  defp block_html(%{"type" => "heading", "level" => level, "text" => text})
       when level in [2, 3, 4],
       do: wrap("h#{level}", text)

  defp block_html(%{"type" => "list", "ordered" => ordered, "items" => items}) do
    tag = if ordered, do: "ol", else: "ul"

    case Enum.reject(items, &(String.trim(&1) == "")) do
      [] -> ""
      items -> "<#{tag}>" <> Enum.map_join(items, &"<li>#{String.trim(&1)}</li>") <> "</#{tag}>"
    end
  end

  defp block_html(%{"type" => "quote", "text" => text, "cite" => cite}) do
    case String.trim(text) do
      "" ->
        ""

      text ->
        cite = String.trim(cite)
        cited = if cite == "", do: "", else: "<p><small>— #{escape(cite)}</small></p>"
        "<blockquote><p>#{text}</p>#{cited}</blockquote>"
    end
  end

  defp block_html(%{"type" => "image", "align" => align, "link" => link} = block) do
    case picture(block["src"], block["alt"]) do
      "" ->
        ""

      img ->
        inner = if web?(link), do: ~s(<a href="#{attr(String.trim(link))}">#{img}</a>), else: img
        kind = if align == "none", do: "", else: ~s( data-potok-block="#{align}")
        "<figure#{kind}>#{inner}#{caption(block["caption"])}</figure>"
    end
  end

  defp block_html(%{"type" => "gallery", "look" => look, "images" => images}) do
    figures =
      for image <- images, (img = picture(image["src"], image["alt"] || "")) != "" do
        "<figure>#{img}#{caption(image["caption"] || "")}</figure>"
      end

    if figures == [],
      do: "",
      else: ~s(<div data-potok-gallery="#{look}"><div>#{Enum.join(figures)}</div></div>)
  end

  defp block_html(%{"type" => "buttons", "items" => items}) do
    case Enum.map(items, &button/1) |> Enum.reject(&(&1 == "")) do
      [] -> ""
      [link] -> ~s(<p data-potok-block="button">#{link}</p>)
      links -> ~s(<div data-potok-block="buttons">#{Enum.join(links)}</div>)
    end
  end

  defp block_html(%{"type" => "separator"}), do: "<hr>"

  defp block_html(%{"type" => "table", "header" => header, "rows" => rows}) do
    case Enum.filter(rows, fn row -> Enum.any?(row, &(inline_text(&1) != "")) end) do
      [] ->
        ""

      [first | rest] = rows ->
        cells = fn row, tag -> Enum.map_join(row, &"<#{tag}>#{String.trim(&1)}</#{tag}>") end
        head = if header, do: "<thead><tr>#{cells.(first, "th")}</tr></thead>", else: ""
        body_rows = if header, do: rest, else: rows
        body = Enum.map_join(body_rows, &"<tr>#{cells.(&1, "td")}</tr>")
        body = if body == "", do: "", else: "<tbody>#{body}</tbody>"
        "<table>#{head}#{body}</table>"
    end
  end

  defp block_html(%{"type" => "columns", "columns" => columns}) do
    inner = Enum.map(columns, &html/1)

    if Enum.all?(inner, &(&1 == "")),
      do: "",
      else:
        ~s(<div data-potok-block="columns">) <>
          Enum.map_join(inner, &~s(<div data-potok-block="column">#{&1}</div>)) <> "</div>"
  end

  defp block_html(%{"type" => "callout", "text" => text}) do
    case String.trim(text) do
      "" -> ""
      text -> ~s(<div data-potok-block="callout"><p>#{text}</p></div>)
    end
  end

  defp block_html(%{"type" => "cover", "text" => text} = block) do
    case picture(block["src"], block["alt"]) do
      "" ->
        ""

      img ->
        text = String.trim(text)
        caption = if text == "", do: "", else: "<figcaption>#{escape(text)}</figcaption>"
        ~s(<figure data-potok-block="cover">#{img}#{caption}</figure>)
    end
  end

  defp wrap(tag, text) do
    case String.trim(text) do
      "" -> ""
      text -> "<#{tag}>#{text}</#{tag}>"
    end
  end

  defp picture(src, alt) do
    src = String.trim(src || "")

    if web?(src) or (String.starts_with?(src, "/") and not String.starts_with?(src, "//")),
      do: ~s(<img src="#{attr(src)}" alt="#{attr(alt || "")}">),
      else: ""
  end

  defp caption(text) do
    case String.trim(text) do
      "" -> ""
      text -> "<figcaption>#{text}</figcaption>"
    end
  end

  defp button(%{"label" => label, "url" => url}) do
    label = String.trim(label)
    url = String.trim(url)

    if web?(url) and label != "",
      do: ~s(<a href="#{attr(url)}">#{escape(label)}</a>),
      else: ""
  end

  defp web?(url),
    do: is_binary(url) and Regex.match?(~r/^(https?:\/\/|mailto:)/i, String.trim(url))

  @doc "The words of the blocks, for a card (potok-sajt `blocksText`)."
  def text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => type, "text" => text} when type in ["paragraph", "callout", "quote"] ->
        [inline_text(text)]

      %{"type" => "list", "items" => items} ->
        Enum.map(items, &inline_text/1)

      %{"type" => "columns", "columns" => columns} ->
        Enum.map(columns, &text/1)

      _other ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp inline_text(html) do
    html
    |> String.replace("<br>", " ")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # At most 200 characters, cut between words (potok-sajt `cut`).
  defp cut(text) do
    if String.length(text) <= @card_length do
      text
    else
      short = String.slice(text, 0, @card_length - 1)

      short =
        case :binary.matches(short, " ") |> List.last() do
          {at, _} when at > 0 ->
            space = short |> binary_part(0, at) |> String.length()
            if space > @card_length / 2, do: String.slice(short, 0, space), else: short

          _none ->
            short
        end

      String.trim_trailing(short) <> "…"
    end
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp attr(text), do: text |> escape() |> String.replace("\"", "&quot;")

  @doc """
  FNV-1a over the characters of `html`, as potok-sajt's `hashOf`: line
  endings and outer spaces do not count.
  """
  def hash(html) when is_binary(html) do
    html
    |> String.replace("\r", "")
    |> String.trim()
    |> String.to_charlist()
    |> Enum.reduce(0x811C9DC5, fn char, hash ->
      rem(Bitwise.bxor(hash, char) * 0x01000193, 0x100000000)
    end)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end
end
