defmodule PotokIdeWeb.Galleries do
  @moduledoc """
  A gallery in rich content: pictures that move sideways, by a swipe, a
  trackpad, the arrow keys or two buttons. The stored HTML says only which
  pictures, in which look:

      <div data-potok-gallery="slides"><div>
        <figure><img src="..." alt="..."><figcaption>...</figcaption></figure>
        ...
      </div></div>

  `data-potok-gallery` with one of `looks/0` is the one attribute of its kind
  `RichContentScrubber` keeps. FeedCreator's Galerija template writes it,
  and anyone may write it by hand. Without Potok's CSS the pictures stand one
  under another.

  `decorate/1` runs on sanitized HTML, as it is shown: it adds what moving
  through the pictures needs (the buttons, a counter on each picture, a strip
  the keyboard can reach, pictures that load as they come near), so none of
  it is stored or sanitized, and the buttons speak the viewer's language.
  The looks are in `app.css`, which apps' frames load too; `gallery.js`
  moves the strip, and Feed has the same few lines.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  @marker "data-potok-gallery"
  @looks ~w(slides cards cinema polaroid)

  @doc "The looks a gallery can have."
  def looks, do: @looks

  @doc """
  `html` (a string or safe HTML) with each gallery made ready to move through.
  HTML without a gallery comes back as it was.
  """
  def decorate({:safe, _iodata} = safe) do
    html = Phoenix.HTML.safe_to_string(safe)

    if String.contains?(html, @marker),
      do: Phoenix.HTML.raw(decorate_html(html)),
      else: safe
  end

  def decorate(html) when is_binary(html) do
    if String.contains?(html, @marker), do: decorate_html(html), else: html
  end

  def decorate(nil), do: nil

  defp decorate_html(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree()
    |> Enum.map(&walk/1)
    |> LazyHTML.from_tree()
    |> LazyHTML.to_html()
  end

  defp walk({"div", attrs, children}) do
    case List.keyfind(attrs, @marker, 0) do
      {_name, look} when look in @looks -> gallery(look, children)
      _other -> {"div", attrs, Enum.map(children, &walk/1)}
    end
  end

  defp walk({tag, attrs, children}) when is_binary(tag),
    do: {tag, attrs, Enum.map(children, &walk/1)}

  defp walk(other), do: other

  defp gallery(look, children) do
    slides = slides(children)
    count = length(slides)

    strip =
      {"div", [{"data-gallery-strip", ""}, {"tabindex", "0"}],
       slides
       |> Enum.with_index(1)
       |> Enum.map(fn {slide, n} -> slide(slide, n, count) end)}

    {"div", [{@marker, look}, {"role", "region"}, {"aria-label", gettext("Gallery")}],
     [strip | buttons(count)]}
  end

  # The pictures stand in a `<div>` of their own; written by hand they may
  # stand right in the gallery.
  defp slides(children) do
    case elements(children) do
      [{"div", attrs, inner}] ->
        if List.keymember?(attrs, @marker, 0), do: [], else: elements(inner)

      elements ->
        elements
    end
  end

  defp elements(nodes),
    do: Enum.filter(nodes, &match?({tag, _attrs, _children} when is_binary(tag), &1))

  defp slide({tag, attrs, children}, n, count) do
    counter =
      if count > 1,
        do: [{"span", [{"data-gallery-count", ""}, {"aria-hidden", "true"}], ["#{n} / #{count}"]}],
        else: []

    {tag, attrs, counter ++ Enum.map(children, &lazy/1)}
  end

  defp lazy({"img", attrs, children}),
    do: {"img", attrs ++ [{"loading", "lazy"}, {"decoding", "async"}], children}

  defp lazy({tag, attrs, children}) when is_binary(tag),
    do: {tag, attrs, Enum.map(children, &lazy/1)}

  defp lazy(other), do: other

  defp buttons(count) when count < 2, do: []

  defp buttons(_count) do
    [
      {"button",
       [
         {"type", "button"},
         {"data-gallery-step", "-1"},
         {"aria-label", gettext("Previous picture")}
       ], []},
      {"button",
       [{"type", "button"}, {"data-gallery-step", "1"}, {"aria-label", gettext("Next picture")}],
       []}
    ]
  end
end
