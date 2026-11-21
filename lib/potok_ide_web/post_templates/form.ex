defmodule PotokIdeWeb.PostTemplates.Form do
  @moduledoc """
  Turns what a description's form sends into the description to save.

  The description is the form's only state: its fields are read back from the
  comment on its first line (`Post.decode/1`). The form sends them as
  `description_template` next to the form's own attrs:

    * `id` and `fields`, while a template's form is open
    * `pick`, from a card in the list of templates
    * `add_item` (the list's key), `remove_item` (`key:index`, or the
      index of the list `items`), `clear_image` (the picture's key) and
      `restore`, from buttons

  `catalog` holds the group's own templates as the form takes them
  (`PostTemplates.template/2`); a field's rows are found by its key and kind,
  so a template of any shape works.

  An unchanged form gives back the saved description as it is, so opening
  someone's description in another language, or a FeedCreator post, rewrites
  nothing.
  """

  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.PostTemplates.{Custom, Post}

  @doc """
  `attrs` with the description of `params`, and the labels of required fields
  still empty. `saved` is the description in the database. A description that
  is not being changed never stops a save, as its group may have other edits.
  """
  def prepare(attrs, params, saved, catalog \\ [])

  def prepare(attrs, nil, _saved, _catalog), do: {attrs, []}

  def prepare(attrs, params, saved, catalog) do
    attrs = put_description(attrs, params, saved, catalog)
    {attrs, missing(attrs["description"], saved, catalog)}
  end

  defp missing(description, description, _catalog), do: []

  defp missing(description, _saved, catalog) do
    with {:post, %{template: id, fields: fields}} <- Post.decode(description),
         true <- PostTemplates.form?(id, catalog) do
      PostTemplates.missing_fields(id, fields, catalog)
    else
      _other -> []
    end
  end

  defp put_description(attrs, %{"restore" => _restore}, _saved, catalog) do
    with {:changed, %{template: id, fields: fields}} <- Post.decode(attrs["description"]),
         true <- PostTemplates.form?(id, catalog) do
      put_post(attrs, id, fields, catalog)
    else
      _other -> attrs
    end
  end

  defp put_description(attrs, %{"pick" => id} = params, saved, catalog) do
    cond do
      id == params["id"] ->
        put_description(attrs, Map.delete(params, "pick"), saved, catalog)

      id == PostTemplates.free_text() ->
        put_free_text(attrs, opened_post(attrs, params, catalog), catalog)

      PostTemplates.form?(id, catalog) ->
        {_id, fields} = opened_post(attrs, params, catalog) || {id, %{}}
        put_post(attrs, id, Map.take(fields, PostTemplates.field_keys(id, catalog)), catalog)

      true ->
        attrs
    end
  end

  defp put_description(attrs, %{"id" => id} = params, saved, catalog) do
    if PostTemplates.form?(id, catalog) do
      fields = submitted_fields(params, id, catalog)

      # A new row is empty, so it would otherwise read as no change at all.
      if not Map.has_key?(params, "add_item") and same_as_saved?(saved, id, fields, catalog),
        do: put_description_source(attrs, saved),
        else: put_post(attrs, id, fields, catalog)
    else
      attrs
    end
  end

  defp put_description(attrs, _params, _saved, _catalog), do: attrs

  defp put_post(attrs, id, fields, catalog) do
    put_description_source(
      attrs,
      Post.encode(id, Map.reject(fields, &match?({_key, ""}, &1)), catalog)
    )
  end

  defp put_description_source(attrs, description) do
    attrs
    |> Map.put("description", description)
    |> Map.put("description_format", "html")
  end

  # The text stays, as HTML, for the author to go on from.
  defp put_free_text(attrs, nil, _catalog), do: attrs

  defp put_free_text(attrs, {id, fields}, catalog),
    do: put_description_source(attrs, Post.html(id, fields, catalog))

  # What the form holds at the moment: the fields of an open form, or those a
  # text changed by hand was made from. Free text has no fields.
  defp opened_post(_attrs, %{"id" => id} = params, catalog) do
    if PostTemplates.form?(id, catalog), do: {id, submitted_fields(params, id, catalog)}
  end

  defp opened_post(attrs, _params, catalog) do
    with {:changed, %{template: id, fields: fields}} <- Post.decode(attrs["description"]),
         true <- PostTemplates.form?(id, catalog) do
      {id, fields}
    else
      _other -> nil
    end
  end

  # Only the template's own fields: on every change the browser also sends
  # `_unused_<field>` for each input the author has not touched yet.
  defp submitted_fields(params, id, catalog) do
    template = PostTemplates.template(id, catalog)

    params
    |> Map.get("fields", %{})
    |> fields_map()
    |> Map.take(PostTemplates.field_keys(id, catalog))
    |> Map.new(fn {key, value} -> {key, clean(value)} end)
    |> edit_items(params, template)
    |> clear_image(params)
  end

  defp fields_map(%{} = fields), do: fields
  defp fields_map(_other), do: %{}

  defp clean(value) when is_binary(value), do: without_returns(value)
  defp clean(values) when is_list(values), do: for(v <- values, is_binary(v), do: clean(v))
  defp clean(_value), do: ""

  # A form sends `\r\n`, while a description keeps `\n`.
  defp without_returns(text), do: String.replace(text, "\r", "")

  # A row is added to a list, or taken out of it: a list of items, or
  # pictures with their captions, which stay in step. The list of a built-in
  # template's older buttons is `items`.
  defp edit_items(fields, %{"add_item" => key}, template) do
    case list_field(template, key) do
      %{kind: :pictures, key: key, captions: captions} ->
        count = min(length(List.wrap(fields[key])) + 1, PostTemplates.max_pictures())

        fields
        |> Map.put(key, pad(fields[key], count))
        |> Map.put(captions, pad(fields[captions], count))

      %{kind: :items, key: key} ->
        Map.update(fields, key, [""], fn items ->
          Enum.take(List.wrap(items) ++ [""], max_items(template))
        end)

      nil ->
        fields
    end
  end

  defp edit_items(fields, %{"remove_item" => target}, template) do
    {key, index} =
      case String.split(to_string(target), ":", parts: 2) do
        [key, index] -> {key, index}
        [index] -> {"items", index}
      end

    with {index, ""} <- Integer.parse(index),
         %{} = field <- list_field(template, key) do
      remove_row(fields, field, index)
    else
      _invalid -> fields
    end
  end

  defp edit_items(fields, _params, _template), do: fields

  defp remove_row(fields, %{kind: :pictures, key: key, captions: captions}, index) do
    count = length(List.wrap(fields[key]))

    fields
    |> Map.put(key, List.delete_at(pad(fields[key], count), index))
    |> Map.put(captions, List.delete_at(pad(fields[captions], count), index))
  end

  defp remove_row(fields, %{kind: :items, key: key}, index),
    do: Map.update(fields, key, [], &List.delete_at(List.wrap(&1), index))

  # A list field of the template by its key; "1" is the add button of a
  # built-in list, sent before buttons named their field.
  defp list_field(template, "1"), do: list_field(template, "items")

  defp list_field(%{fields: fields}, key) do
    Enum.find(fields, &(&1.key == key and &1.kind in [:items, :pictures]))
  end

  defp list_field(_template, _key), do: nil

  defp max_items(%{custom: _custom}), do: Custom.max_items()
  defp max_items(_template), do: PostTemplates.max_items()

  # Exactly `count` entries: a list sent short gets empty ones, a long one is cut.
  defp pad(values, count) do
    values = values |> List.wrap() |> Enum.filter(&is_binary/1)
    Enum.take(values ++ List.duplicate("", max(count - length(values), 0)), count)
  end

  # The picture's key; "1" from a built-in template's button is its `image`.
  defp clear_image(fields, %{"clear_image" => key}) when key in ["1", ""],
    do: Map.delete(fields, "image")

  defp clear_image(fields, %{"clear_image" => key}), do: Map.delete(fields, key)
  defp clear_image(fields, _params), do: fields

  defp same_as_saved?(saved, id, fields, catalog) do
    case Post.decode(saved) do
      {:post, %{template: ^id, fields: saved_fields}} ->
        comparable(saved_fields, id, catalog) == comparable(fields, id, catalog)

      _other ->
        false
    end
  end

  # What a form cannot tell apart: a field left out and one left empty, and a
  # level FeedCreator never wrote and the first of the select.
  defp comparable(fields, id, catalog) do
    fields
    |> Map.take(PostTemplates.field_keys(id, catalog))
    |> Enum.flat_map(fn
      {"level", "info"} -> []
      {key, value} -> comparable_field(key, clean(value))
    end)
    |> Map.new()
  end

  defp comparable_field(_key, ""), do: []

  defp comparable_field(key, values) when is_list(values) do
    case Enum.reject(values, &(String.trim(&1) == "")) do
      [] -> []
      filled -> [{key, filled}]
    end
  end

  defp comparable_field(key, value) do
    if String.trim(value) == "", do: [], else: [{key, value}]
  end
end
