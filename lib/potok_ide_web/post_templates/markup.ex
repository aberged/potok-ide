defmodule PotokIdeWeb.PostTemplates.Markup do
  @moduledoc """
  Text and addresses on their way into a description, which
  `PotokIdeWeb.RichContentScrubber` sanitizes when it is shown.

  The same rules as `html.ts` of FeedCreator, whose descriptions these forms
  open and save. The two differ only in where a long text full of emoji is cut
  and in how an address with non-Latin letters shows its host: JavaScript
  counts UTF-16 units and writes punycode.
  """

  @doc "Unlike `Phoenix.HTML.html_escape/1`, this leaves apostrophes as they are."
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  @doc """
  JavaScript's `trim`, as a description's hash depends on it: `String.trim/1`
  leaves U+FEFF and takes U+0085.
  """
  def trim(text) do
    Regex.replace(
      ~r/\A[\t-\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\t-\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u,
      text,
      ""
    )
  end

  # The sanitizer compares schemes as they are written, so they go lowercase.
  defp with_lowercase_scheme(address),
    do: Regex.replace(~r/\A[a-z]+:/i, address, &String.downcase/1)

  @doc "A link's address: one without a scheme gets https. `\"\"` when it is no link at all."
  def safe_href(value) do
    address = trim(value)

    cond do
      String.match?(address, ~r/\s/u) ->
        ""

      String.match?(address, ~r/\A(https?:\/\/|mailto:)./i) ->
        with_lowercase_scheme(address)

      String.match?(address, ~r/\A[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)+([\/?#].*)?\z/u) ->
        "https://" <> address

      true ->
        ""
    end
  end

  @doc "A picture's address: on the web, or the picture of a group here."
  def safe_image(value) do
    address = trim(value)

    cond do
      String.match?(address, ~r/\Ahttps?:\/\/\S+\z/iu) -> with_lowercase_scheme(address)
      String.match?(address, ~r/\A\/avatar\/group\/\d+(\?\w+=\w+)?\z/) -> address
      true -> ""
    end
  end

  @doc "The host of an address, without `www.`. `\"\"` for an address that has none."
  def host(href) do
    case URI.parse(href).host do
      nil -> ""
      host -> host |> String.downcase() |> String.replace_prefix("www.", "")
    end
  end

  defp anchor(href, label) do
    ~s|<a href="#{escape(href)}" target="_blank" rel="noopener">#{escape(label)}</a>|
  end

  defp marks,
    do: ~r/\[([^\]\n]+)\]\(([^)\s]+)\)|\*\*([^*\n]+)\*\*|\*([^*\n]+)\*|(https?:\/\/[^\s<>]+)/u

  @doc """
  Text with `**bold**`, `*italic*`, `[a link](address)` and bare addresses.
  `links: false` is for a colored card, where the page's link color has nothing
  to stand on.
  """
  def inline(text, opts \\ []) do
    links = Keyword.get(opts, :links, true)

    marks()
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(&inline_piece(&1, links))
  end

  # Every group takes at least one character, so `""` is a group left out.
  defp inline_piece(piece, links) do
    case Regex.run(marks(), piece) do
      nil -> escape(piece)
      [_whole, "", "", bold] -> "<strong>#{escape(bold)}</strong>"
      [_whole, "", "", "", italic] -> "<em>#{escape(italic)}</em>"
      [_whole, "", "", "", "", bare] -> bare_address(bare, links)
      [whole, label, href] -> labeled_link(whole, label, safe_href(href), links)
    end
  end

  defp labeled_link(whole, _label, "", _links), do: escape(whole)
  defp labeled_link(_whole, label, address, true), do: anchor(address, label)
  defp labeled_link(_whole, label, _address, false), do: escape(label)

  # A sentence ends after the address, not in it.
  defp bare_address(bare, links) do
    ending =
      case Regex.run(~r/[.,;:!?)]+\z/, bare) do
        [ending] -> ending
        nil -> ""
      end

    address = String.replace_suffix(bare, ending, "")

    if(links, do: anchor(address, address), else: escape(address)) <> escape(ending)
  end

  @doc "Blocks of text as paragraphs: an empty line starts a new one."
  def paragraphs(text, style \\ "", opts \\ []) do
    opening = if style == "", do: "<p>", else: ~s|<p style="#{style}">|

    text
    |> String.split(~r/\n\s*\n/u)
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(&"#{opening}#{String.replace(inline(&1, opts), "\n", "<br>")}</p>")
  end

  @doc "A text without its marks, on one line and cut between words, for a link's card."
  def summary(text, length \\ 200) do
    clean =
      marks()
      |> Regex.replace(text, fn whole, label, _href, bold, italic, bare ->
        Enum.find([bold, italic, label, bare], whole, &(&1 != ""))
      end)
      |> then(&Regex.replace(~r/\s+/u, &1, " "))
      |> trim()

    if String.length(clean) <= length, do: clean, else: cut(clean, length)
  end

  defp cut(text, length) do
    start = String.slice(text, 0, length - 1)

    head =
      case start |> :binary.matches(" ") |> List.last() do
        {position, _size} when position > 0 -> binary_part(start, 0, position)
        _no_space -> start
      end

    Regex.replace(~r/[\s,;:]+\z/u, head, "") <> "…"
  end
end
