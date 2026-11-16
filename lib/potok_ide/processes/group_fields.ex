defmodule PotokIde.Processes.GroupFields do
  @moduledoc """
  The fields the processes drawn in a group keep for each other
  (`GroupField`). A step sets one, or adds a number to it
  (`Processes.Engine`), and every drawn process of the group reads them as
  `{{group.name}}` in its texts and conditions. They are texts: adding takes
  a whole number or a decimal one, and a field not there yet counts as 0.

  - At most 50 in a group, each named with up to 40 letters, digits, `-`
    or `_`, and up to 1,000 characters long.
  - A write takes the row's lock, and a new name the group's, so two steps
    never lose each other's addition or go past the limit together.
  - Only the app's editors delete one, on the group's Processes tab.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.GroupField
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, AppProcess, Group, ValueRules}

  @max_fields 50
  @max_value 1_000
  @name_format ~r/^[\p{L}\p{Nd}_-]{1,40}$/u

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
  Sets the field `name` of the group to `value`, cut to #{@max_value}
  characters, as `process` writes it, in the caller's transaction. Returns
  `{:ok, field}` or `{:error, :invalid_field | :too_many_fields}`.
  """
  def put(%AppProcess{} = process, name, value) when is_binary(value) do
    write(process, name, fn _old -> {:ok, String.slice(value, 0, @max_value)} end)
  end

  @doc """
  Adds the number `amount` to the field `name`, 0 when it is not there yet.
  Whole numbers stay whole. Returns `{:ok, field}` or `{:error, reason}`,
  `:not_a_number` among them when either is no number.
  """
  def add(%AppProcess{} = process, name, amount) when is_binary(amount) do
    write(process, name, fn old ->
      with {:ok, a} <- number(old || "0"),
           {:ok, b} <- number(amount) do
        {:ok, number_text(a + b)}
      end
    end)
  end

  @doc "Deletes a field of the group, for the app's editors."
  def delete(%Group{} = group, %Access{} = access, id) when is_integer(id) do
    if ValueRules.manage?(access) do
      case Repo.get_by(GroupField, id: id, group_id: group.id) do
        nil -> {:error, :not_found}
        field -> Repo.delete(field)
      end
    else
      {:error, :not_permitted}
    end
  end

  def delete(_group, _access, _id), do: {:error, :not_found}

  defp write(%AppProcess{id: process_id, group_id: group_id}, name, fun) do
    if name?(name) do
      case locked(group_id, name) do
        %GroupField{} = field ->
          with {:ok, value} <- fun.(field.value) do
            field
            |> Ecto.Changeset.change(value: value, app_process_id: process_id)
            |> Repo.update()
          end

        nil ->
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            7_103,
            :erlang.phash2(group_id, 2_147_483_647)
          ])

          # Another step may have made it while this one waited.
          case locked(group_id, name) do
            %GroupField{} -> write(%AppProcess{id: process_id, group_id: group_id}, name, fun)
            nil -> create(group_id, process_id, name, fun)
          end
      end
    else
      {:error, :invalid_field}
    end
  end

  defp create(group_id, process_id, name, fun) do
    count = from(f in GroupField, where: f.group_id == ^group_id) |> Repo.aggregate(:count)

    with true <- count < @max_fields || {:error, :too_many_fields},
         {:ok, value} <- fun.(nil) do
      Repo.insert(%GroupField{
        group_id: group_id,
        name: name,
        value: value,
        app_process_id: process_id
      })
    end
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
