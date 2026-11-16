defmodule PotokIde.Processes.GroupEntities do
  @moduledoc """
  The entities the editors of a group define for the processes drawn in it
  (`GroupEntity`): what the data a process works with looks like, as a name
  and attributes with their types (`PotokIde.Processes.Types`).

  - At most 50 in a group, each name once in any letter case.
  - An attribute may hold another entity of the group, never in a circle.
  - Only the app's editors write them, on the group's Processes tab. A write
    takes the group's lock, so two never make a circle or pass the limit
    together, and a change made from an older copy is refused.
  - One that another entity holds, or a drawn process of the group keeps a
    variable of, cannot be deleted.

  The group's pages hear of a change (`{:app_value, group_id, :entity, _}`).
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.GroupEntity
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, AppData, AppProcess, Group, ValueRules}

  @max_entities 50

  @doc "The group's entities by name."
  def list(%Group{id: group_id}) do
    from(e in GroupEntity,
      where: e.group_id == ^group_id,
      order_by: [asc: fragment("lower(?)", e.name), asc: e.id]
    )
    |> Repo.all()
  end

  @doc "The entity `id` of the group, or nil."
  def get(%Group{id: group_id}, id) when is_integer(id),
    do: Repo.get_by(GroupEntity, id: id, group_id: group_id)

  def get(_group, _id), do: nil

  @doc """
  A changeset of the entity for a form, among `entities`, the group's own
  (`list/1`): its attributes may hold any of them but itself.
  """
  def change(%GroupEntity{} = entity, attrs, entities) when is_list(entities),
    do: GroupEntity.changeset(entity, attrs, others(entities, entity))

  @doc """
  Defines a new entity of the group. Returns `{:ok, entity}`, `{:error,
  changeset}`, or `{:error, :not_permitted | :too_many}`.
  """
  def create(%Group{} = group, %Access{} = access, attrs) when is_map(attrs) do
    writing(group, access, fn entities ->
      if length(entities) >= @max_entities, do: Repo.rollback(:too_many)

      %GroupEntity{group_id: group.id}
      |> GroupEntity.changeset(attrs, entities)
      |> Repo.insert()
    end)
  end

  @doc """
  Changes the entity as its editor saw it: a change made from a copy someone
  has changed since comes back as an error on `:lock_version`.
  """
  def update(%Group{} = group, %Access{} = access, %GroupEntity{} = entity, attrs)
      when is_map(attrs) do
    writing(group, access, fn entities ->
      if entity.group_id != group.id, do: Repo.rollback(:not_found)

      entity
      |> GroupEntity.changeset(attrs, others(entities, entity))
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.update(stale_error_field: :lock_version)
    end)
  end

  @doc """
  Deletes an entity of the group, unless something holds it: `{:error,
  {:in_use, names}}` then.
  """
  def delete(%Group{} = group, %Access{} = access, id) when is_integer(id) do
    writing(group, access, fn entities ->
      entity = Enum.find(entities, &(&1.id == id)) || Repo.rollback(:not_found)

      case in_use(entity, entities) ++ drawn_with(group, entity) do
        [] -> Repo.delete(entity)
        names -> Repo.rollback({:in_use, names})
      end
    end)
  end

  def delete(_group, _access, _id), do: {:error, :not_found}

  @doc """
  The group's entities as a graph keeps them (`Processes.Check`), by id as
  a text: `%{"12" => %{"name" => _, "attributes" => [_]}}`.
  """
  def definitions(%Group{} = group), do: definitions(list(group))

  def definitions(entities) when is_list(entities),
    do: Map.new(entities, &{to_string(&1.id), definition(&1)})

  @doc "One entity as a graph keeps it: its name and its attributes with their types."
  def definition(%GroupEntity{name: name, attributes: attributes}) do
    %{
      "name" => name,
      "attributes" =>
        Enum.map(attributes, fn attribute ->
          base = %{
            "name" => attribute.name,
            "type" => attribute.type,
            "list" => attribute.list,
            "required" => attribute.required
          }

          case attribute.type do
            "choice" -> Map.put(base, "options", attribute.options)
            "entity" -> Map.put(base, "entity", attribute.entity_id)
            _plain -> base
          end
        end)
    }
  end

  @doc "The names of what holds the entity, among the group's `entities`."
  def in_use(%GroupEntity{id: id}, entities) do
    for other <- entities, other.id != id, id in GroupEntity.held(other), do: other.name
  end

  # The names of the group's drawn processes that were saved with the entity
  # among those their variables hold (`Processes.Check`).
  defp drawn_with(%Group{id: group_id}, %GroupEntity{id: id}) do
    from(p in AppProcess,
      where:
        p.group_id == ^group_id and p.drawn and
          fragment("jsonb_exists(? -> 'types', ?)", p.graph, ^to_string(id)),
      order_by: [asc: p.name],
      select: p.name
    )
    |> Repo.all()
  end

  defp others(entities, %GroupEntity{id: id}), do: Enum.reject(entities, &(&1.id == id))

  # Runs `fun` on the group's entities, for an editor, under the group's lock.
  defp writing(%Group{} = group, %Access{} = access, fun) do
    if ValueRules.manage?(access) do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          7_104,
          :erlang.phash2(group.id, 2_147_483_647)
        ])

        case fun.(list(group)) do
          {:ok, entity} -> entity
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> announced(group)
    else
      {:error, :not_permitted}
    end
  end

  # The pages of the group hear of it; apps' frames do not (`AppValues`).
  defp announced({:ok, %GroupEntity{} = entity}, group) do
    AppData.broadcast(group, :entity, %{alt_id: nil, id: entity.id})
    {:ok, entity}
  end

  defp announced({:error, reason}, _group), do: {:error, reason}
end
