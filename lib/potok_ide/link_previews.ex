defmodule PotokIde.LinkPreviews do
  @moduledoc """
  Open Graph previews of links in chat values. The page of a value's first
  link is fetched (`PotokIde.LinkPreviews.HTTP`), and its title,
  description, image and site name are kept on the value
  (`Value.link_preview`). Images are shown straight from the linked site.

  Results are cached per URL, failures too, so a link posted again is not
  fetched again for a while.
  """

  alias PotokIde.LinkPreviews.HTTP
  alias PotokIde.UTF8

  @cache_ttl :timer.hours(6)
  @max_title_length 200
  @max_description_length 300
  @max_site_name_length 80
  @max_url_length 2048
  @url_pattern ~r{https?://[^\s<>"'`]+}iu
  @trailing_punctuation ~r/[.,;:!?'"*_~]+\z/u

  @doc "True when previews are fetched off the caller (false in tests)."
  def async?, do: config(:async, true)

  @doc """
  The first http(s) link of a value's content, or nil. Links in code blocks
  and inline code do not count, trailing punctuation (and a closing bracket
  without its opening one) is not part of the link, and links to Potok itself
  are skipped.
  """
  def first_url(content) when is_binary(content) do
    content
    |> String.replace(~r/```.*?(?:```|\z)/su, " ")
    |> String.replace(~r/`[^`\n]*`/u, " ")
    |> then(&Regex.scan(@url_pattern, &1))
    |> Enum.find_value(fn [candidate] -> clean_url(candidate) end)
  end

  def first_url(_content), do: nil

  defp clean_url(candidate) do
    url =
      candidate
      |> String.replace("&amp;", "&")
      |> trim_url_end()

    case URI.new(url) do
      {:ok, %URI{host: host}}
      when is_binary(host) and host != "" and byte_size(url) <= @max_url_length ->
        if String.downcase(host) == PotokIdeWeb.Endpoint.host(), do: nil, else: url

      _ ->
        nil
    end
  end

  # "(see https://example.com/a_(b))." keeps the `)` that belongs to the link.
  defp trim_url_end(url) do
    trimmed = String.replace(url, @trailing_punctuation, "")

    trimmed =
      cond do
        unbalanced_end?(trimmed, "(", ")") -> String.slice(trimmed, 0..-2//1)
        unbalanced_end?(trimmed, "[", "]") -> String.slice(trimmed, 0..-2//1)
        true -> trimmed
      end

    if trimmed == url, do: url, else: trim_url_end(trimmed)
  end

  defp unbalanced_end?(url, open, close) do
    String.ends_with?(url, close) and
      length(String.split(url, close)) > length(String.split(url, open))
  end

  @doc """
  `{:ok, preview}` for a page with a title or a description, `:error`
  otherwise. Never raises: previews are best effort.
  """
  def fetch(url) when is_binary(url) do
    case config(:cache_ttl, @cache_ttl) do
      0 -> fetch_uncached(url)
      ttl -> PotokIde.Cache.fetch({:link_preview, url}, ttl, fn -> fetch_uncached(url) end)
    end
  end

  defp fetch_uncached(url) do
    case HTTP.get_html(url) do
      {:ok, html, page_url} -> parse(html, page_url, url)
      :error -> :error
    end
  rescue
    _exception -> :error
  end

  @doc """
  The preview of the page at `page_url` that `url` led to. Open Graph tags
  come first, then Twitter cards, then plain `<title>` and description.
  Only https images are kept: an http one would be mixed content.
  """
  def parse(html, page_url, url \\ nil) when is_binary(html) and is_binary(page_url) do
    document = LazyHTML.from_document(html)

    title =
      document
      |> meta(["og:title", "twitter:title"])
      |> Kernel.||(title_tag(document))
      |> clean_text(@max_title_length)

    description =
      document
      |> meta(["og:description", "twitter:description", "description"])
      |> clean_text(@max_description_length)

    if title || description do
      image =
        meta(document, [
          "og:image:secure_url",
          "og:image",
          "og:image:url",
          "twitter:image",
          "twitter:image:src"
        ])

      site_name =
        document
        |> meta(["og:site_name", "application-name"])
        |> Kernel.||(page_host(page_url))
        |> clean_text(@max_site_name_length)

      {:ok,
       %{
         "url" => url || page_url,
         "title" => title,
         "description" => description,
         "site_name" => site_name,
         "image_url" => image_url(image, page_url)
       }}
    else
      :error
    end
  end

  # The first non-blank `content` among `<meta>` tags named (`property` or
  # `name`) after `names`, tried in order.
  defp meta(document, names) do
    Enum.find_value(names, fn name ->
      document
      |> LazyHTML.query(~s(meta[property="#{name}" i], meta[name="#{name}" i]))
      |> LazyHTML.attribute("content")
      |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    end)
  end

  defp title_tag(document) do
    case Enum.at(LazyHTML.query(document, "head > title"), 0) do
      nil -> nil
      title -> LazyHTML.text(title)
    end
  end

  defp clean_text(nil, _max_length), do: nil

  defp clean_text(text, max_length) do
    text
    |> UTF8.replace_invalid()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" ->
        nil

      text ->
        if String.length(text) <= max_length,
          do: text,
          else: String.trim_trailing(String.slice(text, 0, max_length - 1)) <> "…"
    end
  end

  defp image_url(nil, _page_url), do: nil

  defp image_url(src, page_url) do
    case URI.merge(page_url, String.trim(src)) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and host != "" ->
        image_url = URI.to_string(uri)
        if byte_size(image_url) <= @max_url_length, do: image_url

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp page_host(page_url) do
    case URI.parse(page_url) do
      %URI{host: "www." <> host} -> host
      %URI{host: host} -> host
    end
  end

  defp config(key, default) do
    :potok_ide
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end
end
