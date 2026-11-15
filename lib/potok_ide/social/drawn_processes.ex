defmodule PotokIde.Social.DrawnProcesses do
  @moduledoc """
  Processes an editor draws in Potok, on a collection of one of the group's
  apps (`AppProcess` with `drawn`). They run like the app's own process: an
  instance for every new value of the collection (`Processes.Engine`), each
  with a copy of the graph, signed by a profile of their own.

  The app neither sees nor overwrites them: the app's config, which an app
  replaces whole on every save, never holds their graphs, and its process
  calls and events reach only its own process. Their tasks are finished on
  the group's page instead.

  - Only the app's editors (`ValueRules.manage?/1`) draw, change, switch on
    and off and delete. Every change takes the app's lock, as a save of its
    config does, and checks the revision the editor started from.
  - Only a graph an instance can finish is kept (`Graph.normalize/1`), with
    roles the group has.
  - A new drawing is off. Switching it on brings its profile into the app's
    group; switching it off cancels its instances that run or wait and takes
    the profile out, as removing an app's rule does (`AppProcesses.stop/2`).
  - A change applies to the instances that start after it.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.Graph
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    AppProcesses,
    Group,
    GroupAltDescription,
    Profile,
    Value,
    ValueRules
  }

  @max_per_app 10
  @max_name 60
  @max_coordinate 50_000
  @max_collections 50

  @doc "At most how many processes may be drawn on one app."
  def max_per_app, do: @max_per_app

  @doc """
  The group's apps a process can be drawn on, as `%{alt_id, alt, name}`: the
  default description when it is an app (`alt` nil), then the other
  descriptions that are.
  """
  def apps(%Group{} = group) do
    default = if group.uses_api, do: [%{alt_id: nil, alt: nil, name: group.description_name}]

    alts =
      from(d in GroupAltDescription,
        where: d.group_id == ^group.id and d.uses_api,
        order_by: [asc: d.position, asc: d.id],
        select: struct(d, [:id, :group_id, :name, :uses_api, :position])
      )
      |> Repo.all()
      |> Enum.map(&%{alt_id: &1.id, alt: &1, name: &1.name})

    List.wrap(default) ++ alts
  end

  @doc """
  The collections of an app a process can be drawn on: those its rules name
  and those that already hold values, without the ones Potok keeps for it.
  """
  def collections(%Group{} = group, alt_id) do
    ruled = group |> AppData.get_config(alt_id) |> AppData.rules() |> Map.keys()

    held =
      from(v in Value,
        where: v.group_id == ^group.id and v.is_data and not is_nil(v.collection),
        distinct: true,
        select: v.collection,
        limit: @max_collections
      )
      |> of_alt(alt_id)
      |> Repo.all()

    (ruled ++ held)
    |> Enum.uniq()
    |> Enum.filter(&ValueRules.app_collection?/1)
    |> Enum.sort()
  end

  defp of_alt(query, nil), do: where(query, [v], is_nil(v.alt_description_id))
  defp of_alt(query, alt_id), do: where(query, [v], v.alt_description_id == ^alt_id)

  @doc "The processes drawn in the group, switched on or not, by name."
  def list(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn,
      order_by: [asc: p.name, asc: p.id],
      preload: [:profile, :owner_profile]
    )
    |> Repo.all()
  end

  @doc "A process drawn in the group, or nil."
  def get(%Group{id: group_id}, id) when is_integer(id) do
    from(p in AppProcess,
      where: p.id == ^id and p.group_id == ^group_id and p.drawn,
      preload: [:profile, :owner_profile]
    )
    |> Repo.one()
  end

  def get(_group, _id), do: nil

  @doc """
  Draws a new process, switched off, on `attrs["collection"]` of the app
  `attrs["alt_id"]` (an integer, nil for the default description), with its `name`,
  `graph` and `layout`. Returns `{:ok, process}` or `{:error, reason}`:
  `:not_permitted`, `:not_an_app`, `:unknown_collection`, `:too_many`,
  `:invalid_name` or `{:invalid_graph, path, reason}`.
  """
  def create(%Profile{} = editor, %Group{} = group, attrs) when is_map(attrs) do
    alt_id = attrs["alt_id"]
    collection = attrs["collection"]

    with {:ok, name} <- name(attrs["name"]),
         {:ok, graph} <- graph(attrs["graph"]),
         true <- Enum.any?(apps(group), &(&1.alt_id == alt_id)) || {:error, :not_an_app},
         true <- collection in collections(group, alt_id) || {:error, :unknown_collection} do
      layout = layout(attrs["layout"], graph)

      Repo.transaction(fn ->
        AppData.lock_app(group, alt_id)
        access = editor_access!(editor, group)
        known_roles!(graph, access)

        if count(group, alt_id) >= @max_per_app, do: Repo.rollback(:too_many)

        profile = AppProcesses.create_process_profile!()

        %AppProcess{
          profile_id: profile.id,
          group_id: group.id,
          alt_description_id: alt_id,
          collection: collection,
          name: name,
          owner_profile_id: editor.id,
          active: false,
          drawn: true,
          graph: graph,
          layout: layout
        }
        |> Repo.insert!()
      end)
      |> announced(group)
    end
  end

  @doc """
  Changes the `name`, `graph` and `layout` of a drawn process, from the
  `revision` the editor started from; another editor's change in between
  gives `{:error, {:conflict, current}}`. Instances under way keep the graph
  they started with. The owner stays while they edit the app.
  """
  def update(%Profile{} = editor, %Group{} = group, id, attrs, revision) when is_map(attrs) do
    with {:ok, name} <- name(attrs["name"]),
         {:ok, graph} <- graph(attrs["graph"]) do
      layout = layout(attrs["layout"], graph)

      changing(editor, group, id, fn row, access ->
        if row.lock_version != revision, do: Repo.rollback({:conflict, row})
        known_roles!(graph, access)

        row
        |> Ecto.Changeset.change(
          name: name,
          graph: graph,
          layout: layout,
          owner_profile_id: owner(row, editor, group)
        )
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update!()
      end)
    end
  end

  @doc """
  Switches a drawn process on: its profile joins the app's group, and the
  editor owns it. Its next new value starts an instance.
  """
  def activate(%Profile{} = editor, %Group{} = group, id) do
    changing(editor, group, id, fn row, access ->
      known_roles!(row.graph, access)

      row =
        row
        |> Ecto.Changeset.change(active: true, owner_profile_id: editor.id)
        |> Repo.update!()

      AppProcesses.join(group, row.profile_id)
      row
    end)
  end

  @doc """
  Switches a drawn process off: its instances that run or wait are cancelled,
  and its profile leaves the app's group, with its roles.
  """
  def deactivate(%Profile{} = editor, %Group{} = group, id) do
    changing(editor, group, id, fn row, _access ->
      if row.active, do: AppProcesses.stop(group, row)
      %{row | active: false}
    end)
  end

  @doc """
  Deletes a drawn process with its instances. What it wrote stays, signed by
  its profile, which goes once nothing it wrote is left (`AppProcesses.sweep/0`).
  """
  def delete(%Profile{} = editor, %Group{} = group, id) do
    changing(editor, group, id, fn row, _access ->
      if row.active, do: AppProcesses.stop(group, row)
      Repo.delete!(row)
    end)
  end

  # Runs `fun` on the locked row, for an editor of its app, under the app's lock.
  defp changing(editor, group, id, fun) do
    case get(group, id) do
      nil ->
        {:error, :not_found}

      %AppProcess{alt_description_id: alt_id} ->
        Repo.transaction(fn ->
          AppData.lock_app(group, alt_id)
          access = editor_access!(editor, group)
          row = locked(group, id) || Repo.rollback(:not_found)
          fun.(row, access)
        end)
        |> announced(group)
    end
  end

  defp locked(%Group{id: group_id}, id) do
    from(p in AppProcess,
      where: p.id == ^id and p.group_id == ^group_id and p.drawn,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp editor_access!(editor, group) do
    access = Access.for_profile(editor, Repo.get!(Group, group.id))
    if ValueRules.manage?(access), do: access, else: Repo.rollback(:not_permitted)
  end

  defp known_roles!(graph, %Access{manifest: manifest}) do
    case Graph.unknown_role(graph, AppData.role_keys(manifest)) do
      nil -> :ok
      {path, reason} -> Repo.rollback({:invalid_graph, path, reason})
    end
  end

  defp owner(%AppProcess{owner_profile_id: owner_id}, editor, group) do
    if owner_id != editor.id and not AppProcesses.edits_app?(owner_id, group),
      do: editor.id,
      else: owner_id
  end

  defp count(%Group{id: group_id}, alt_id) do
    query = from(p in AppProcess, where: p.group_id == ^group_id and p.drawn)

    case alt_id do
      nil -> where(query, [p], is_nil(p.alt_description_id))
      alt_id -> where(query, [p], p.alt_description_id == ^alt_id)
    end
    |> Repo.aggregate(:count)
  end

  # The pages of the group hear of it; apps' frames do not (`AppValues`).
  defp announced({:ok, %AppProcess{} = row}, group) do
    AppData.broadcast(group, :drawn_process, %{
      alt_id: row.alt_description_id,
      id: row.id,
      revision: row.lock_version
    })

    {:ok, Repo.preload(row, [:profile, :owner_profile], force: true)}
  end

  defp announced({:error, reason}, _group), do: {:error, reason}

  defp name(name) when is_binary(name) do
    name = String.trim(name)
    if String.length(name) in 1..@max_name, do: {:ok, name}, else: {:error, :invalid_name}
  end

  defp name(_name), do: {:error, :invalid_name}

  defp graph(graph) do
    case Graph.normalize(graph) do
      {:ok, graph} -> {:ok, graph}
      {:error, {path, reason}} -> {:error, {:invalid_graph, path, reason}}
    end
  end

  # The positions of the graph's elements, whole numbers within reach; the
  # rest is dropped, as a wide screen sets them again.
  defp layout(%{"nodes" => positions}, graph) when is_map(positions) do
    ids = MapSet.new(graph["nodes"], & &1["id"])

    nodes =
      for {id, [x, y]} <- positions,
          MapSet.member?(ids, id),
          is_number(x) and is_number(y),
          abs(x) <= @max_coordinate and abs(y) <= @max_coordinate,
          into: %{},
          do: {id, [round(x), round(y)]}

    %{"nodes" => nodes}
  end

  defp layout(_layout, _graph), do: %{}
end
