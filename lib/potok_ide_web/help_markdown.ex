defmodule PotokIdeWeb.HelpMarkdown do
  @moduledoc """
  Turns the text of the help page (`priv/static/HELP.*.md`) into its HTML,
  table of contents, title and lead. `PotokIdeWeb.HelpDoc` does this once, at
  compile time.

  The text is plain Markdown with three conventions:

    * it starts with the page's title (`# ...`) and one paragraph, which the
      page shows above its contents and as its description in link cards;
    * a heading that the contents list or a link points to carries an id, the
      same in every language: `## Poruke {:#poruke}`;
    * a picture of the app is named, not linked: `![Opis](poruke-odgovor)`
      shows `priv/static/images/help/poruke-odgovor.webp` with the text as its
      caption. A paragraph of several pictures shows them side by side.

  Only what the page needs gets through. Raw HTML, a picture inside a sentence,
  a link to an unknown kind of address or a section heading without an id
  raise an `ArgumentError` that says what to fix, so a mistake in the text
  stops the build instead of reaching the page.
  """

  @tags ~w(h1 h2 h3 h4 p a strong em del code pre br hr ul ol li blockquote table thead tbody tr th td)
  @headings ~w(h1 h2 h3 h4)
  @name ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @href ~r/\A(?:#[a-z0-9-]+|\/[^\s"<>]*|https?:\/\/[^\s"<>]+|mailto:[^\s"<>]+)\z/

  @typedoc "A picture's size in CSS pixels, by name."
  @type manifest :: %{optional(String.t()) => %{String.t() => pos_integer()}}

  @type entry :: %{id: String.t(), title: String.t(), children: [entry]}

  @type t :: %{
          html: String.t(),
          title: String.t(),
          lead: String.t(),
          toc: [entry],
          ids: [String.t()],
          images: [String.t()],
          anchors: [String.t()]
        }

  @doc "Parses the help text; raises `ArgumentError` on what the page cannot show."
  @spec parse(String.t(), manifest) :: t
  def parse(markdown, manifest \\ %{}) do
    ast =
      case Earmark.Parser.as_ast(markdown, smartypants: false) do
        {:ok, ast, _messages} -> ast
        {:error, _ast, messages} -> fail("Markdown it cannot read: #{inspect(messages)}")
      end

    # `<!-- ... -->` notes for whoever edits the text stay out of the page.
    {title, lead, body} =
      case Enum.reject(ast, &match?({:comment, _, _, _}, &1)) do
        [{"h1", _, _, _} = title, {"p", _, _, _} = lead | body] -> {title, lead, body}
        _other -> fail("the text starts with a title (# ...) and a paragraph under it")
      end

    ast = Enum.map(body, &block(&1, manifest))

    %{
      html:
        Earmark.Transform.transform(ast, %Earmark.Options{
          compact_output: true,
          smartypants: false
        }),
      title: text(title),
      lead: text(lead),
      toc: toc(ast),
      ids: ast |> Enum.filter(&match?({tag, _, _, _} when tag in @headings, &1)) |> ids(),
      images:
        ast |> find_all("figure") |> Enum.map(fn {_, attrs, _, _} -> attr(attrs, "data-shot") end),
      anchors:
        ast
        |> find_all("a")
        |> Enum.flat_map(fn {"a", attrs, _, _} ->
          case attr(attrs, "href") do
            "#" <> id -> [id]
            _other -> []
          end
        end)
    }
  end

  defp block({_tag, _attrs, _children, %{verbatim: true}} = node, _manifest) do
    fail("raw HTML is not allowed: #{inspect(node)}")
  end

  defp block({"p", attrs, children, meta}, manifest) do
    case pictures(children) do
      [] -> clean({"p", attrs, children, meta})
      [picture] -> figure(picture, manifest)
      pictures -> {"div", [{"class", "hp-shots"}], Enum.map(pictures, &figure(&1, manifest)), %{}}
    end
  end

  defp block({"table", _attrs, _children, _meta} = table, _manifest) do
    {"div", [{"class", "or-table hp-table"}], [clean(table)], %{}}
  end

  defp block({tag, attrs, children, _meta} = node, _manifest) when tag in ~w(h2 h3) do
    if attr(attrs, "id") == nil do
      fail(~s(the heading "#{text(node)}" needs an id, as in "## #{text(node)} {:#some-id}"))
    end

    clean({tag, attrs, children, %{}})
  end

  defp block(node, _manifest), do: clean(node)

  # A paragraph that holds only pictures is a row of them; a picture next to
  # words would sit inside a sentence, which the page cannot lay out.
  defp pictures(children) do
    {pictures, rest} = Enum.split_with(children, &match?({"img", _, _, _}, &1))

    blank? =
      Enum.all?(rest, fn
        {"br", _, _, _} -> true
        text when is_binary(text) -> String.trim(text) == ""
        _node -> false
      end)

    cond do
      pictures == [] -> []
      blank? -> pictures
      true -> fail("a picture must stand in a paragraph of its own: #{inspect(children)}")
    end
  end

  defp figure({"img", attrs, _children, _meta} = picture, manifest) do
    name = image_name(picture)
    caption = attr(attrs, "alt") || ""

    {size, class} =
      case manifest do
        %{^name => %{"w" => width, "h" => height}} ->
          {[{"width", to_string(width)}, {"height", to_string(height)}], "hp-shot"}

        _missing ->
          {[], "hp-shot hp-missing"}
      end

    image =
      {"img",
       [{"src", "/images/help/#{name}.webp"}, {"alt", ""}] ++
         size ++ [{"loading", "lazy"}, {"decoding", "async"}], [], %{}}

    children = if caption == "", do: [image], else: [image, {"figcaption", [], [caption], %{}}]

    {"figure", [{"class", class}, {"data-shot", name}], children, %{}}
  end

  defp image_name({"img", attrs, _children, _meta}) do
    name = attr(attrs, "src") || ""

    if Regex.match?(@name, name) do
      name
    else
      fail(
        ~s|a picture is named by its file name without ".webp", as in ![Text](chat-reply), not "#{name}"|
      )
    end
  end

  # Keeps the tags the page styles and, of their attributes, only an id on a
  # heading and the address of a link.
  defp clean({tag, attrs, children, _meta}) when tag in @tags do
    {tag, clean_attrs(tag, attrs), Enum.map(children, &clean/1), %{}}
  end

  defp clean(text) when is_binary(text), do: text

  defp clean({"img", _attrs, _children, _meta} = picture) do
    fail("a picture must stand in a paragraph of its own: #{inspect(picture)}")
  end

  defp clean(node), do: fail("the help page does not show #{inspect(node)}")

  defp clean_attrs(tag, attrs) when tag in @headings do
    case attr(attrs, "id") do
      nil ->
        []

      id ->
        if Regex.match?(@name, id),
          do: [{"id", id}],
          else: fail(~s(an id is written in small Latin letters, digits and "-", not "#{id}"))
    end
  end

  defp clean_attrs("a", attrs) do
    href = attr(attrs, "href") || ""

    cond do
      not Regex.match?(@href, href) ->
        fail(~s(a link goes to "#section", "/page" or "https://...", not "#{href}"))

      String.starts_with?(href, "http") ->
        [{"href", href}, {"target", "_blank"}, {"rel", "noopener noreferrer"}]

      true ->
        [{"href", href}]
    end
  end

  defp clean_attrs(_tag, _attrs), do: []

  defp toc(ast) do
    ast
    |> Enum.filter(&match?({tag, _, _, _} when tag in ~w(h2 h3), &1))
    |> Enum.reduce([], fn
      {"h2", attrs, _, _} = node, entries ->
        [%{id: attr(attrs, "id"), title: text(node), children: []} | entries]

      {"h3", attrs, _, _} = node, [section | entries] ->
        child = %{id: attr(attrs, "id"), title: text(node), children: []}
        [%{section | children: section.children ++ [child]} | entries]

      {"h3", _, _, _} = node, [] ->
        fail(~s(the heading "#{text(node)}" comes before any "## " section))
    end)
    |> Enum.reverse()
  end

  defp ids(nodes) do
    Enum.flat_map(nodes, fn {_tag, attrs, _, _} -> List.wrap(attr(attrs, "id")) end)
  end

  defp find_all(nodes, tag) when is_list(nodes), do: Enum.flat_map(nodes, &find_all(&1, tag))

  defp find_all({tag, _attrs, children, _meta} = node, tag),
    do: [node | find_all(children, tag)]

  defp find_all({_other, _attrs, children, _meta}, tag), do: find_all(children, tag)
  defp find_all(_text, _tag), do: []

  defp text(nil), do: ""
  defp text(text) when is_binary(text), do: text
  defp text({_tag, _attrs, children, _meta}), do: text(children)

  defp text(nodes) when is_list(nodes),
    do: nodes |> Enum.map_join(&text/1) |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  defp fail(message), do: raise(ArgumentError, "help text: " <> message)
end
