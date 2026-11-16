defmodule PotokIde.Processes.Types do
  @moduledoc """
  The types of what the processes drawn in a group work with: what an
  attribute of an entity (`PotokIde.Processes.GroupEntity`) may hold, and
  what the names of a process stand for (`PotokIde.Processes.Scope`).

  - `text`, `number`, `boolean`, `date` and `datetime` hold one plain value.
  - `choice` holds one of the `options` the attribute lists.
  - `entity` holds another entity of the same group, by its id.

  Any of them may be a list. Entities nest at most #{4} deep and never in a
  circle, so a value of one always has an end.

  Names of attributes are written in the texts and conditions of a process,
  so they are plain: a letter or `_`, then letters, digits and `_`, up to 40,
  and none of the words a process keeps for itself (`reserved/0`).

  ## Types as terms

  A stored type is a map, as an attribute keeps it (`%{"type" => "number",
  "list" => true}`). Checking and running work on terms (`of/1`, back with
  `json/1`): `:text`, `:number`, `:boolean`, `:date`, `:datetime`,
  `{:choice, options}`, `{:entity, id}`, `{:list, type}`, and three no
  attribute has:

  - `{:record, fields, open?}`: named fields that no entity defines, such as
    what a decision brings back. An open one may hold more than it names.
  - `:any`: what Potok does not know the type of, such as a field of an
    app's value. It goes anywhere and is read as it comes.
  - `:empty`: no value, which goes anywhere.

  ## Values

  At rest a value is JSON: a number is a plain decimal text (`"12.5"`), a
  date `"2026-11-16"`, a date and time an ISO 8601 instant in UTC. While a
  step works on it, it is a `Decimal`, a `Date` or a `DateTime` (`cast/4`,
  `load/3`, back with `dump/1`), so numbers stay exact and dates compare as
  dates. `text/2` is how a value reads in a text.
  """

  @kinds ~w(text number boolean date datetime choice entity)
  @name_format ~r/^[\p{L}_][\p{L}\p{Nd}_]{0,39}$/u
  # What a run always gets beside its fields, and the words of a condition.
  @reserved ~w(from signal outcome author and or not true false empty)
  @max_depth 4
  @max_items 200
  @max_number 40
  @number_format ~r/^-?\d+(\.\d+)?$/
  @local_date ~r/^(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})\.?$/

  @doc "Every type an attribute may have, in the order the editor offers them."
  def kinds, do: @kinds

  @doc "The words no attribute may be named."
  def reserved, do: @reserved

  @doc "How deep entities may nest: an entity with plain attributes is 1 deep."
  def max_depth, do: @max_depth

  @doc "How many items a list may hold."
  def max_items, do: @max_items

  @doc "Whether `name` may name an attribute."
  def name?(name) when is_binary(name),
    do: Regex.match?(@name_format, name) and name not in @reserved

  def name?(_name), do: false

  @doc """
  Checks how the entities of a group nest, given the entities each holds as
  `%{id => [id]}`: `:ok`, `{:error, :cycle}` when one comes back to itself,
  or `{:error, :too_deep}` past #{@max_depth} levels. An id the map does not
  know holds nothing.
  """
  def nesting(holds) when is_map(holds) do
    Enum.reduce_while(Map.keys(holds), :ok, fn id, :ok ->
      case depth(holds, id, []) do
        :cycle -> {:halt, {:error, :cycle}}
        depth when depth > @max_depth -> {:halt, {:error, :too_deep}}
        _depth -> {:cont, :ok}
      end
    end)
  end

  defp depth(holds, id, path) do
    if id in path do
      :cycle
    else
      holds
      |> Map.get(id, [])
      |> Enum.reduce_while(0, fn held, deepest ->
        case depth(holds, held, [id | path]) do
          :cycle -> {:halt, :cycle}
          depth -> {:cont, max(deepest, depth)}
        end
      end)
      |> case do
        :cycle -> :cycle
        deepest -> deepest + 1
      end
    end
  end

  # ---------
  # Types as terms
  # ---------

  @doc "The type a stored description names, as a term. What it cannot read is `:any`."
  def of(%{"list" => true} = type), do: {:list, of(Map.put(type, "list", false))}
  def of(%{"type" => "text"}), do: :text
  def of(%{"type" => "number"}), do: :number
  def of(%{"type" => "boolean"}), do: :boolean
  def of(%{"type" => "date"}), do: :date
  def of(%{"type" => "datetime"}), do: :datetime
  def of(%{"type" => "choice"} = type), do: {:choice, type["options"] || []}
  def of(%{"type" => "entity", "entity" => id}) when is_integer(id), do: {:entity, id}

  def of(%{"type" => "record", "fields" => fields} = type) when is_map(fields),
    do:
      {:record, Map.new(fields, fn {name, field} -> {name, of(field)} end), type["open"] == true}

  def of(_unknown), do: :any

  @doc "A type as it is stored: the map `of/1` reads back."
  def json({:list, type}), do: Map.put(json(type), "list", true)
  def json(:text), do: %{"type" => "text"}
  def json(:number), do: %{"type" => "number"}
  def json(:boolean), do: %{"type" => "boolean"}
  def json(:date), do: %{"type" => "date"}
  def json(:datetime), do: %{"type" => "datetime"}
  def json({:choice, options}), do: %{"type" => "choice", "options" => options}
  def json({:entity, id}), do: %{"type" => "entity", "entity" => id}

  def json({:record, fields, open?}) do
    %{
      "type" => "record",
      "fields" => Map.new(fields, fn {name, type} -> {name, json(type)} end),
      "open" => open?
    }
  end

  def json(_any_or_empty), do: %{"type" => "any"}

  @doc """
  The attributes of the entity `id`, as `entities` keeps them (`%{"12" =>
  %{"name" => _, "attributes" => [_]}}`, the entities a graph was saved
  with), or nil.
  """
  def attributes(entities, id) when is_map(entities) do
    case Map.get(entities, to_string(id)) do
      %{"attributes" => attributes} when is_list(attributes) -> attributes
      _unknown -> nil
    end
  end

  @doc """
  Whether a value of the type `actual` may go where `expected` is asked for.
  What is unknown or empty goes anywhere, and a choice is a text.
  """
  def fits?(_actual, :any), do: true
  def fits?(:any, _expected), do: true
  def fits?(:empty, _expected), do: true
  def fits?(type, type), do: true
  def fits?({:choice, _options}, :text), do: true
  def fits?(:text, {:choice, _options}), do: true
  def fits?({:choice, _options}, {:choice, _others}), do: true
  def fits?({:list, actual}, {:list, expected}), do: fits?(actual, expected)
  def fits?(_actual, _expected), do: false

  @doc """
  The same, knowing the `entities` the types name: an entity also takes
  what holds each of its attributes, such as what set a run going, whatever
  else that holds.
  """
  def fits?({:record, fields, _open?}, {:entity, id}, entities) do
    case attributes(entities, id) do
      nil ->
        false

      attributes ->
        Enum.all?(attributes, fn %{"name" => name} = attribute ->
          case Map.fetch(fields, name) do
            {:ok, type} -> fits?(type, of(attribute), entities)
            :error -> false
          end
        end)
    end
  end

  # So does another entity that holds each of its attributes, as the entity
  # of one group may mirror what a process of another takes.
  def fits?({:entity, given}, {:entity, wanted}, entities) when given != wanted do
    case attributes(entities, given) do
      nil ->
        false

      attributes ->
        fields = Map.new(attributes, &{&1["name"], of(&1)})
        fits?({:record, fields, false}, {:entity, wanted}, entities)
    end
  end

  def fits?({:list, actual}, {:list, expected}, entities), do: fits?(actual, expected, entities)
  def fits?(actual, expected, _entities), do: fits?(actual, expected)

  @doc """
  Whether a value of the type is written as a text, which may hold
  expressions between `{{` and `}}`; every other is written as one
  expression.
  """
  def textual?(:text), do: true
  def textual?({:choice, _options}), do: true
  def textual?(_type), do: false

  # ---------
  # Values
  # ---------

  @doc """
  A value as a step works on it, from what came in: a form's text, JSON at
  rest, or a value a step made. Returns `{:ok, value}` or `{:error, {reason,
  path}}`, the path naming where in an entity or a list it went wrong (`""`
  for the value itself). Nothing (nil, or a blank where no text is asked
  for) is no value.

  - `:zone` reads a time without an offset (a form's `2026-11-16T14:30`) as
    local to it; UTC otherwise.
  - `required: true` refuses an entity that lacks a required attribute.
  """
  def cast(value, type, entities \\ %{}, opts \\ []), do: cast(value, type, entities, opts, "")

  defp cast(nil, _type, _entities, _opts, _path), do: {:ok, nil}
  defp cast(value, type, _entities, _opts, _path) when type in [:any, :empty], do: {:ok, value}

  defp cast(value, :text, _entities, opts, path) do
    cond do
      is_binary(value) -> {:ok, value}
      is_list(value) or (is_map(value) and not is_struct(value)) -> {:error, {:not_a_text, path}}
      true -> {:ok, text(value, opts[:zone] || "Etc/UTC")}
    end
  end

  defp cast(value, _type, _entities, _opts, _path) when is_binary(value) and value == "",
    do: {:ok, nil}

  defp cast(value, :number, _entities, _opts, path) do
    case number(value) do
      {:ok, number} -> {:ok, number}
      :error -> {:error, {:not_a_number, path}}
    end
  end

  defp cast(value, :boolean, _entities, _opts, path) do
    case value do
      true -> {:ok, true}
      false -> {:ok, false}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, {:not_a_boolean, path}}
    end
  end

  defp cast(%Date{} = date, :date, _entities, _opts, _path), do: {:ok, date}
  defp cast(%DateTime{} = at, :date, _entities, _opts, _path), do: {:ok, DateTime.to_date(at)}

  defp cast(value, :date, _entities, _opts, path) when is_binary(value) do
    text = String.trim(value)

    with {:error, _} <- Date.from_iso8601(String.slice(text, 0, 10)),
         [_, day, month, year] <- Regex.run(@local_date, text),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      {:ok, date}
    else
      {:ok, %Date{} = date} -> {:ok, date}
      _not_a_date -> {:error, {:not_a_date, path}}
    end
  end

  defp cast(%DateTime{} = at, :datetime, _entities, _opts, _path),
    do: {:ok, DateTime.shift_zone!(at, "Etc/UTC")}

  defp cast(value, :datetime, _entities, opts, path) when is_binary(value) do
    text = String.trim(value)

    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} ->
        {:ok, DateTime.truncate(at, :second)}

      {:error, _no_offset} ->
        with {:ok, naive} <- naive(text),
             {:ok, at} <- local(naive, opts[:zone] || "Etc/UTC") do
          {:ok, at}
        else
          _not_a_time -> {:error, {:not_a_datetime, path}}
        end
    end
  end

  defp cast(value, {:choice, options}, _entities, _opts, path) do
    if is_binary(value) and value in options,
      do: {:ok, value},
      else: {:error, {:not_an_option, path}}
  end

  defp cast(values, {:list, type}, entities, opts, path) when is_list(values) do
    if length(values) > @max_items do
      {:error, {:too_many_items, path}}
    else
      values
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {value, i}, {:ok, acc} ->
        case cast(value, type, entities, opts, join(path, i)) do
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  defp cast(value, {:entity, id}, entities, opts, path)
       when is_map(value) and not is_struct(value) do
    case attributes(entities, id) do
      nil ->
        {:error, {:unknown_entity, path}}

      attributes ->
        Enum.reduce_while(attributes, {:ok, %{}}, fn %{"name" => name} = attribute, {:ok, acc} ->
          at = join(path, name)

          case cast(Map.get(value, name), of(attribute), entities, opts, at) do
            {:ok, held} ->
              if blank?(held) and attribute["required"] == true and opts[:required] == true,
                do: {:halt, {:error, {:required, at}}},
                else: {:cont, {:ok, Map.put(acc, name, held)}}

            error ->
              {:halt, error}
          end
        end)
    end
  end

  defp cast(value, {:record, fields, open?}, entities, opts, path)
       when is_map(value) and not is_struct(value) do
    base = if open?, do: value, else: %{}

    Enum.reduce_while(fields, {:ok, base}, fn {name, type}, {:ok, acc} ->
      case cast(Map.get(value, name), type, entities, opts, join(path, name)) do
        {:ok, held} -> {:cont, {:ok, Map.put(acc, name, held)}}
        error -> {:halt, error}
      end
    end)
  end

  defp cast(_value, type, _entities, _opts, path), do: {:error, {mismatch(type), path}}

  defp mismatch(:date), do: :not_a_date
  defp mismatch(:datetime), do: :not_a_datetime
  defp mismatch({:list, _type}), do: :not_a_list
  defp mismatch(_entity_or_record), do: :not_an_entity

  defp join("", name), do: to_string(name)
  defp join(path, name), do: "#{path}.#{name}"

  defp blank?(value), do: value in [nil, "", []]

  defp naive(text) do
    # A form's time has no seconds.
    text =
      if Regex.match?(~r/^\d{4}-\d\d-\d\d[T ]\d\d:\d\d$/, text), do: text <> ":00", else: text

    NaiveDateTime.from_iso8601(text)
  end

  # A local time that falls in a gap or twice takes the later instant.
  defp local(naive, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> {:ok, at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
      {:ambiguous, _first, at} -> {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
      {:gap, _before, at} -> {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
      {:error, _reason} -> :error
    end
  end

  @doc """
  A value kept at rest, as a step works on it: `cast/4` that never fails.
  What does not fit its type any more, after its entity changed, stays as
  it was kept.
  """
  def load(value, type, entities \\ %{}) do
    case cast(value, type, entities, []) do
      {:ok, loaded} -> loaded
      {:error, _reason} -> value
    end
  end

  @doc "A value as it is kept at rest: plain JSON."
  def dump(%Decimal{} = number), do: number_text(number)
  def dump(%Date{} = date), do: Date.to_iso8601(date)
  def dump(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def dump(values) when is_list(values), do: Enum.map(values, &dump/1)

  def dump(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {name, held} -> {name, dump(held)} end)

  def dump(value), do: value

  @doc """
  A number from what may be one: a `Decimal`, a whole or a decimal number,
  or a text that holds a plain one, with a dot or a comma (`"12,5"`).
  `:error` otherwise.
  """
  def number(%Decimal{} = number), do: {:ok, number}
  def number(number) when is_integer(number), do: {:ok, Decimal.new(number)}
  def number(number) when is_float(number), do: {:ok, Decimal.from_float(number)}

  def number(text) when is_binary(text) do
    text = text |> String.trim() |> String.replace(",", ".")

    if byte_size(text) <= @max_number and Regex.match?(@number_format, text),
      do: {:ok, Decimal.new(text)},
      else: :error
  end

  def number(_other), do: :error

  @doc "A number as a text: plain digits, without the zeros that say nothing."
  def number_text(%Decimal{} = number),
    do: number |> Decimal.normalize() |> Decimal.to_string(:normal)

  @doc """
  How a value reads in a text. A date reads as `16. 11. 2026.`, and a date
  and time the same with the hour, in `zone`. Nothing reads as nothing, a
  list as its items after one another, and an entity as nothing: a text
  names the attribute it wants.
  """
  def text(value, zone \\ "Etc/UTC")
  def text(nil, _zone), do: ""
  def text(value, _zone) when is_binary(value), do: value
  def text(%Decimal{} = number, _zone), do: number_text(number)
  def text(value, _zone) when is_number(value) or is_boolean(value), do: to_string(value)
  def text(%Date{} = date, _zone), do: Calendar.strftime(date, "%d. %m. %Y.")

  def text(%DateTime{} = at, zone) do
    local =
      case DateTime.shift_zone(at, zone) do
        {:ok, local} -> local
        {:error, _unknown_zone} -> at
      end

    Calendar.strftime(local, "%d. %m. %Y. %H:%M")
  end

  def text(values, zone) when is_list(values), do: Enum.map_join(values, ", ", &text(&1, zone))
  def text(_entity, _zone), do: ""
end
