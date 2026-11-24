defmodule PotokIde.Processes.GroupFields do
  @moduledoc """
  The fields the processes drawn in a group keep for each other
  (`GroupField`). A step sets one, or adds a number to it
  (`Processes.Engine`), and every drawn process of the group reads them as
  `group.name` in its expressions and `{{group.name}}` in its texts.

  Each field has a type: a text, a number, a yes or no, a date, a date and
  time, or one of its choices (`types/0`). It keeps its value as a text of
  that type, so a graph of the first language reads it as it always did; a
  graph of today reads it as its type, as the graph was saved with it
  (`Check` keeps the fields it uses as `fields`), and a name the group does
  not declare is an unknown name there.

  - The app's editors declare a field on the group's Processes tab. A field
    a step sets that the group does not declare yet is declared when the
    drawing is saved: a number for one it adds to, a text otherwise
    (`declare_missing/2`), so a field still comes with its first step.
  - At most 50 in a group, each named with up to 40 letters, digits, `-`
    or `_` (a declared one as a plain word, which reads as `group.name`),
    and up to 1,000 characters long. A choice has up to 30 options.
  - A write takes the row's lock, and a new name the group's, so two steps
    never lose each other's addition or go past the limit together. A value
    that does not fit the field's type is refused (`:invalid_field`), and
    adding goes only to a number.
  - Only the app's editors change a field's type (while its value fits),
    empty it or delete it, and one a drawn process sets or reads is not
    deleted.
  """

  import Ecto.Query, warn: false

  alias PotokIde.History
  alias PotokIde.Processes.{GroupField, Types}
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, AppProcess, Group, Profile, ValueRules}

  @max_fields 50
  @max_value 1_000
  @max_options 30
  @name_format ~r/^[\p{L}\p{Nd}_-]{1,40}$/u
  @types ~w(text number boolean date datetime choice)

  @doc "The types a field may have."
  def types, do: @types

  @doc "Whether `name` may name a field of the group."
  def name?(name) when is_binary(name), do: Regex.match?(@name_format, name)
  def name?(_name), do: false

  @doc "The group's fields by name, with the process that wrote each last."
  def list(%Group{id: group_id}) do
    from(f in GroupField,
      where: f.group_id == ^group_id,
      order_by: [asc: f.name],
      preload: [:app_process]
    )
    |> Repo.all()
  end

  @doc "The names of the group's fields."
  def names(%Group{id: group_id}) do
    from(f in GroupField, where: f.group_id == ^group_id, order_by: f.name, select: f.name)
    |> Repo.all()
  end

  @doc """
  The group's fields as a graph keeps them (`Check`): `%{name => %{"type" =>
  type}}`, a choice with its `"options"`.
  """
  def definitions(%Group{id: group_id}) do
    from(f in GroupField,
      where: f.group_id == ^group_id,
      select: {f.name, f.type, f.options}
    )
    |> Repo.all()
    |> Map.new(fn {name, type, options} -> {name, definition(type, options)} end)
  end

  defp definition("choice", options), do: %{"type" => "choice", "options" => options}
  defp definition(type, _options), do: %{"type" => type}

  @doc """
  The fields a run of the process `app_process_id` reads, as `%{name =>
  value}`: those of its group when it is drawn in Potok, none otherwise.
  """
  def for_process(app_process_id) do
    from(f in GroupField,
      join: p in AppProcess,
      on: p.group_id == f.group_id,
      where: p.id == ^app_process_id and p.drawn,
      select: {f.name, f.value}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  A value written for a field, as the text the field keeps: `{:ok, text}`, or
  `:error` when it is not of the field's type. Empty always fits.
  """
  def typed_text(definition, text) when is_map(definition) and is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:ok, ""}
      true -> kept(definition["type"], definition["options"] || [], trimmed, text)
    end
  end

  def typed_text(_definition, _text), do: :error

  defp kept("number", _options, trimmed, _text) do
    case number(trimmed) do
      {:ok, n} -> {:ok, number_text(n)}
      {:error, _} -> :error
    end
  end

  defp kept("boolean", _options, trimmed, _text) do
    case String.downcase(trimmed) do
      yes when yes in ["true", "da", "yes"] -> {:ok, "true"}
      no when no in ["false", "ne", "no"] -> {:ok, "false"}
      _other -> :error
    end
  end

  defp kept("date", _options, trimmed, _text) do
    case Types.cast(trimmed, :date) do
      {:ok, %Date{} = date} -> {:ok, Date.to_iso8601(date)}
      _not_a_date -> :error
    end
  end

  defp kept("datetime", _options, trimmed, _text) do
    case Types.cast(trimmed, :datetime) do
      {:ok, %DateTime{} = at} -> {:ok, DateTime.to_iso8601(at)}
      _not_a_time -> :error
    end
  end

  defp kept("choice", options, trimmed, _text),
    do: if(trimmed in options, do: {:ok, trimmed}, else: :error)

  defp kept(_text_type, _options, _trimmed, text), do: {:ok, String.slice(text, 0, @max_value)}

  @doc """
  Declares a field of the group, empty, for the app's editors (`editor` is who
  signs it, as in the functions below, `PotokIde.History`): `name` (a
  plain word), `type` and, for a choice, its `options`. `{:ok, field}` or
  `{:error, reason}`: `:not_permitted`, `:invalid_name`, `:taken`,
  `:invalid_type`, `:invalid_options` or `:too_many_fields`.
  """
  def declare(%Group{} = group, %Access{} = access, attrs, editor \\ nil) when is_map(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()

    with true <- ValueRules.manage?(access) || {:error, :not_permitted},
         true <- (name?(name) and Types.name?(name)) || {:error, :invalid_name},
         {:ok, type, options} <- typed(attrs) do
      History.transaction(signature(editor), fn ->
        lock_group(group.id)

        cond do
          Repo.exists?(from(f in GroupField, where: f.group_id == ^group.id and f.name == ^name)) ->
            Repo.rollback(:taken)

          count(group.id) >= @max_fields ->
            Repo.rollback(:too_many_fields)

          true ->
            Repo.insert!(%GroupField{
              group_id: group.id,
              name: name,
              type: type,
              options: options,
              value: ""
            })
        end
      end)
    end
  end

  @doc """
  Changes the type of a field, for the app's editors, while what it holds
  fits the new one: `{:error, :value_does_not_fit}` otherwise. The drawings
  that use it are saved with the old type until saved again.
  """
  def retype(%Group{} = group, %Access{} = access, id, attrs, editor \\ nil)
      when is_integer(id) do
    with true <- ValueRules.manage?(access) || {:error, :not_permitted},
         %GroupField{} = field <-
           Repo.get_by(GroupField, id: id, group_id: group.id) || {:error, :not_found},
         {:ok, type, options} <- typed(attrs),
         {:ok, value} <- fitting(definition(type, options), field.value) do
      field
      |> Ecto.Changeset.change(type: type, options: options, value: value)
      |> History.update(signature(editor))
    end
  end

  defp fitting(definition, value) do
    case typed_text(definition, value) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :value_does_not_fit}
    end
  end

  @doc """
  Gives a field the `value`, `type` and `options` it had (`PotokIde.History`),
  those of them that `attrs` name, while the value fits the type.
  """
  def put_back(%Group{} = group, %Access{} = access, id, attrs, editor) when is_map(attrs) do
    with true <- ValueRules.manage?(access) || {:error, :not_permitted},
         %GroupField{} = field <-
           Repo.get_by(GroupField, id: id, group_id: group.id) || {:error, :not_found},
         {:ok, type, options} <-
           typed(%{
             "type" => attrs["type"] || field.type,
             "options" => attrs["options"] || field.options
           }),
         {:ok, value} <- fitting(definition(type, options), attrs["value"] || field.value) do
      field
      |> Ecto.Changeset.change(type: type, options: options, value: value)
      |> History.update(signature(editor))
    end
  end

  @doc "Empties a field, for the app's editors."
  def clear(%Group{} = group, %Access{} = access, id, editor \\ nil) when is_integer(id) do
    with true <- ValueRules.manage?(access) || {:error, :not_permitted},
         %GroupField{} = field <-
           Repo.get_by(GroupField, id: id, group_id: group.id) || {:error, :not_found} do
      field |> Ecto.Changeset.change(value: "") |> History.update(signature(editor))
    end
  end

  @doc """
  Deletes a field of the group, for the app's editors, unless a drawn
  process of the group sets or reads it: `{:error, {:in_use, names}}` names
  those processes.
  """
  def delete(group, access, id, editor \\ nil)

  def delete(%Group{} = group, %Access{} = access, id, editor) when is_integer(id) do
    with true <- ValueRules.manage?(access) || {:error, :not_permitted},
         %GroupField{} = field <-
           Repo.get_by(GroupField, id: id, group_id: group.id) || {:error, :not_found} do
      case users(group, field.name) do
        [] -> History.delete(field, signature(editor))
        names -> {:error, {:in_use, names}}
      end
    end
  end

  def delete(_group, _access, _id, _editor), do: {:error, :not_found}

  defp signature(%Profile{} = editor), do: [actor: editor]
  defp signature(nil), do: []

  # The names of the drawn processes of the group that set or read the field.
  defp users(%Group{id: group_id}, name) do
    from(p in AppProcess, where: p.group_id == ^group_id and p.drawn, select: {p.name, p.graph})
    |> Repo.all()
    |> Enum.filter(fn {_name, graph} ->
      is_map(graph) and
        name in PotokIde.Processes.Check.used_fields(
          %{"nodes" => [], "flows" => []}
          |> Map.merge(graph)
        )
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Declares the fields a graph sets that the group does not declare yet: a
  number for one it adds to, a text otherwise, while there is room. Called
  as a drawing of today's language is saved, so a field still comes with
  its first step; a graph of the first language makes it on its first write.
  """
  def declare_missing(%Group{id: group_id}, %{"v" => 2, "nodes" => nodes}, %Profile{} = editor)
      when is_list(nodes) do
    wanted =
      for %{"action" => "set", "field" => field} = node <- nodes,
          is_binary(field) and name?(field),
          reduce: %{} do
        acc -> Map.update(acc, field, kind(node), &if(&1 == "number", do: &1, else: kind(node)))
      end

    if wanted != %{} do
      History.transaction([actor: editor], fn ->
        lock_group(group_id)

        known =
          from(f in GroupField, where: f.group_id == ^group_id, select: f.name)
          |> Repo.all()
          |> MapSet.new()

        room = @max_fields - MapSet.size(known)

        wanted
        |> Enum.reject(fn {name, _type} -> MapSet.member?(known, name) end)
        |> Enum.take(max(room, 0))
        |> Enum.each(fn {name, type} ->
          Repo.insert!(%GroupField{group_id: group_id, name: name, type: type, value: ""})
        end)
      end)
    end

    :ok
  end

  def declare_missing(_group, _graph, _editor), do: :ok

  defp kind(%{"op" => "add"}), do: "number"
  defp kind(_set), do: "text"

  defp typed(attrs) do
    type = to_string(attrs["type"] || "text")

    options =
      case attrs["options"] do
        list when is_list(list) -> list
        text when is_binary(text) -> String.split(text, ",")
        _none -> []
      end
      |> Enum.map(&(&1 |> to_string() |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      type not in @types ->
        {:error, :invalid_type}

      type == "choice" and (options == [] or length(options) > @max_options) ->
        {:error, :invalid_options}

      type == "choice" ->
        {:ok, type, options}

      true ->
        {:ok, type, []}
    end
  end

  @doc """
  Sets the field `name` of the group to `value`, as `process` writes it, in
  the caller's transaction: a value of the field's type, kept as its text.
  A field the group does not declare yet comes as a text. Returns `{:ok,
  field}` or `{:error, :invalid_field | :too_many_fields}`.
  """
  def put(%AppProcess{} = process, name, value) when is_binary(value) do
    write(process, name, "text", fn field ->
      case typed_text(definition(field.type, field.options), value) do
        {:ok, text} -> {:ok, text}
        :error -> {:error, :invalid_field}
      end
    end)
  end

  @doc """
  Adds the number `amount` to the field `name`, 0 when it is empty or not
  there yet, which then comes as a number. Whole numbers stay whole. Returns
  `{:ok, field}` or `{:error, reason}`, `:not_a_number` among them when the
  field holds no number or `amount` is none.
  """
  def add(%AppProcess{} = process, name, amount) when is_binary(amount) do
    write(process, name, "number", fn field ->
      with true <- field.type == "number" || {:error, :not_a_number},
           {:ok, a} <- number(if(field.value in [nil, ""], do: "0", else: field.value)),
           {:ok, b} <- number(amount) do
        {:ok, number_text(a + b)}
      end
    end)
  end

  defp write(%AppProcess{id: process_id, group_id: group_id}, name, new_type, fun) do
    if name?(name) do
      case locked(group_id, name) do
        %GroupField{} = field ->
          with {:ok, value} <- fun.(field) do
            field
            |> Ecto.Changeset.change(value: value, app_process_id: process_id)
            |> Repo.update()
          end

        nil ->
          lock_group(group_id)

          # Another step may have made it while this one waited.
          case locked(group_id, name) do
            %GroupField{} ->
              write(%AppProcess{id: process_id, group_id: group_id}, name, new_type, fun)

            nil ->
              create(group_id, process_id, name, new_type, fun)
          end
      end
    else
      {:error, :invalid_field}
    end
  end

  defp create(group_id, process_id, name, type, fun) do
    with true <- count(group_id) < @max_fields || {:error, :too_many_fields},
         {:ok, value} <- fun.(%GroupField{type: type, options: [], value: ""}) do
      Repo.insert(%GroupField{
        group_id: group_id,
        name: name,
        type: type,
        value: value,
        app_process_id: process_id
      })
    end
  end

  defp count(group_id),
    do: from(f in GroupField, where: f.group_id == ^group_id) |> Repo.aggregate(:count)

  defp lock_group(group_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      7_103,
      :erlang.phash2(group_id, 2_147_483_647)
    ])
  end

  defp locked(group_id, name) do
    from(f in GroupField,
      where: f.group_id == ^group_id and f.name == ^name,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp number(text) do
    text = text |> String.trim() |> String.replace(",", ".")

    case Integer.parse(text) do
      {n, ""} ->
        {:ok, n}

      _not_whole ->
        case Float.parse(text) do
          {n, ""} -> {:ok, n}
          _not_a_number -> {:error, :not_a_number}
        end
    end
  end

  defp number_text(n) when is_integer(n), do: Integer.to_string(n)

  defp number_text(n) when is_float(n) do
    if n == Float.round(n), do: n |> trunc() |> Integer.to_string(), else: Float.to_string(n)
  end
end
