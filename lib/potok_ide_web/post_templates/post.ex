defmodule PotokIdeWeb.PostTemplates.Post do
  @moduledoc """
  A description made from a template. It has to be HTML that stands alone, as
  that is what viewers and apps get, so what it was made from travels in a
  comment on the first line. The group keeps the comment, and the sanitizer
  takes it out of everything a viewer gets.

      <!--potok-post {"v":1,"template":"quote","fields":{...},"hash":"1a2b3c4d"}-->
      <meta name="description" content="..."><blockquote style="...">...</blockquote>

  `hash` is that of the HTML below the comment, which tells if someone changed
  the text by hand: a form built from `fields` would undo that. The meta tag is
  what the card of a shared link says.

  FeedCreator writes and reads the same thing (`post.ts`), so a change here
  needs one there.
  """

  import Bitwise

  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.PostTemplates.Markup

  @marker_start "<!--potok-post "

  @doc "FNV-1a over code points. Line endings and outer spaces do not count."
  def hash(html) do
    html
    |> String.replace("\r", "")
    |> Markup.trim()
    |> String.to_charlist()
    |> Enum.reduce(0x811C9DC5, fn point, hash ->
      rem(bxor(hash, point) * 0x01000193, 0x100000000)
    end)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  @doc "The description of a template with its fields."
  def encode(id, fields) do
    html = html(id, fields)

    marker =
      [v: 1, template: id, fields: fields, hash: hash(html)]
      |> Jason.OrderedObject.new()
      |> Jason.encode!()
      |> comment_safe()

    "#{@marker_start}#{marker}-->\n#{html}"
  end

  @doc "The same description without the comment, which no form can come back from."
  def html(id, fields),
    do: card_tag(PostTemplates.card(id, fields)) <> PostTemplates.render(id, fields)

  # JSON that no comment can end inside of. Those characters stand only in its strings.
  defp comment_safe(json) do
    json
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace("--", "-\\u002d")
  end

  defp card_tag(text) do
    case Markup.summary(text) do
      "" -> ""
      content -> ~s|<meta name="description" content="#{Markup.escape(content)}">|
    end
  end

  @doc """
  What a description was made from:

    * `{:post, %{template: id, fields: fields}}` when it comes from a template
      and stayed as it was
    * `{:changed, %{template: id, fields: fields}}` when it was changed by hand
      since
    * `:free` for everything else
  """
  def decode(<<@marker_start, _rest::binary>> = description) do
    with [marker, json] <- Regex.run(~r/\A<!--potok-post (\{.*?\})-->\n?/s, description),
         {:ok, post, expected} <- parse(json) do
      html_size = byte_size(description) - byte_size(marker)
      html = binary_part(description, byte_size(marker), html_size)

      if hash(html) == expected, do: {:post, post}, else: {:changed, post}
    else
      _no_post -> :free
    end
  end

  def decode(_description), do: :free

  defp parse(json) do
    with {:ok, %{"template" => id, "fields" => %{} = fields} = marker} <- Jason.decode(json),
         true <- PostTemplates.form?(id) do
      {:ok, %{template: id, fields: fields}, marker["hash"]}
    else
      _invalid -> :error
    end
  end
end
