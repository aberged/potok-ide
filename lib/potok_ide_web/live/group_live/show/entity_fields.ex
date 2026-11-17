defmodule PotokIdeWeb.GroupLive.Show.EntityFields do
  @moduledoc """
  The attributes of an entity as the forms of a drawn process ask for them:
  the form a step asks a person to fill in (`ProcessForm`) and the Start of a
  process started by hand (`ProcessesState`). A plain attribute is an input
  of its type; an attribute that holds another entity is a framed group of
  that entity's attributes; a list is a row per item, with × to take one
  out and a button to add one, up to `PotokIde.Processes.Types`'s limit.

  An input is named by the path to it, `answers[stavke][0][naziv]`, so what
  the form sends is a map of the same shape, where a list is a map by
  index. `params/4` makes that map from values a form starts with, `value/3`
  turns what came back into what `Types.cast/4` reads (lists, and nothing
  for an item or an entity left wholly empty), and `add/4` and `remove/3`
  change a list of the map a form holds.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Processes.Types

  # As `Types` lets a list hold.
  @max_items 200
  @max_field 1_000

  @doc """
  What a form starts with for `attributes` (with the entities they name,
  `types`), from `values` as a run keeps them: a time in the viewer's
  `zone`, as its input takes it. A list starts with one empty item to
  fill in.
  """
  def params(attributes, types, values, zone) do
    values = if is_map(values), do: values, else: %{}

    Map.new(attributes, fn %{"name" => name} = attribute ->
      {name, attribute_params(attribute, types, values[name], zone)}
    end)
  end

  defp attribute_params(%{"list" => true} = attribute, types, values, zone) do
    item = Map.delete(attribute, "list")

    case values do
      [_ | _] = items ->
        items
        |> Enum.take(@max_items)
        |> Enum.with_index()
        |> Map.new(fn {value, i} ->
          {to_string(i), attribute_params(item, types, value, zone)}
        end)

      _none ->
        %{"0" => attribute_params(item, types, nil, zone)}
    end
  end

  defp attribute_params(%{"type" => "entity", "entity" => id}, types, value, zone) do
    params(Types.attributes(types, id) || [], types, value, zone)
  end

  defp attribute_params(%{"type" => type}, _types, value, zone),
    do: input_value(value, type, zone)

  # What an input starts with: a time in the viewer's own zone, as they read
  # it and as the form sends it back.
  defp input_value(nil, _type, _zone), do: ""
  defp input_value(true, _type, _zone), do: "true"
  defp input_value(false, _type, _zone), do: ""

  defp input_value(value, "datetime", zone) when is_binary(value) do
    with {:ok, instant, _offset} <- DateTime.from_iso8601(value),
         {:ok, local} <- DateTime.shift_zone(instant, zone || "Etc/UTC") do
      Calendar.strftime(local, "%Y-%m-%dT%H:%M")
    else
      _unreadable -> ""
    end
  end

  defp input_value(value, _type, _zone) when is_map(value) or is_list(value), do: ""
  defp input_value(value, _type, _zone), do: to_string(value)

  @doc """
  What a form sent for `attributes`, as `Types.cast/4` reads it: texts
  trimmed, a list in the order of its items, with those left empty out, and
  an entity left wholly empty as none.
  """
  def value(attributes, types, params) do
    params = if is_map(params), do: params, else: %{}

    Map.new(attributes, fn %{"name" => name} = attribute ->
      {name, attribute_value(attribute, types, params[name])}
    end)
  end

  defp attribute_value(%{"list" => true} = attribute, types, params) do
    item = Map.delete(attribute, "list")

    params
    |> indexed()
    |> Enum.map(&attribute_value(item, types, &1))
    |> Enum.reject(&blank?/1)
  end

  defp attribute_value(%{"type" => "entity", "entity" => id}, types, params) do
    value = value(Types.attributes(types, id) || [], types, params)
    if Enum.all?(Map.values(value), &blank?/1), do: nil, else: value
  end

  defp attribute_value(_attribute, _types, text) when is_binary(text),
    do: text |> String.trim() |> String.slice(0, @max_field)

  defp attribute_value(_attribute, _types, _other), do: nil

  # The items of a list as a form sends them, by index, in their order.
  defp indexed(params) when is_map(params) do
    params
    |> Enum.flat_map(fn {key, value} ->
      case Integer.parse(to_string(key)) do
        {i, ""} -> [{i, value}]
        _other -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp indexed(_params), do: []

  # An unticked box sends "false": on its own it says nothing was filled in.
  defp blank?(value), do: value in [nil, "", [], "false", false] or value == %{}

  @doc """
  `params` with one more item in the list at `path` (a list of names and
  indexes, as `remove/3` and the buttons give it), an empty one of what
  the list holds; as it was when the list is full or `path` names none.
  """
  def add(params, path, attributes, types) do
    with %{} = attribute <- attribute_at(attributes, types, path),
         true <- attribute["list"] == true,
         items when is_map(items) <- at(params, path) || %{},
         true <- map_size(items) < @max_items do
      next =
        items
        |> Map.keys()
        |> Enum.flat_map(&List.wrap(parse_index(&1)))
        |> Enum.max(fn -> -1 end)
        |> Kernel.+(1)
        |> to_string()

      item = attribute_params(Map.delete(attribute, "list"), types, nil, nil)
      put_in(params, Enum.map(path, &Access.key(&1, %{})), Map.put(items, next, item))
    else
      _not_a_list -> params
    end
  end

  @doc "`params` without the item `index` of the list at `path`."
  def remove(params, path, index) do
    case at(params, path) do
      %{} = items ->
        put_in(params, Enum.map(path, &Access.key(&1, %{})), Map.delete(items, index))

      _none ->
        params
    end
  end

  # The attribute a path of names and indexes leads to.
  defp attribute_at(attributes, types, [name | rest]) do
    case Enum.find(attributes, &(&1["name"] == name)) do
      nil -> nil
      attribute -> attribute_rest(attribute, types, rest)
    end
  end

  defp attribute_at(_attributes, _types, []), do: nil

  defp attribute_rest(attribute, _types, []), do: attribute

  # Past a list, an index; past an entity, one of its attributes.
  defp attribute_rest(%{"list" => true} = attribute, types, [index | rest]) do
    if parse_index(index), do: attribute_rest(Map.delete(attribute, "list"), types, rest)
  end

  defp attribute_rest(%{"type" => "entity", "entity" => id}, types, rest),
    do: attribute_at(Types.attributes(types, id) || [], types, rest)

  defp attribute_rest(_plain, _types, _rest), do: nil

  defp parse_index(key) do
    case Integer.parse(to_string(key)) do
      {i, ""} when i >= 0 -> i
      _other -> nil
    end
  end

  @doc """
  The path of an attribute as an error of `Types.cast/4` names it
  (`stavke.1.kolicina`) for what the form holds, where a list's items are
  keyed by their own index, not by their place.
  """
  def error_path(attributes, types, params, dotted) when is_binary(dotted) do
    dotted |> String.split(".") |> keyed(attributes, types, params, [])
  end

  def error_path(_attributes, _types, _params, _dotted), do: nil

  defp keyed([], _attributes, _types, _params, acc), do: Enum.reverse(acc)

  defp keyed([name | rest], attributes, types, params, acc) do
    case Enum.find(attributes, &(&1["name"] == name)) do
      nil -> nil
      attribute -> keyed_value(rest, attribute, types, (params || %{})[name], [name | acc])
    end
  end

  defp keyed_value([], _attribute, _types, _params, acc), do: Enum.reverse(acc)

  # The n-th item that was sent, as `value/3` kept them, is its own key here.
  defp keyed_value([place | rest], %{"list" => true} = attribute, types, params, acc) do
    item = Map.delete(attribute, "list")

    kept =
      params
      |> keys_in_order()
      |> Enum.reject(fn key -> blank?(attribute_value(item, types, params[key])) end)

    with {n, ""} <- Integer.parse(place),
         key when is_binary(key) <- Enum.at(kept, n) do
      keyed_value(rest, item, types, params[key], [key | acc])
    else
      _gone -> nil
    end
  end

  defp keyed_value(rest, %{"type" => "entity", "entity" => id}, types, params, acc),
    do: keyed(rest, Types.attributes(types, id) || [], types, params, acc)

  defp keyed_value(_rest, _plain, _types, _params, _acc), do: nil

  defp keys_in_order(params) when is_map(params) do
    params
    |> Map.keys()
    |> Enum.filter(&parse_index/1)
    |> Enum.sort_by(&parse_index/1)
  end

  defp keys_in_order(_params), do: []

  attr :prefix, :string, required: true, doc: "what the form names its inputs under: `answers`"
  attr :id_prefix, :string, required: true
  attr :attributes, :list, required: true
  attr :types, :map, required: true
  attr :params, :map, required: true
  attr :path, :list, default: []
  attr :error, :any, default: nil, doc: "`{path, text}` of the attribute that is not right"
  attr :add, :string, required: true, doc: "the event that adds an item to a list"
  attr :remove, :string, required: true, doc: "the event that takes one out"

  @doc "The inputs of `attributes`, each as its type."
  def fields(assigns) do
    ~H"""
    <.attribute
      :for={attribute <- @attributes}
      attribute={attribute}
      prefix={@prefix}
      id_prefix={@id_prefix}
      types={@types}
      params={@params}
      path={@path ++ [attribute["name"]]}
      error={@error}
      add={@add}
      remove={@remove}
    />
    """
  end

  attr :attribute, :map, required: true
  attr :prefix, :string, required: true
  attr :id_prefix, :string, required: true
  attr :types, :map, required: true
  attr :params, :map, required: true
  attr :path, :list, required: true
  attr :error, :any, default: nil
  attr :add, :string, required: true
  attr :remove, :string, required: true

  defp attribute(%{attribute: %{"list" => true} = attribute} = assigns) do
    items = assigns.params |> at(assigns.path) |> keys_in_order()

    assigns =
      assigns
      |> assign(:item, Map.delete(attribute, "list"))
      |> assign(:items, items)
      |> assign(:full?, length(items) >= @max_items)

    ~H"""
    <fieldset
      id={field_id(@id_prefix, @path)}
      class="space-y-2 rounded-2xl border border-base-300/70 p-3"
    >
      <legend class="px-1 text-sm font-medium">{label(@attribute)}</legend>
      <div
        :for={key <- @items}
        id={field_id(@id_prefix, @path ++ [key]) <> "-item"}
        class="flex items-start gap-1.5"
      >
        <div class={["min-w-0 flex-1", @item["type"] == "entity" && "rounded-xl bg-base-200/50 p-2"]}>
          <.attribute
            attribute={Map.put(@item, "name", "")}
            prefix={@prefix}
            id_prefix={@id_prefix}
            types={@types}
            params={@params}
            path={@path ++ [key]}
            error={@error}
            add={@add}
            remove={@remove}
          />
        </div>
        <.icon_button
          id={field_id(@id_prefix, @path ++ [key]) <> "-remove"}
          type="button"
          phx-click={@remove}
          phx-value-path={Enum.join(@path, ".")}
          phx-value-index={key}
          icon="hero-x-mark"
          label={gettext("Remove")}
          class="mt-1"
        />
      </div>
      <button
        :if={!@full?}
        id={field_id(@id_prefix, @path) <> "-add"}
        type="button"
        phx-click={@add}
        phx-value-path={Enum.join(@path, ".")}
        class="inline-flex items-center gap-1 rounded-full bg-base-200 px-3 py-1 text-xs font-medium text-base-content/75 transition hover:bg-primary/15 hover:text-primary active:scale-95"
      >
        <.icon name="hero-plus" class="size-3.5" />
        {gettext("Add")}
      </button>
    </fieldset>
    """
  end

  defp attribute(%{attribute: %{"type" => "entity", "entity" => id}} = assigns) do
    assigns = assign(assigns, :held, Types.attributes(assigns.types, id) || [])

    ~H"""
    <fieldset
      id={field_id(@id_prefix, @path)}
      class={["space-y-2", @attribute["name"] != "" && "rounded-2xl border border-base-300/70 p-3"]}
    >
      <legend :if={@attribute["name"] != ""} class="px-1 text-sm font-medium">
        {label(@attribute)}
      </legend>
      <.fields
        prefix={@prefix}
        id_prefix={@id_prefix}
        attributes={@held}
        types={@types}
        params={@params}
        path={@path}
        error={@error}
        add={@add}
        remove={@remove}
      />
    </fieldset>
    """
  end

  defp attribute(assigns) do
    assigns =
      assigns
      |> assign(:name, input_name(assigns.prefix, assigns.path))
      |> assign(:id, field_id(assigns.id_prefix, assigns.path))
      |> assign(:value, at(assigns.params, assigns.path) || "")
      |> assign(:label, label(assigns.attribute))
      # Inside a list or an entity it holds, an empty item is left out: the
      # browser must not hold the form back over it.
      |> assign(:required?, assigns.attribute["required"] == true and length(assigns.path) == 1)
      |> assign(:errors, errors(assigns.error, assigns.path))

    ~H"""
    <%= case @attribute["type"] do %>
      <% "boolean" -> %>
        <.input type="checkbox" id={@id} name={@name} value={@value} label={@label} errors={@errors} />
      <% "date" -> %>
        <.input
          type="date"
          id={@id}
          name={@name}
          value={@value}
          label={@label}
          required={@required?}
          errors={@errors}
        />
      <% "datetime" -> %>
        <.input
          type="datetime-local"
          id={@id}
          name={@name}
          value={@value}
          label={@label}
          required={@required?}
          errors={@errors}
        />
      <% "choice" -> %>
        <.input
          type="select"
          id={@id}
          name={@name}
          value={@value}
          label={@label}
          prompt={gettext("Pick one")}
          options={@attribute["options"] || []}
          required={@required?}
          errors={@errors}
        />
      <% "number" -> %>
        <.input
          type="text"
          id={@id}
          name={@name}
          value={@value}
          label={@label}
          placeholder="0"
          maxlength="40"
          inputmode="decimal"
          required={@required?}
          errors={@errors}
        />
      <% _text -> %>
        <.input
          type="text"
          id={@id}
          name={@name}
          value={@value}
          label={@label}
          maxlength="1000"
          required={@required?}
          errors={@errors}
        />
    <% end %>
    """
  end

  # An item of a list has no label of its own: the list's stands over it.
  defp label(%{"name" => ""}), do: nil

  defp label(%{"name" => name} = attribute),
    do: name <> if(attribute["required"] == true, do: " *", else: "")

  defp field_id(id_prefix, path), do: Enum.join([id_prefix | path], "-")

  defp input_name(prefix, path), do: prefix <> Enum.map_join(path, &"[#{&1}]")

  # What the form holds at a path, or nil where it holds something else.
  defp at(value, []), do: value
  defp at(%{} = map, [key | rest]), do: at(Map.get(map, key), rest)
  defp at(_other, _path), do: nil

  defp errors({path, text}, path), do: [text]
  defp errors(_error, _path), do: []

  @doc "The path a button names (`stavke.0.delovi`), as `add/4` and `remove/3` take it."
  def parse_path(text) when is_binary(text), do: String.split(text, ".", trim: true)
  def parse_path(_text), do: []
end
