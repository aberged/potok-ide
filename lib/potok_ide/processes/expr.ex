defmodule PotokIde.Processes.Expr do
  @moduledoc """
  The expressions of a process drawn in Potok: what a condition asks, what a
  value is set to, and what a text puts in between `{{` and `}}`.

      start.sprat + 1
      ukupno > 10 and not start.hitno
      "Kvar: " & start.naslov
      if(empty(odluka.comment), "bez komentara", odluka.comment)

  - A number is written with a dot (`12.5`), a text between quotes, and
    `true`, `false` and `empty` as words.
  - A name stands for what the process holds (`PotokIde.Processes.Scope`):
    `start.naslov` is an attribute, `lista[0]` an item of a list, and
    `start["broj-prijava"]` a field whose name is no plain word.
  - `+ - * /` count, `&` joins texts, `= != < > <= >=` compare, and `and`,
    `or`, `not` join what is true or false. `-` is always a minus: a name
    holds letters, digits and `_` only.
  - `if empty length contains first last sum join text number round today
    now lower upper trim add_days` are the functions.

  An expression is parsed once into a tree (`parse/1`), checked against the
  types of the names a step may use (`check/2`), so a wrong name or a number
  where a text is asked for shows when the drawing is saved, and run on the
  values of a run (`eval/3`), where numbers are `Decimal`s
  (`PotokIde.Processes.Types`). A text with expressions in it is a template
  (`template/1`, `check_template/2`, `render/3`).
  """

  alias PotokIde.Processes.Types

  @max_length 1_000
  @max_depth 40
  @keywords ~w(and or not true false empty)
  @identifier ~r/^[\p{L}_][\p{L}\p{Nd}_]*/u
  @number ~r/^\d+(\.\d+)?/
  @placeholder ~r/\{\{(.*?)\}\}/su
  @double ["\"", "„", "“", "”"]
  @single ["'", "‘", "’", "‚"]
  # Past this a number says nothing a process could use.
  @max_exponent 60
  @max_round 10

  # ---------
  # Parsing
  # ---------

  @doc """
  The tree of an expression, or `{:error, {:syntax, at}}` with the place of
  the first character that does not fit, counted from 0.
  """
  def parse(text) when is_binary(text) do
    if String.length(text) > @max_length do
      {:error, {:syntax, @max_length}}
    else
      try do
        case text |> lex(0, []) |> expression(0) do
          {tree, []} -> {:ok, tree}
          {_tree, [{_kind, _value, at} | _rest]} -> {:error, {:syntax, at}}
        end
      catch
        # It ended where more was due.
        {:syntax, :end} -> {:error, {:syntax, String.length(text)}}
        {:syntax, at} -> {:error, {:syntax, at}}
      end
    end
  end

  def parse(_text), do: {:error, {:syntax, 0}}

  @doc """
  The parts of a text that may hold expressions between `{{` and `}}`: its
  own pieces as texts and each expression as its tree. An error names the
  expression's place in the text.
  """
  def template(text) when is_binary(text) do
    @placeholder
    |> Regex.split(text, include_captures: true)
    |> Enum.reduce_while({:ok, [], 0}, fn part, {:ok, acc, at} ->
      next = at + String.length(part)

      if String.starts_with?(part, "{{") and String.ends_with?(part, "}}") and
           String.length(part) >= 4 do
        case part |> String.slice(2..-3//1) |> parse() do
          {:ok, tree} -> {:cont, {:ok, [tree | acc], next}}
          {:error, {:syntax, inside}} -> {:halt, {:error, {:syntax, at + 2 + inside}}}
        end
      else
        {:cont, {:ok, [part | acc], next}}
      end
    end)
    |> case do
      {:ok, parts, _at} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  def template(_text), do: {:error, {:syntax, 0}}

  defp lex("", _at, acc), do: Enum.reverse(acc)

  defp lex(<<space, rest::binary>>, at, acc) when space in [?\s, ?\t, ?\n, ?\r],
    do: lex(rest, at + 1, acc)

  defp lex("!=" <> rest, at, acc), do: lex(rest, at + 2, [{:op, :!=, at} | acc])
  defp lex("<=" <> rest, at, acc), do: lex(rest, at + 2, [{:op, :<=, at} | acc])
  defp lex(">=" <> rest, at, acc), do: lex(rest, at + 2, [{:op, :>=, at} | acc])
  # As it is written elsewhere; one `=` is enough here.
  defp lex("==" <> rest, at, acc), do: lex(rest, at + 2, [{:op, :=, at} | acc])
  defp lex("+" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :+, at} | acc])
  defp lex("-" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :-, at} | acc])
  defp lex("*" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :*, at} | acc])
  defp lex("/" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :/, at} | acc])
  defp lex("&" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :&, at} | acc])
  defp lex("=" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :=, at} | acc])
  defp lex("<" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :<, at} | acc])
  defp lex(">" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :>, at} | acc])
  defp lex("(" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :open, at} | acc])
  defp lex(")" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :close, at} | acc])
  defp lex("[" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :open_index, at} | acc])
  defp lex("]" <> rest, at, acc), do: lex(rest, at + 1, [{:op, :close_index, at} | acc])
  defp lex("," <> rest, at, acc), do: lex(rest, at + 1, [{:op, :comma, at} | acc])
  defp lex("." <> rest, at, acc), do: lex(rest, at + 1, [{:op, :dot, at} | acc])

  defp lex(text, at, acc) do
    {first, rest} = String.split_at(text, 1)

    cond do
      # A phone's keyboard curls the quotes it is given.
      first in @double ->
        quoted(rest, @double, at + 1, [], at, acc)

      first in @single ->
        quoted(rest, @single, at + 1, [], at, acc)

      match = Regex.run(@number, text) ->
        digits = hd(match)
        rest = binary_part(text, byte_size(digits), byte_size(text) - byte_size(digits))
        lex(rest, at + String.length(digits), [{:number, Decimal.new(digits), at} | acc])

      match = Regex.run(@identifier, text) ->
        name = hd(match)
        rest = binary_part(text, byte_size(name), byte_size(text) - byte_size(name))
        token = if name in @keywords, do: {:word, name, at}, else: {:name, name, at}
        lex(rest, at + String.length(name), [token | acc])

      true ->
        throw({:syntax, at})
    end
  end

  # A text runs to the quote that closes it; `\` keeps the next character.
  defp quoted("", _closing, _at, _text, opened, _acc), do: throw({:syntax, opened})

  defp quoted("\\" <> rest, closing, at, text, opened, acc) do
    case String.split_at(rest, 1) do
      {"", _rest} -> throw({:syntax, opened})
      {"n", rest} -> quoted(rest, closing, at + 2, ["\n" | text], opened, acc)
      {kept, rest} -> quoted(rest, closing, at + 2, [kept | text], opened, acc)
    end
  end

  defp quoted(rest, closing, at, text, opened, acc) do
    {char, rest} = String.split_at(rest, 1)

    if char in closing do
      value = text |> Enum.reverse() |> IO.iodata_to_binary()
      lex(rest, at + 1, [{:text, value, opened} | acc])
    else
      quoted(rest, closing, at + 1, [char | text], opened, acc)
    end
  end

  # expression := or
  defp expression(tokens, depth) when depth > @max_depth, do: throw({:syntax, place(tokens)})
  defp expression(tokens, depth), do: either(tokens, depth)

  defp either(tokens, depth) do
    {left, rest} = both(tokens, depth)
    either(left, rest, depth)
  end

  defp either(left, [{:word, "or", _at} | rest], depth) do
    {right, rest} = both(rest, depth)
    either({:op, :or, left, right}, rest, depth)
  end

  defp either(left, rest, _depth), do: {left, rest}

  defp both(tokens, depth) do
    {left, rest} = negation(tokens, depth)
    both(left, rest, depth)
  end

  defp both(left, [{:word, "and", _at} | rest], depth) do
    {right, rest} = negation(rest, depth)
    both({:op, :and, left, right}, rest, depth)
  end

  defp both(left, rest, _depth), do: {left, rest}

  defp negation([{:word, "not", _at} | rest], depth) when depth <= @max_depth do
    {tree, rest} = negation(rest, depth + 1)
    {{:not, tree}, rest}
  end

  defp negation(tokens, depth), do: comparison(tokens, depth)

  # One comparison at a time: `a < b < c` says nothing.
  defp comparison(tokens, depth) do
    {left, rest} = joined(tokens, depth)

    case rest do
      [{:op, op, _at} | rest] when op in [:=, :!=, :<, :>, :<=, :>=] ->
        {right, rest} = joined(rest, depth)
        {{:op, op, left, right}, rest}

      rest ->
        {left, rest}
    end
  end

  defp joined(tokens, depth) do
    {left, rest} = sum(tokens, depth)
    joined(left, rest, depth)
  end

  defp joined(left, [{:op, :&, _at} | rest], depth) do
    {right, rest} = sum(rest, depth)
    joined({:op, :&, left, right}, rest, depth)
  end

  defp joined(left, rest, _depth), do: {left, rest}

  defp sum(tokens, depth) do
    {left, rest} = product(tokens, depth)
    sum(left, rest, depth)
  end

  defp sum(left, [{:op, op, _at} | rest], depth) when op in [:+, :-] do
    {right, rest} = product(rest, depth)
    sum({:op, op, left, right}, rest, depth)
  end

  defp sum(left, rest, _depth), do: {left, rest}

  defp product(tokens, depth) do
    {left, rest} = signed(tokens, depth)
    product(left, rest, depth)
  end

  defp product(left, [{:op, op, _at} | rest], depth) when op in [:*, :/] do
    {right, rest} = signed(rest, depth)
    product({:op, op, left, right}, rest, depth)
  end

  defp product(left, rest, _depth), do: {left, rest}

  defp signed([{:op, :-, _at} | rest], depth) when depth <= @max_depth do
    {tree, rest} = signed(rest, depth + 1)
    {{:minus, tree}, rest}
  end

  defp signed(tokens, depth) do
    {tree, rest} = primary(tokens, depth)
    path(tree, rest, depth)
  end

  # `.name` and `[index]`, as many as follow.
  defp path(tree, [{:op, :dot, _at}, {kind, name, _name_at} | rest], depth)
       when kind in [:name, :word],
       do: path({:attribute, tree, name}, rest, depth)

  defp path(tree, [{:op, :open_index, _at} | rest], depth) do
    {index, rest} = expression(rest, depth + 1)

    case rest do
      [{:op, :close_index, _at} | rest] -> path({:index, tree, index}, rest, depth)
      rest -> throw({:syntax, place(rest)})
    end
  end

  defp path(_tree, [{:op, :dot, at} | _rest], _depth), do: throw({:syntax, at + 1})
  defp path(tree, rest, _depth), do: {tree, rest}

  defp primary([{:number, number, _at} | rest], _depth), do: {{:value, number}, rest}
  defp primary([{:text, text, _at} | rest], _depth), do: {{:value, text}, rest}
  defp primary([{:word, "true", _at} | rest], _depth), do: {{:value, true}, rest}
  defp primary([{:word, "false", _at} | rest], _depth), do: {{:value, false}, rest}

  defp primary([{:word, "empty", _at}, {:op, :open, _open} | rest], depth),
    do: call("empty", rest, depth)

  defp primary([{:word, "empty", _at} | rest], _depth), do: {{:value, nil}, rest}

  defp primary([{:name, name, _at}, {:op, :open, _open} | rest], depth),
    do: call(name, rest, depth)

  defp primary([{:name, name, _at} | rest], _depth), do: {{:name, name}, rest}

  defp primary([{:op, :open, _at} | rest], depth) do
    {tree, rest} = expression(rest, depth + 1)

    case rest do
      [{:op, :close, _close} | rest] -> {tree, rest}
      rest -> throw({:syntax, place(rest)})
    end
  end

  defp primary(tokens, _depth), do: throw({:syntax, place(tokens)})

  defp call(name, [{:op, :close, _at} | rest], _depth), do: {{:call, name, []}, rest}

  defp call(name, tokens, depth) do
    {arguments, rest} = arguments(tokens, depth + 1, [])
    {{:call, name, arguments}, rest}
  end

  defp arguments(tokens, depth, acc) do
    {tree, rest} = expression(tokens, depth)

    case rest do
      [{:op, :comma, _at} | rest] -> arguments(rest, depth, [tree | acc])
      [{:op, :close, _at} | rest] -> {Enum.reverse([tree | acc]), rest}
      rest -> throw({:syntax, place(rest)})
    end
  end

  # Where the tokens that are left start; past the last one, where it ended.
  defp place([{_kind, _value, at} | _rest]), do: at
  defp place([]), do: :end

  # ---------
  # Checking
  # ---------

  @doc """
  The type of what the expression gives, with `scope.names` as the types of
  the names it may use and `scope.entities` as the entities those types name
  (`Types.attributes/2`). `{:error, reason}` when it cannot be right:

  - `{:unknown_name, name}`, `{:unknown_attribute, name}`,
    `{:unknown_function, name}`, `{:arguments, function}`;
  - `{:mismatch, expected, got}`: `got` is the type found where `expected`
    was asked for (`:number`, `:text`, `:boolean`, `:list`, `:record`,
    `:date`, or a type to match).
  """
  def check(tree, %{names: _names} = scope) do
    {:ok, type(tree, scope)}
  catch
    {:check, reason} -> {:error, reason}
  end

  @doc "Checks every expression of a template; a text takes what any of them gives."
  def check_template(parts, scope) when is_list(parts) do
    Enum.reduce_while(parts, :ok, fn
      part, :ok when is_binary(part) ->
        {:cont, :ok}

      tree, :ok ->
        case check(tree, scope) do
          {:ok, _type} -> {:cont, :ok}
          error -> {:halt, error}
        end
    end)
  end

  defp type({:value, %Decimal{}}, _scope), do: :number
  defp type({:value, value}, _scope) when is_binary(value), do: :text
  defp type({:value, value}, _scope) when is_boolean(value), do: :boolean
  defp type({:value, nil}, _scope), do: :empty

  defp type({:name, name}, scope) do
    case Map.fetch(scope.names, name) do
      {:ok, type} -> type
      :error -> throw({:check, {:unknown_name, name}})
    end
  end

  defp type({:attribute, tree, name}, scope), do: attribute(type(tree, scope), name, scope)

  defp type({:index, tree, index}, scope) do
    case {type(tree, scope), index} do
      {{:list, item}, _index} ->
        expect(index, :number, scope)
        item

      {:any, _index} ->
        type(index, scope)
        :any

      # A field whose name is no plain word.
      {of, {:value, name}} when is_binary(name) ->
        attribute(of, name, scope)

      {of, _index} ->
        throw({:check, {:mismatch, :list, of}})
    end
  end

  defp type({:minus, tree}, scope) do
    expect(tree, :number, scope)
    :number
  end

  defp type({:not, tree}, scope) do
    expect(tree, :boolean, scope)
    :boolean
  end

  defp type({:op, op, left, right}, scope) when op in [:+, :-, :*, :/] do
    expect(left, :number, scope)
    expect(right, :number, scope)
    :number
  end

  defp type({:op, :&, left, right}, scope) do
    printable(left, scope)
    printable(right, scope)
    :text
  end

  defp type({:op, op, left, right}, scope) when op in [:and, :or] do
    expect(left, :boolean, scope)
    expect(right, :boolean, scope)
    :boolean
  end

  defp type({:op, op, left, right}, scope) when op in [:=, :!=] do
    {a, b} = {type(left, scope), type(right, scope)}
    if alike?(a, b), do: :boolean, else: throw({:check, {:mismatch, a, b}})
  end

  defp type({:op, _order, left, right}, scope) do
    {a, b} = {type(left, scope), type(right, scope)}

    cond do
      not ordered?(a) -> throw({:check, {:mismatch, :number, a}})
      not ordered?(b) -> throw({:check, {:mismatch, :number, b}})
      alike?(a, b) -> :boolean
      true -> throw({:check, {:mismatch, a, b}})
    end
  end

  defp type({:call, name, arguments}, scope), do: function(name, arguments, scope)

  defp attribute({:entity, id}, name, scope) do
    attributes = Types.attributes(Map.get(scope, :entities, %{}), id) || []

    case Enum.find(attributes, &(&1["name"] == name)) do
      nil -> throw({:check, {:unknown_attribute, name}})
      attribute -> Types.of(attribute)
    end
  end

  defp attribute({:record, fields, open?}, name, _scope) do
    case Map.fetch(fields, name) do
      {:ok, type} -> type
      :error when open? -> :any
      :error -> throw({:check, {:unknown_attribute, name}})
    end
  end

  defp attribute(:any, _name, _scope), do: :any
  defp attribute(of, _name, _scope), do: throw({:check, {:mismatch, :record, of}})

  defp expect(tree, expected, scope) do
    type = type(tree, scope)
    if Types.fits?(type, expected), do: type, else: throw({:check, {:mismatch, expected, type}})
  end

  # What a text can show: anything but a whole entity.
  defp printable(tree, scope) do
    case type(tree, scope) do
      {:entity, _id} = type -> throw({:check, {:mismatch, :text, type}})
      {:record, _fields, _open?} = type -> throw({:check, {:mismatch, :text, type}})
      type -> type
    end
  end

  defp alike?(a, b), do: Types.fits?(a, b) or Types.fits?(b, a)

  defp ordered?(type),
    do: type in [:number, :text, :date, :datetime, :any, :empty] or match?({:choice, _}, type)

  defp function("if", [condition, then, otherwise], scope) do
    expect(condition, :boolean, scope)
    {a, b} = {type(then, scope), type(otherwise, scope)}

    cond do
      a in [:any, :empty] -> b
      alike?(a, b) -> a
      true -> throw({:check, {:mismatch, a, b}})
    end
  end

  defp function("empty", [tree], scope) do
    type(tree, scope)
    :boolean
  end

  defp function("length", [tree], scope) do
    case type(tree, scope) do
      {:list, _item} -> :number
      type when type in [:text, :any, :empty] -> :number
      type -> throw({:check, {:mismatch, :list, type}})
    end
  end

  defp function("contains", [tree, wanted], scope) do
    case type(tree, scope) do
      {:list, item} -> expect(wanted, item, scope)
      type when type in [:text, :any, :empty] -> printable(wanted, scope)
      type -> throw({:check, {:mismatch, :list, type}})
    end

    :boolean
  end

  defp function(name, [tree], scope) when name in ["first", "last"], do: item(tree, scope)

  defp function("sum", [tree], scope) do
    item = item(tree, scope)
    if Types.fits?(item, :number), do: :number, else: throw({:check, {:mismatch, :number, item}})
  end

  defp function("join", [tree], scope) do
    item(tree, scope)
    :text
  end

  defp function("join", [tree, separator], scope) do
    item(tree, scope)
    expect(separator, :text, scope)
    :text
  end

  defp function("text", [tree], scope) do
    printable(tree, scope)
    :text
  end

  defp function("number", [tree], scope) do
    case type(tree, scope) do
      type when type in [:number, :text, :any, :empty] -> :number
      {:choice, _options} -> :number
      type -> throw({:check, {:mismatch, :number, type}})
    end
  end

  defp function("round", [tree], scope) do
    expect(tree, :number, scope)
    :number
  end

  defp function("round", [tree, places], scope) do
    expect(tree, :number, scope)
    expect(places, :number, scope)
    :number
  end

  defp function("today", [], _scope), do: :date
  defp function("now", [], _scope), do: :datetime

  defp function(name, [tree], scope) when name in ["lower", "upper", "trim"] do
    expect(tree, :text, scope)
    :text
  end

  defp function("add_days", [tree, days], scope) do
    expect(days, :number, scope)

    case type(tree, scope) do
      type when type in [:date, :datetime, :any] -> type
      type -> throw({:check, {:mismatch, :date, type}})
    end
  end

  defp function(name, _arguments, _scope)
       when name in ~w(if empty length contains first last sum join text number round today now
                       lower upper trim add_days),
       do: throw({:check, {:arguments, name}})

  defp function(name, _arguments, _scope), do: throw({:check, {:unknown_function, name}})

  defp item(tree, scope) do
    case type(tree, scope) do
      {:list, item} -> item
      type when type in [:any, :empty] -> :any
      type -> throw({:check, {:mismatch, :list, type}})
    end
  end

  # ---------
  # Running
  # ---------

  @doc """
  What the expression gives on `data`, the values of the names a run holds
  (`Types.load/3`). `opts` may hold `:zone`, the time zone the process
  reads days and hours in, and `:now`. Returns `{:ok, value}` or `{:error,
  reason}`: `:not_a_number`, `:division_by_zero`, `:number_too_large`,
  `:not_a_list` or `:not_a_date`.
  """
  def eval(tree, data, opts \\ %{}) when is_map(data) do
    {:ok, value(tree, data, opts)}
  catch
    {:eval, reason} -> {:error, reason}
  end

  @doc """
  The text of a template on `data`, without the spaces around it. Returns
  `{:ok, text}` or the error of the expression that failed.
  """
  def render(parts, data, opts \\ %{}) when is_list(parts) do
    zone = zone(opts)

    text =
      Enum.map_join(parts, fn
        part when is_binary(part) -> part
        tree -> tree |> value(data, opts) |> Types.text(zone)
      end)

    {:ok, String.trim(text)}
  catch
    {:eval, reason} -> {:error, reason}
  end

  defp zone(opts), do: Map.get(opts, :zone) || "Etc/UTC"
  defp now(opts), do: Map.get(opts, :now) || DateTime.utc_now(:second)

  defp value({:value, value}, _data, _opts), do: value
  defp value({:name, name}, data, _opts), do: Map.get(data, name)

  defp value({:attribute, tree, name}, data, opts) do
    case value(tree, data, opts) do
      %{} = held when not is_struct(held) -> Map.get(held, name)
      _other -> nil
    end
  end

  defp value({:index, tree, index}, data, opts) do
    case {value(tree, data, opts), value(index, data, opts)} do
      {items, at} when is_list(items) ->
        case whole(at) do
          nil -> nil
          at when at < 0 -> nil
          at -> Enum.at(items, at)
        end

      {%{} = held, name} when not is_struct(held) and is_binary(name) ->
        Map.get(held, name)

      _other ->
        nil
    end
  end

  defp value({:minus, tree}, data, opts),
    do: tree |> value(data, opts) |> number!() |> Decimal.negate()

  defp value({:not, tree}, data, opts), do: not true?(value(tree, data, opts))

  defp value({:op, :and, left, right}, data, opts),
    do: true?(value(left, data, opts)) and true?(value(right, data, opts))

  defp value({:op, :or, left, right}, data, opts),
    do: true?(value(left, data, opts)) or true?(value(right, data, opts))

  defp value({:op, :&, left, right}, data, opts) do
    zone = zone(opts)
    Types.text(value(left, data, opts), zone) <> Types.text(value(right, data, opts), zone)
  end

  defp value({:op, op, left, right}, data, opts) when op in [:+, :-, :*, :/] do
    a = number!(value(left, data, opts))
    b = number!(value(right, data, opts))

    result =
      case op do
        :+ ->
          Decimal.add(a, b)

        :- ->
          Decimal.sub(a, b)

        :* ->
          Decimal.mult(a, b)

        :/ ->
          if Decimal.equal?(b, 0), do: throw({:eval, :division_by_zero}), else: Decimal.div(a, b)
      end

    bounded!(result)
  end

  defp value({:op, :=, left, right}, data, opts),
    do: same?(value(left, data, opts), value(right, data, opts))

  defp value({:op, :!=, left, right}, data, opts),
    do: not same?(value(left, data, opts), value(right, data, opts))

  defp value({:op, op, left, right}, data, opts) do
    case {op, order(value(left, data, opts), value(right, data, opts))} do
      {_op, nil} -> false
      {:<, order} -> order == :lt
      {:>, order} -> order == :gt
      {:<=, order} -> order in [:lt, :eq]
      {:>=, order} -> order in [:gt, :eq]
    end
  end

  # Only the branch taken is worked out.
  defp value({:call, "if", [condition, then, otherwise]}, data, opts) do
    if true?(value(condition, data, opts)),
      do: value(then, data, opts),
      else: value(otherwise, data, opts)
  end

  defp value({:call, name, arguments}, data, opts),
    do: apply_function(name, Enum.map(arguments, &value(&1, data, opts)), opts)

  defp apply_function("empty", [value], _opts), do: empty?(value)

  defp apply_function("length", [items], _opts) when is_list(items),
    do: Decimal.new(length(items))

  defp apply_function("length", [nil], _opts), do: Decimal.new(0)

  defp apply_function("length", [value], opts),
    do: value |> Types.text(zone(opts)) |> String.length() |> Decimal.new()

  defp apply_function("contains", [items, wanted], _opts) when is_list(items),
    do: Enum.any?(items, &same?(&1, wanted))

  defp apply_function("contains", [value, wanted], opts) do
    zone = zone(opts)
    String.contains?(Types.text(value, zone), Types.text(wanted, zone))
  end

  defp apply_function("first", [items], _opts), do: items |> list!() |> List.first()
  defp apply_function("last", [items], _opts), do: items |> list!() |> List.last()

  defp apply_function("sum", [items], _opts) do
    items
    |> list!()
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, number!(&1)))
    |> bounded!()
  end

  defp apply_function("join", [items], opts), do: apply_function("join", [items, ", "], opts)

  defp apply_function("join", [items, separator], opts) do
    zone = zone(opts)
    items |> list!() |> Enum.map_join(Types.text(separator, zone), &Types.text(&1, zone))
  end

  defp apply_function("text", [value], opts), do: Types.text(value, zone(opts))
  defp apply_function("number", [value], _opts), do: number!(value)
  defp apply_function("round", [value], opts), do: apply_function("round", [value, 0], opts)

  defp apply_function("round", [value, places], _opts) do
    places = whole(places) || throw({:eval, :not_a_number})
    Decimal.round(number!(value), places |> max(0) |> min(@max_round), :half_up)
  end

  defp apply_function("today", [], opts) do
    case DateTime.shift_zone(now(opts), zone(opts)) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _unknown_zone} -> DateTime.to_date(now(opts))
    end
  end

  defp apply_function("now", [], opts), do: now(opts)

  defp apply_function("lower", [value], opts),
    do: value |> Types.text(zone(opts)) |> String.downcase()

  defp apply_function("upper", [value], opts),
    do: value |> Types.text(zone(opts)) |> String.upcase()

  defp apply_function("trim", [value], opts), do: value |> Types.text(zone(opts)) |> String.trim()

  defp apply_function("add_days", [nil, _days], _opts), do: nil

  defp apply_function("add_days", [value, days], _opts) do
    days = whole(days) || throw({:eval, :not_a_number})

    case value do
      %Date{} = date ->
        Date.add(date, days)

      %DateTime{} = at ->
        DateTime.add(at, days * 86_400, :second)

      # What Potok knows no type of may still hold a date.
      text when is_binary(text) ->
        case Types.cast(text, :date) do
          {:ok, %Date{} = date} -> Date.add(date, days)
          _not_a_date -> throw({:eval, :not_a_date})
        end

      _other ->
        throw({:eval, :not_a_date})
    end
  end

  defp apply_function(_name, _arguments, _opts), do: throw({:eval, :not_a_function})

  defp number!(value) do
    case Types.number(value) do
      {:ok, number} -> number
      :error -> throw({:eval, :not_a_number})
    end
  end

  defp list!(items) when is_list(items), do: items
  defp list!(nil), do: []
  defp list!(_other), do: throw({:eval, :not_a_list})

  # A number of more than 60 digits before or after the point is no use.
  defp bounded!(%Decimal{coef: coefficient, exp: exponent} = number)
       when is_integer(coefficient) do
    magnitude = exponent + length(Integer.digits(coefficient)) - 1

    if magnitude > @max_exponent or exponent < -@max_exponent,
      do: throw({:eval, :number_too_large}),
      else: number
  end

  defp bounded!(_not_a_number), do: throw({:eval, :number_too_large})

  # A whole number that fits a place in a list, or nil.
  defp whole(value) do
    with {:ok, number} <- Types.number(value),
         true <- Decimal.integer?(number),
         true <- Decimal.compare(Decimal.abs(number), 1_000_000) == :lt do
      Decimal.to_integer(number)
    else
      _not_whole -> nil
    end
  end

  defp true?(value), do: value in [true, "true"]

  defp empty?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty?(value), do: value in [nil, [], %{}]

  # Two values are the same as numbers when both are numbers, as days when
  # both are days, and as texts without the spaces around them otherwise.
  defp same?(a, b) do
    cond do
      empty?(a) or empty?(b) -> empty?(a) and empty?(b)
      is_boolean(a) or is_boolean(b) -> true?(a) == true?(b)
      is_list(a) or is_list(b) or plain_map?(a) or plain_map?(b) -> Types.dump(a) == Types.dump(b)
      true -> order(a, b) == :eq
    end
  end

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  defp order(%Date{} = a, %Date{} = b), do: Date.compare(a, b)
  defp order(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp order(a, b) do
    case {Types.number(a), Types.number(b)} do
      {{:ok, a}, {:ok, b}} ->
        Decimal.compare(a, b)

      _not_numbers ->
        if printable?(a) and printable?(b) do
          {a, b} =
            {a |> Types.dump() |> to_string() |> String.trim(),
             b |> Types.dump() |> to_string() |> String.trim()}

          cond do
            a < b -> :lt
            a > b -> :gt
            true -> :eq
          end
        end
    end
  end

  defp printable?(value),
    do:
      is_binary(value) or is_number(value) or is_struct(value, Decimal) or is_struct(value, Date) or
        is_struct(value, DateTime)
end
