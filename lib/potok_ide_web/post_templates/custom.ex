defmodule PotokIdeWeb.PostTemplates.Custom do
  @moduledoc """
  Renders a group's own template (`PotokIde.Social.GroupTemplate`) with what
  its form holds, the one place it is turned into HTML: Uredi grupu and
  FeedCreator (through `renderTemplate`) both come here, so no copy can drift.

  The template is read by `GroupTemplate.Syntax`. Every value is escaped, and
  only the `url`, `image` and `video` filters reach an address, through
  `Markup`'s checks; the display sanitizer still runs over what comes out.

  A post made with it says `"template": "custom:<id>"` and its version
  (`rev`) in its marker (`PostTemplates.Post`).
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Events.Format
  alias PotokIde.Social.GroupTemplate
  alias PotokIde.Social.GroupTemplate.Syntax
  alias PotokIdeWeb.PostTemplates.Markup
  alias PotokIdeWeb.RichContentScrubber

  @max_items 30
  @max_pictures 20

  @kinds %{
    "text" => :text,
    "textarea" => :textarea,
    "url" => :url,
    "date" => :date,
    "time" => :time,
    "choice" => :choice,
    "items" => :items,
    "image" => :image,
    "pictures" => :pictures,
    "video" => :video
  }

  @doc "The id a post and the description form know the template by."
  def id(%GroupTemplate{id: id}), do: "custom:#{id}"

  @doc "The template's id in `id` (`custom:<id>`), or nil for any other."
  def template_id("custom:" <> digits) do
    case Integer.parse(digits) do
      {id, ""} when id > 0 -> id
      _other -> nil
    end
  end

  def template_id(_id), do: nil

  @doc """
  The template as the description form takes one (`PostTemplates.templates/0`):
  `%{id, name, purpose, fields, sample, custom, owner}`.
  """
  def form_template(%GroupTemplate{} = template, owner \\ nil) do
    %{
      id: id(template),
      name: template.name,
      purpose: template.purpose,
      fields: Enum.map(template.fields, &form_field/1),
      sample: sample(template),
      custom: template,
      owner: owner
    }
  end

  defp form_field(field) do
    kind = Map.fetch!(@kinds, field["kind"])

    %{
      key: field["key"],
      label: field["label"],
      kind: kind,
      required: field["required"] == true,
      hint: blank_to_nil(field["hint"]),
      placeholder: nil,
      options: for(option <- field["options"] || [], do: {option, option}),
      captions: if(kind == :pictures, do: GroupTemplate.captions_key(field["key"]))
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc "The keys a post of the template keeps: its fields', and the captions of its pictures."
  def field_keys(%GroupTemplate{fields: fields}) do
    Enum.flat_map(fields, fn
      %{"kind" => "pictures", "key" => key} -> [key, GroupTemplate.captions_key(key)]
      %{"key" => key} -> [key]
    end)
  end

  @doc "The labels of required fields left empty."
  def missing_fields(%GroupTemplate{fields: fields}, values) do
    for %{"required" => true, "label" => label} = field <- fields,
        empty?(value(field, values)),
        do: label
  end

  defp empty?(value) when is_binary(value), do: value == ""
  defp empty?(value) when is_list(value), do: value == []

  @doc "The HTML of the template with `values`, without the marker."
  def render(%GroupTemplate{} = template, values) do
    case Syntax.parse(template.html, template.fields) do
      {:ok, tree} -> render_nodes(tree, field_values(template, values), [])
      {:error, _message} -> ""
    end
  end

  @doc "What a FeedCreator post made with it is called: its first required text field."
  def name(%GroupTemplate{} = template, values) do
    with %{} = field <- Enum.find(template.fields, &(&1["kind"] == "text" and &1["required"])),
         text when text != "" <- value(field, values) do
      String.slice(text, 0, 120)
    else
      _none -> template.name
    end
  end

  @doc "What the card of a shared link says: the first longer text."
  def card(%GroupTemplate{} = template, values) do
    case Enum.find(template.fields, &(&1["kind"] == "textarea")) do
      nil -> ""
      field -> field |> value(values) |> Markup.summary()
    end
  end

  @doc """
  The template with its sample values, sanitized, for the list of templates.
  Unlike a built-in template's, a group's own goes through the sanitizer.
  """
  def thumbnail(%GroupTemplate{} = template) do
    template |> render(sample(template)) |> sanitize()
  end

  @doc """
  What the sanitizer would drop of the template with its sample values: a
  list of `{:tag | :attribute | :style, what}`, empty when nothing goes.
  """
  def dropped(%GroupTemplate{} = template) do
    html = render(template, sample(template))
    shown = sanitize(html)

    tags = parts(html, :tag) -- parts(shown, :tag)
    attributes = parts(html, :attribute) -- parts(shown, :attribute)
    styles = declarations(html) -- declarations(shown)

    Enum.uniq(
      Enum.map(tags, &{:tag, &1}) ++
        Enum.map(attributes, &{:attribute, &1}) ++ Enum.map(styles, &{:style, &1})
    )
  end

  defp sanitize(html), do: HtmlSanitizeEx.Scrubber.scrub(html, RichContentScrubber)

  defp parts("", _kind), do: []

  defp parts(html, kind) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.to_tree()
    |> collect(kind)
  end

  defp collect(nodes, kind) do
    Enum.flat_map(nodes, fn
      {tag, attrs, children} when is_binary(tag) ->
        own =
          case kind do
            :tag -> ["<#{tag}>"]
            :attribute -> for {name, _value} <- attrs, name != "style", do: "#{tag} #{name}"
          end

        own ++ collect(children, kind)

      _text ->
        []
    end)
  end

  defp declarations(html) do
    ~r/ style="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [style] -> String.split(style, ";", trim: true) end)
    |> Enum.map(&String.replace(&1, " ", ""))
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Values that show every field of `template`: for its thumbnail and its preview."
  def sample(%GroupTemplate{fields: fields}) do
    picture = sample_picture()

    Enum.reduce(fields, %{}, fn field, acc ->
      key = field["key"]

      case field["kind"] do
        "text" ->
          Map.put(acc, key, field["label"])

        "textarea" ->
          Map.put(acc, key, dgettext("post_templates", "A few words about it."))

        "url" ->
          Map.put(acc, key, "https://potok.rs")

        "date" ->
          Map.put(acc, key, "2026-11-14")

        "time" ->
          Map.put(acc, key, "10:00")

        "choice" ->
          Map.put(acc, key, List.first(field["options"] || [], ""))

        "items" ->
          Map.put(acc, key, [field["label"] <> " 1", field["label"] <> " 2"])

        "image" ->
          Map.put(acc, key, picture)

        "video" ->
          acc

        "pictures" ->
          acc
          |> Map.put(key, [picture, picture])
          |> Map.put(GroupTemplate.captions_key(key), [field["label"], ""])
      end
    end)
  end

  defp sample_picture, do: PotokIdeWeb.Endpoint.url() <> "/images/template-sample.svg"

  # What each field holds, in the shape its tags read.
  defp field_values(%GroupTemplate{fields: fields}, values) do
    Map.new(fields, &{&1["key"], value(&1, values)})
  end

  defp value(%{"kind" => "items", "key" => key}, values) do
    values
    |> Map.get(key)
    |> List.wrap()
    |> Enum.flat_map(fn item -> if is_binary(item), do: [Markup.trim(item)], else: [] end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(@max_items)
  end

  defp value(%{"kind" => "pictures", "key" => key}, values) do
    captions = values |> Map.get(GroupTemplate.captions_key(key)) |> List.wrap()

    values
    |> Map.get(key)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {address, index} ->
      %{
        "picture" => address |> text() |> Markup.safe_image(),
        "caption" => captions |> Enum.at(index) |> text()
      }
    end)
    |> Enum.reject(&(&1["picture"] == ""))
    |> Enum.take(@max_pictures)
  end

  defp value(%{"key" => key}, values), do: values |> Map.get(key) |> text()

  defp text(value) when is_binary(value), do: Markup.trim(value)
  defp text(_value), do: ""

  defp render_nodes(nodes, values, scopes),
    do: Enum.map_join(nodes, &render_node(&1, values, scopes))

  defp render_node({:text, text}, _values, _scopes), do: text

  defp render_node({:var, name, filter}, values, scopes),
    do: name |> lookup(values, scopes) |> show(filter)

  defp render_node({:section, name, inverted?, children}, values, scopes) do
    value = lookup(name, values, scopes)

    cond do
      inverted? and filled?(value) -> ""
      inverted? -> render_nodes(children, values, scopes)
      not filled?(value) -> ""
      is_list(value) -> Enum.map_join(value, &render_nodes(children, values, [row(&1) | scopes]))
      true -> render_nodes(children, values, scopes)
    end
  end

  defp row(%{} = picture), do: picture
  defp row(item), do: %{"." => item}

  defp lookup(name, values, scopes) do
    Enum.find_value(scopes, fn scope -> Map.get(scope, name) end) || Map.get(values, name, "")
  end

  defp filled?(value) when is_binary(value), do: value != ""
  defp filled?(value) when is_list(value), do: value != []
  defp filled?(_value), do: false

  defp show(value, filter) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
    |> show(filter)
  end

  defp show(text, nil), do: escape(text)
  defp show(text, "inline"), do: Markup.inline(text)
  defp show(text, "paragraphs"), do: Markup.paragraphs(text)
  defp show(text, "date"), do: text |> date() |> escape()
  defp show(text, "url"), do: text |> Markup.safe_href() |> escape()
  defp show(text, "image"), do: text |> Markup.safe_image() |> escape()
  defp show(text, "video"), do: text |> Markup.safe_video() |> escape()

  # Apostrophes too: a template may quote an attribute either way.
  defp escape(text), do: text |> Markup.escape() |> String.replace("'", "&#39;")

  defp date(text) do
    with [_whole, year, month, day] <- Regex.run(~r/\A(\d{4})-(\d{2})-(\d{2})\z/, text),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      dgettext("post_templates", "%{month} %{day}, %{year}",
        month: Format.month_name(date.month),
        day: date.day,
        year: date.year
      )
    else
      _not_a_date -> text
    end
  end
end
