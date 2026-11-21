defmodule PotokIde.Social.GroupTemplate.Syntax do
  @moduledoc """
  The language of a group's own templates: HTML with tags that take the form's
  fields, and nothing that runs.

    * `{{key}}` the field's text, escaped; a list joins with ", ".
    * `{{key|filter}}`: `inline` (`**jako**`, `*malo*`, links), `paragraphs`,
      `date`, and `url`, `image`, `video`, the only ways into an address.
    * `{{#key}}…{{/key}}` when the field is filled, once per row of a list:
      `{{.}}` is the row of `items`, `{{picture}}` and `{{caption}}` the row of
      `pictures`. `{{^key}}…{{/key}}` when it is empty.

  `parse/2` reads a template against its fields into a tree that
  `PotokIdeWeb.PostTemplates.Custom` renders: `{:text, text}`,
  `{:var, name, filter}` and `{:section, name, inverted?, children}`.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  @tag ~r/\{\{.*?\}\}/s
  @inside ~r/\A\{\{\s*([#^\/]?)\s*([a-z][a-z0-9_]*|\.)\s*(?:\|\s*([a-z]+)\s*)?\}\}\z/s
  @filters ~w(inline paragraphs date url image video)
  @max_depth 3

  def filters, do: @filters

  @doc "The tree of `html` against `fields` (stored shape), or `{:error, message}`."
  def parse(html, fields) when is_binary(html) and is_list(fields) do
    kinds = Map.new(fields, &{&1["key"], &1["kind"]})

    html
    |> String.split(@tag, include_captures: true, trim: true)
    |> Enum.reduce_while({[[]], []}, fn piece, {stack, open} ->
      case step(piece, stack, open, kinds) do
        {:ok, stack, open} -> {:cont, {stack, open}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:error, message} ->
        {:error, message}

      {[tree], []} ->
        {:ok, Enum.reverse(tree)}

      {_stack, [{name, _inverted} | _rest]} ->
        {:error, dgettext("errors", "leaves {{#%{name}}} without its {{/%{name}}}", name: name)}
    end
  end

  defp step("{{" <> _rest = piece, stack, open, kinds) do
    case Regex.run(@inside, piece) do
      [_tag, "", name] ->
        var(name, nil, stack, open, kinds)

      [_tag, "", name, filter] ->
        var(name, filter, stack, open, kinds)

      [_tag, mark, name] when mark in ["#", "^"] ->
        open(name, mark == "^", stack, open, kinds)

      [_tag, "/", name] ->
        close(name, stack, open)

      [_tag, _mark, _name, _filter] ->
        {:error, dgettext("errors", "puts a filter on a section: %{tag}", tag: piece)}

      nil ->
        {:error, dgettext("errors", "has a tag it does not know: %{tag}", tag: piece)}
    end
  end

  defp step(text, [current | rest], open, _kinds),
    do: {:ok, [[{:text, text} | current] | rest], open}

  defp var(name, filter, [current | rest], open, kinds) do
    cond do
      not known?(name, open, kinds) ->
        {:error, dgettext("errors", "has no field %{name}", name: name)}

      filter && filter not in @filters ->
        {:error, dgettext("errors", "has no filter %{filter}", filter: filter)}

      true ->
        {:ok, [[{:var, name, filter} | current] | rest], open}
    end
  end

  defp open(name, inverted?, stack, open, kinds) do
    cond do
      not known?(name, open, kinds) ->
        {:error, dgettext("errors", "has no field %{name}", name: name)}

      length(open) >= @max_depth ->
        {:error, dgettext("errors", "has sections more than %{count} deep", count: @max_depth)}

      true ->
        {:ok, [[] | stack], [{name, inverted?} | open]}
    end
  end

  defp close(name, [children, parent | rest], [{name, inverted?} | open]) do
    {:ok, [[{:section, name, inverted?, Enum.reverse(children)} | parent] | rest], open}
  end

  defp close(name, _stack, [{other, _inverted} | _open]) do
    {:error,
     dgettext("errors", "closes {{/%{name}}} where {{/%{other}}} belongs",
       name: name,
       other: other
     )}
  end

  defp close(name, _stack, []),
    do: {:error, dgettext("errors", "closes {{/%{name}}} that was never opened", name: name)}

  # The fields, and inside a list's section the names of its row.
  defp known?(name, open, kinds) do
    Map.has_key?(kinds, name) or name in row_names(open, kinds)
  end

  defp row_names(open, kinds) do
    Enum.flat_map(open, fn {name, _inverted} ->
      case kinds[name] do
        "items" -> ["."]
        "pictures" -> ["picture", "caption"]
        _other -> []
      end
    end)
  end
end
