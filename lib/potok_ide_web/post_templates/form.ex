defmodule PotokIdeWeb.PostTemplates.Form do
  @moduledoc """
  Turns what a description's form sends into the description to save.

  The description is the form's only state: its fields are read back from the
  comment on its first line (`Post.decode/1`). The form sends them as
  `description_template` next to the form's own attrs:

    * `id` and `fields`, while a template's form is open
    * `pick`, from a card in the list of templates
    * `add_item`, `remove_item`, `clear_image` and `restore`, from buttons

  An unchanged form gives back the saved description as it is, so opening
  someone's description in another language, or a FeedCreator post, rewrites
  nothing.
  """

  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.PostTemplates.Post

  @doc """
  `attrs` with the description of `params`, and the labels of required fields
  still empty. `saved` is the description in the database. A description that
  is not being changed never stops a save, as its group may have other edits.
  """
  def prepare(attrs, nil, _saved), do: {attrs, []}

  def prepare(attrs, params, saved) do
    attrs = put_description(attrs, params, saved)
    {attrs, missing(attrs["description"], saved)}
  end

  defp missing(description, description), do: []

  defp missing(description, _saved) do
    case Post.decode(description) do
      {:post, %{template: id, fields: fields}} -> PostTemplates.missing_fields(id, fields)
      _other -> []
    end
  end

  defp put_description(attrs, %{"restore" => _restore}, _saved) do
    case Post.decode(attrs["description"]) do
      {:changed, %{template: id, fields: fields}} -> put_post(attrs, id, fields)
      _other -> attrs
    end
  end

  defp put_description(attrs, %{"pick" => id} = params, saved) do
    cond do
      id == params["id"] ->
        put_description(attrs, Map.delete(params, "pick"), saved)

      id == PostTemplates.free_text() ->
        put_free_text(attrs, opened_post(attrs, params))

      PostTemplates.form?(id) ->
        {_id, fields} = opened_post(attrs, params) || {id, %{}}
        put_post(attrs, id, Map.take(fields, field_keys(id)))

      true ->
        attrs
    end
  end

  defp put_description(attrs, %{"id" => id} = params, saved) do
    if PostTemplates.form?(id) do
      fields = submitted_fields(params, id)

      # A new row is empty, so it would otherwise read as no change at all.
      if not Map.has_key?(params, "add_item") and same_as_saved?(saved, id, fields),
        do: put_description_source(attrs, saved),
        else: put_post(attrs, id, fields)
    else
      attrs
    end
  end

  defp put_description(attrs, _params, _saved), do: attrs

  defp put_post(attrs, id, fields) do
    put_description_source(attrs, Post.encode(id, Map.reject(fields, &match?({_key, ""}, &1))))
  end

  defp put_description_source(attrs, description) do
    attrs
    |> Map.put("description", description)
    |> Map.put("description_format", "html")
  end

  # The text stays, as HTML, for the author to go on from.
  defp put_free_text(attrs, nil), do: attrs

  defp put_free_text(attrs, {id, fields}),
    do: put_description_source(attrs, Post.html(id, fields))

  # What the form holds at the moment: the fields of an open form, or those a
  # text changed by hand was made from. Free text has no fields.
  defp opened_post(_attrs, %{"id" => id} = params) do
    if PostTemplates.form?(id), do: {id, submitted_fields(params, id)}
  end

  defp opened_post(attrs, _params) do
    case Post.decode(attrs["description"]) do
      {:changed, %{template: id, fields: fields}} -> {id, fields}
      _other -> nil
    end
  end

  defp field_keys(id), do: Enum.map(PostTemplates.template(id).fields, & &1.key)

  # Only the template's own fields: on every change the browser also sends
  # `_unused_<field>` for each input the author has not touched yet.
  defp submitted_fields(params, id) do
    params
    |> Map.get("fields", %{})
    |> fields_map()
    |> Map.take(field_keys(id))
    |> Map.new(fn {key, value} -> {key, clean(value)} end)
    |> edit_items(params)
    |> clear_image(params)
  end

  defp fields_map(%{} = fields), do: fields
  defp fields_map(_other), do: %{}

  defp clean(value) when is_binary(value), do: without_returns(value)
  defp clean(values) when is_list(values), do: for(v <- values, is_binary(v), do: clean(v))
  defp clean(_value), do: ""

  # A form sends `\r\n`, while a description keeps `\n`.
  defp without_returns(text), do: String.replace(text, "\r", "")

  defp edit_items(fields, %{"add_item" => _add}) do
    Map.update(fields, "items", [""], fn items ->
      Enum.take(List.wrap(items) ++ [""], PostTemplates.max_items())
    end)
  end

  defp edit_items(fields, %{"remove_item" => index}) do
    case Integer.parse(to_string(index)) do
      {index, ""} -> Map.update(fields, "items", [], &List.delete_at(List.wrap(&1), index))
      _invalid -> fields
    end
  end

  defp edit_items(fields, _params), do: fields

  defp clear_image(fields, %{"clear_image" => _clear}), do: Map.delete(fields, "image")
  defp clear_image(fields, _params), do: fields

  defp same_as_saved?(saved, id, fields) do
    case Post.decode(saved) do
      {:post, %{template: ^id, fields: saved_fields}} ->
        comparable(saved_fields, id) == comparable(fields, id)

      _other ->
        false
    end
  end

  # What a form cannot tell apart: a field left out and one left empty, and a
  # level FeedCreator never wrote and the first of the select.
  defp comparable(fields, id) do
    fields
    |> Map.take(field_keys(id))
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
