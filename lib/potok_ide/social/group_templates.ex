defmodule PotokIde.Social.GroupTemplates do
  @moduledoc """
  Templates of a group's own (`GroupTemplate`): made by whoever may edit the
  group, they serve that group and every group below it, as a manifest does.
  An organization writes them once at its top group, and every feed and group
  under it picks them for a description.

  Every change broadcasts `{:group_templates_updated, group_id}` on the group's
  topic.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupTemplate, Profile}

  @max_per_group 30

  def max_per_group, do: @max_per_group

  @doc """
  The templates `group` may use, nearest first: its own, then those of each
  group above it. Each is `%{template, group_id, owner, own?}`, `owner` being
  the owning group's name when `viewer` sees it (nil otherwise).
  """
  def catalog(%Group{} = group, viewer) do
    path = Social.list_group_path(group)
    depth = path |> Enum.reverse() |> Enum.with_index() |> Map.new(fn {g, i} -> {g.id, i} end)
    ids = Map.keys(depth)

    seen =
      group
      |> Social.list_visible_group_path_for_profile(viewer)
      |> MapSet.new(& &1.id)

    names = Map.new(path, &{&1.id, &1.name})

    from(t in GroupTemplate, where: t.group_id in ^ids)
    |> Repo.all()
    |> Enum.sort_by(&{Map.fetch!(depth, &1.group_id), &1.position, &1.id})
    |> Enum.map(fn template ->
      %{
        template: template,
        group_id: template.group_id,
        owner: if(MapSet.member?(seen, template.group_id), do: names[template.group_id]),
        own?: template.group_id == group.id
      }
    end)
  end

  @doc "The template `id` if `group` may use it (its own or from a group above), else nil."
  def get_for(%Group{} = group, id) when is_integer(id) do
    ids = group |> Social.list_group_path() |> Enum.map(& &1.id)
    Repo.one(from(t in GroupTemplate, where: t.id == ^id and t.group_id in ^ids))
  end

  def get_for(_group, _id), do: nil

  @doc "The group's own templates, in their order."
  def list_own(%Group{id: group_id}) do
    from(t in GroupTemplate,
      where: t.group_id == ^group_id,
      order_by: [asc: t.position, asc: t.id]
    )
    |> Repo.all()
  end

  def change(%GroupTemplate{} = template, attrs \\ %{}),
    do: GroupTemplate.changeset(template, attrs)

  @doc "Adds a template after the group's others."
  def create(%Profile{} = editor, %Group{} = group, attrs) do
    with :ok <- may_edit(editor, group) do
      Repo.transaction(fn ->
        lock(group)

        {count, position} =
          Repo.one(
            from(t in GroupTemplate,
              where: t.group_id == ^group.id,
              select: {count(), max(t.position)}
            )
          )

        if count >= @max_per_group, do: Repo.rollback(:too_many_templates)

        %GroupTemplate{group_id: group.id, creator_id: editor.id, position: (position || -1) + 1}
        |> GroupTemplate.changeset(attrs)
        |> Repo.insert()
        |> ok_or_rollback()
      end)
      |> announce(group)
    end
  end

  @doc "Saves a new version of one of the group's templates."
  def update(%Profile{} = editor, %Group{} = group, %GroupTemplate{} = template, attrs) do
    with :ok <- may_edit(editor, group),
         :ok <- own(group, template) do
      template
      |> GroupTemplate.changeset(attrs)
      |> Ecto.Changeset.put_change(:rev, template.rev + 1)
      |> Repo.update()
      |> announce(group)
    end
  end

  @doc "Deletes a template; descriptions made with it keep their HTML."
  def delete(%Profile{} = editor, %Group{} = group, %GroupTemplate{} = template) do
    with :ok <- may_edit(editor, group),
         :ok <- own(group, template) do
      template |> Repo.delete(allow_stale: true) |> announce(group)
    end
  end

  @doc "Swaps a template with its neighbour in `direction`."
  def move(%Profile{} = editor, %Group{} = group, %GroupTemplate{} = template, direction)
      when direction in [:up, :down] do
    with :ok <- may_edit(editor, group),
         :ok <- own(group, template) do
      Repo.transaction(fn ->
        lock(group)
        rows = list_own(group)
        index = Enum.find_index(rows, &(&1.id == template.id)) || 0
        neighbour = if direction == :up, do: index - 1, else: index + 1

        if neighbour >= 0 and neighbour < length(rows) do
          rows
          |> List.replace_at(index, Enum.at(rows, neighbour))
          |> List.replace_at(neighbour, Enum.at(rows, index))
          |> Enum.with_index()
          |> Enum.each(fn {row, position} ->
            if row.position != position,
              do:
                Repo.update_all(from(t in GroupTemplate, where: t.id == ^row.id),
                  set: [position: position]
                )
          end)
        end

        :moved
      end)
      |> announce(group)
    end
  end

  defp may_edit(editor, group) do
    if not group.is_direct and is_nil(group.parent_value_id) and
         Access.can?(editor, group, :edit_group),
       do: :ok,
       else: {:error, :not_permitted}
  end

  defp own(%Group{id: group_id}, %GroupTemplate{group_id: group_id}), do: :ok
  defp own(_group, _template), do: {:error, :not_found}

  defp lock(%Group{id: id}),
    do: Repo.one!(from(g in Group, where: g.id == ^id, lock: "FOR UPDATE", select: g.id))

  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp announce({:ok, _value} = result, %Group{id: group_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      "groups:#{group_id}",
      {:group_templates_updated, group_id}
    )

    result
  end

  defp announce(error, _group), do: error
end
