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
  - Only a graph an instance can finish is kept (`Graph.normalize/2`), with
    roles the group has, calling only the group's drawn processes that start
    when another calls them, with the fields they take. A process another
    one calls is not deleted.
  - A graph in today's language (`"v" => 2`) is also checked for what it
    says (`Processes.Check`): its expressions name what the process has. One
    in the first language is kept as it comes, as the runs that started with
    it are.
  - A new drawing is off. Switching it on brings its profile into the app's
    group; switching it off cancels its instances that run or wait and takes
    the profile out, as removing an app's rule does (`AppProcesses.stop/2`).
  - A change applies to the instances that start after it.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.{Check, Engine, Graph, Scheduler, Triggers}
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
  @sampled_values 20
  @max_title 120
  @max_start_text 2_000
  @max_fields 30

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

  @doc """
  The fields the newest values of a collection hold, such as `naslov` or
  `a.q1`, for an editor to put into a text as `{{naslov}}`.
  """
  def fields(%Group{} = group, alt_id, collection) when is_binary(collection) do
    from(v in Value,
      where: v.group_id == ^group.id and v.is_data and v.collection == ^collection,
      order_by: [desc: v.id],
      limit: @sampled_values,
      select: v.data
    )
    |> of_alt(alt_id)
    |> Repo.all()
    |> Enum.flat_map(fn data ->
      data |> PotokIde.Processes.data_rows() |> Enum.map(&elem(&1, 0))
    end)
    |> Enum.uniq()
    |> Enum.filter(&Regex.match?(~r/^[\p{L}\p{Nd}_.-]{1,64}$/u, &1))
    |> Enum.take(@max_fields)
  end

  def fields(_group, _alt_id, _collection), do: []

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
  Draws a new process, switched off, with its `name`, `graph`, `layout` and
  what sets it going (`trigger`, `trigger_config`, `Processes.Triggers`). On a
  new value (`"value"`, the default) it hangs on `attrs["collection"]` of the
  app `attrs["alt_id"]` (an integer, nil for the default description); the
  other triggers need no app. Returns `{:ok, process}` or `{:error, reason}`:
  `:not_permitted`, `:not_an_app`, `:unknown_collection`, `:too_many`,
  `:invalid_name`, `{:invalid_graph, path, reason}` or
  `{:invalid_trigger, path, reason}`.
  """
  def create(%Profile{} = editor, %Group{} = group, attrs) when is_map(attrs) do
    trigger = attrs["trigger"] || "value"

    {alt_id, collection} =
      if trigger == "value", do: {attrs["alt_id"], attrs["collection"]}, else: {nil, nil}

    with {:ok, name} <- name(attrs["name"]),
         {:ok, graph} <- graph(attrs["graph"]),
         {:ok, config} <- trigger_config(trigger, attrs["trigger_config"]),
         {:ok, graph} <- checked(graph, trigger, config),
         :ok <- on_collection(group, trigger, alt_id, collection) do
      layout = layout(attrs["layout"], graph)

      Repo.transaction(fn ->
        AppData.lock_app(group, alt_id)
        access = editor_access!(editor, group)
        known_roles!(graph, access)
        known_trigger_roles!(trigger, config, access)
        known_processes!(graph, group)

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
          layout: layout,
          trigger: trigger,
          trigger_config: config
        }
        |> Repo.insert!()
      end)
      |> announced(group)
    end
  end

  defp on_collection(group, "value", alt_id, collection) do
    cond do
      not Enum.any?(apps(group), &(&1.alt_id == alt_id)) -> {:error, :not_an_app}
      collection not in collections(group, alt_id) -> {:error, :unknown_collection}
      true -> :ok
    end
  end

  defp on_collection(_group, trigger, _alt_id, _collection) do
    if trigger in Triggers.all(), do: :ok, else: {:error, {:invalid_trigger, "", :invalid}}
  end

  defp trigger_config(trigger, config) do
    case Triggers.normalize(trigger, config || %{}) do
      {:ok, config} -> {:ok, config}
      {:error, {path, reason}} -> {:error, {:invalid_trigger, path, reason}}
    end
  end

  # What a graph of today says, checked against what its trigger hands a
  # run, which is written into it (`Check`); one in the first language says
  # nothing to check.
  defp checked(graph, trigger, config) do
    case Check.run(graph, %{entry: Triggers.entry(trigger, config)}) do
      {:ok, graph} -> {:ok, graph}
      {:error, {path, reason}} -> {:error, {:invalid_graph, path, reason}}
    end
  end

  @doc """
  Changes the `name`, `graph`, `layout` and the trigger's settings
  (`trigger_config`; the trigger itself stays) of a drawn process, from the
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
        known_processes!(graph, group)

        config =
          case trigger_config(row.trigger, attrs["trigger_config"] || row.trigger_config) do
            {:ok, config} -> config
            {:error, reason} -> Repo.rollback(reason)
          end

        known_trigger_roles!(row.trigger, config, access)

        graph =
          case checked(graph, row.trigger, config) do
            {:ok, graph} -> graph
            {:error, reason} -> Repo.rollback(reason)
          end

        row
        |> Ecto.Changeset.change(
          name: name,
          graph: graph,
          layout: layout,
          trigger_config: config,
          next_run_at: next_run(%{row | trigger_config: config}),
          owner_profile_id: owner(row, editor, group)
        )
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> Repo.update!()
      end)
    end
  end

  # When a scheduled process that is on starts next; nil for every other.
  defp next_run(%AppProcess{active: true, trigger: "schedule", trigger_config: config}),
    do: Triggers.next_run(config, DateTime.utc_now(:second))

  defp next_run(_process), do: nil

  @doc """
  Switches a drawn process on: its profile joins the app's group, and the
  editor owns it. Its next new value starts an instance.
  """
  def activate(%Profile{} = editor, %Group{} = group, id) do
    changing(editor, group, id, fn row, access ->
      known_roles!(row.graph, access)
      known_trigger_roles!(row.trigger, row.trigger_config, access)
      known_processes!(row.graph, group)

      row =
        row
        |> Ecto.Changeset.change(
          active: true,
          owner_profile_id: editor.id,
          next_run_at: next_run(%{row | active: true})
        )
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
      row |> Ecto.Changeset.change(active: false, next_run_at: nil) |> Repo.update!()
    end)
  end

  @doc """
  Starts a run of a process that starts by hand, for someone holding one of
  its roles (the app's editors always may), with a `title` and a `text` its
  texts read. At most #{elem(PotokIde.RateLimit.limit(:process_manual_start), 0)} an hour per
  person and process. Returns `{:ok, instance}` or `{:error, reason}`:
  `:not_found`, `:invalid_title`, `:process_inactive`, `:not_permitted` or
  `{:rate_limited, retry_after_ms}`.
  """
  def start(%Profile{} = profile, %Group{} = group, id, attrs) when is_map(attrs) do
    with {:ok, title} <- start_text(attrs["title"], 1..@max_title, :invalid_title),
         {:ok, text} <- start_text(attrs["text"] || "", 0..@max_start_text, :invalid_text),
         %AppProcess{trigger: "manual"} <- get(group, id) || {:error, :not_found},
         :ok <- rate(profile, id) do
      Repo.transaction(fn ->
        process =
          from(p in AppProcess, where: p.id == ^id and p.group_id == ^group.id, lock: "FOR SHARE")
          |> Repo.one()

        unless process.active, do: Repo.rollback(:process_inactive)
        access = Access.for_profile(profile, Repo.get!(Group, group.id))
        unless may_start?(process, access), do: Repo.rollback(:not_permitted)

        Engine.start_drawn_on(process,
          started_by: profile.id,
          data: %{"title" => title, "text" => text, "author" => profile.username}
        )
      end)
      |> case do
        {:ok, instance} ->
          Scheduler.nudge()

          AppData.broadcast(group, :process, %{
            alt_id: nil,
            collection: nil,
            id: instance.id,
            drawn: true
          })

          {:ok, instance}

        error ->
          error
      end
    end
  end

  @doc "Whether the holder of `access` may start the process by hand."
  def may_start?(%AppProcess{trigger: "manual", trigger_config: config}, %Access{} = access) do
    access.member? and
      (ValueRules.manage?(access) or
         Enum.any?(config["roles"] || ["everyone"], &(&1 in access.role_keys)))
  end

  def may_start?(_process, _access), do: false

  defp start_text(text, range, reason) when is_binary(text) do
    text = String.trim(text)
    if String.length(text) in range, do: {:ok, text}, else: {:error, reason}
  end

  defp start_text(_text, _range, reason), do: {:error, reason}

  defp rate(profile, id) do
    case PotokIde.RateLimit.hit(:process_manual_start, {id, profile.id}) do
      :ok -> :ok
      {:error, :rate_limited, retry_after} -> {:error, {:rate_limited, retry_after}}
    end
  end

  @doc """
  The fields a process's texts may name: those of its trigger with its
  settings (`config`), or for one on a collection, those the collection's
  newest values hold.
  """
  def fields_for(group, trigger, alt_id, collection, config \\ %{})

  def fields_for(%Group{} = group, "value", alt_id, collection, _config),
    do: fields(group, alt_id, collection)

  def fields_for(%Group{} = group, "signal", _alt_id, _collection, config) do
    carried =
      case Graph.signal_name((config || %{})["name"]) do
        {:ok, name} -> Map.get(signals(group), name, [])
        :error -> []
      end

    carried ++ Triggers.fields("signal", config)
  end

  def fields_for(_group, trigger, _alt_id, _collection, config),
    do: Triggers.fields(trigger, config || %{})

  @doc """
  The signals the group's drawn processes send, wait for or start on, by
  name, each with the names of the fields its senders put in it.
  """
  def signals(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn,
      select: {p.graph, p.trigger, p.trigger_config}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {graph, trigger, config} ->
      started = if trigger == "signal", do: [{config["name"], []}], else: []

      started ++
        Enum.flat_map(graph["nodes"] || [], fn
          %{"action" => "signal", "name" => name} = step ->
            [{name, Enum.map(step["fields"] || [], & &1["name"])}]

          %{"type" => "receiveTask", "signal" => name} ->
            [{name, []}]

          _other ->
            []
        end)
    end)
    |> Enum.reduce(%{}, fn {name, fields}, acc ->
      if is_binary(name), do: Map.update(acc, name, fields, &Enum.uniq(&1 ++ fields)), else: acc
    end)
  end

  @doc """
  The group's drawn processes that another may call, by name, as
  `%{id, name, fields, active}`, `fields` being the names each takes.
  """
  def callable(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn and p.trigger == "process",
      order_by: [asc: p.name, asc: p.id],
      select: %{id: p.id, name: p.name, fields: p.trigger_config, active: p.active}
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | fields: &1.fields["fields"] || []})
  end

  @doc """
  Deletes a drawn process with its instances, unless another process of the
  group calls it (`{:error, {:in_use, name}}`). What it wrote stays, signed
  by its profile, which goes once nothing it wrote is left
  (`AppProcesses.sweep/0`).
  """
  def delete(%Profile{} = editor, %Group{} = group, id) do
    changing(editor, group, id, fn row, _access ->
      if name = caller(group, row), do: Repo.rollback({:in_use, name})
      if row.active, do: AppProcesses.stop(group, row)
      Repo.delete!(row)
    end)
  end

  # The name of a drawn process of the group, other than `row`, that calls it.
  # One saved meanwhile waits for the lock on `row` (`known_processes!/2`).
  defp caller(%Group{id: group_id}, %AppProcess{id: id}) do
    from(p in AppProcess,
      where:
        p.group_id == ^group_id and p.drawn and p.id != ^id and
          fragment(
            "jsonb_path_exists(?, '$.nodes[*] \\? (@.type == \"callActivity\" && @.process == $id)', jsonb_build_object('id', ?::bigint))",
            p.graph,
            ^id
          ),
      order_by: [asc: p.name],
      limit: 1,
      select: p.name
    )
    |> Repo.one()
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

  # The processes the graph calls must be the group's drawn ones that start
  # when another calls them, taking the fields it hands over. They are read
  # `FOR SHARE`, so one being deleted waits for this save, or this save for
  # it (`caller/2`).
  defp known_processes!(graph, %Group{id: group_id}) do
    ids = graph |> Graph.process_refs() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    callable =
      if ids == [] do
        %{}
      else
        from(p in AppProcess,
          where: p.group_id == ^group_id and p.drawn and p.trigger == "process" and p.id in ^ids,
          lock: "FOR SHARE",
          select: {p.id, p.trigger_config}
        )
        |> Repo.all()
        |> Map.new(fn {id, config} -> {id, config["fields"] || []} end)
      end

    case Graph.unknown_process(graph, callable) do
      nil -> :ok
      {path, reason} -> Repo.rollback({:invalid_graph, path, reason})
    end
  end

  defp known_trigger_roles!(trigger, config, %Access{manifest: manifest}) do
    keys = AppData.role_keys(manifest)

    case Enum.find(Triggers.role_refs(trigger, config), fn {_path, key} ->
           not MapSet.member?(keys, key)
         end) do
      nil -> :ok
      {path, _key} -> Repo.rollback({:invalid_trigger, path, :unknown_role})
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
    case Graph.normalize(graph, drawn: true) do
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
