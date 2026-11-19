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
  - A process that starts on a value, by hand, on a call or on a signal may
    take an entity of the group (`entry_entity_id`): a caller then hands it
    that entity's attributes, each of its type, as the process was saved
    with them, and a Start button asks for them in a form.
  - A drawing whose entities changed since it was saved, or whose calls and
    signals no longer fit those they talk to, is stale (`stale?/2`): it runs
    on as it was saved, and its editors are told to look it over.
  - A process that others call is private, for the processes of its own
    group, until an editor makes it public (`set_public/4`): then the
    processes drawn in the groups above and below its group may call it
    too (`Processes.Reach`), handing over what it takes. Those callers do
    not keep it from being deleted or made private again: their calls then
    fail, and their drawings are stale.
  - A new drawing is off. Switching it on brings its profile into the app's
    group; switching it off cancels its instances that run or wait and takes
    the profile out, as removing an app's rule does (`AppProcesses.stop/2`).
  - A change applies to the instances that start after it.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.{
    Check,
    Engine,
    Graph,
    GroupEntities,
    Reach,
    Scheduler,
    Triggers,
    Types
  }

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
  other triggers need no app. One that others call is public with
  `attrs["is_public"]` true, and hands an entity of the group back to its
  caller with `attrs["return_entity_id"]`, which each of its ends fills in.
  Returns `{:ok, process}` or `{:error, reason}`:
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
         {:ok, entity} <- entry_entity(group, trigger, attrs["entry_entity_id"]),
         {:ok, returns} <- return_entity(group, trigger, attrs["return_entity_id"]),
         {:ok, graph} <- checked(graph, trigger, config, group, {entity, returns}, nil),
         :ok <- related_here(group, config, graph),
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
          trigger_config: config,
          entry_entity_id: entity,
          return_entity_id: returns,
          is_public: trigger == "process" and attrs["is_public"] == true,
          hears_related: hears_related?(trigger, config)
        }
        |> Repo.insert!()
      end)
      |> announced(group)
    end
  end

  @doc """
  How many active processes of the groups above and below hear each signal
  from them, `%{name => count}`: those that start on it (`hears_related`) and
  those that wait for it at a step that does (`related`). For the editor of a
  process that sends one; empty when the look takes too long.
  """
  def related_hearers(%Group{id: group_id}) do
    hearers =
      from(p in AppProcess,
        where: p.drawn and p.active and p.group_id != ^group_id,
        where:
          p.hears_related or
            fragment(
              "jsonb_path_exists(?, '$.nodes[*] \\? (@.type == \"receiveTask\" && @.related == true)')",
              p.graph
            ),
        select: {p.group_id, p.trigger, p.trigger_config, p.graph}
      )
      |> Repo.all()

    case Reach.related_among(group_id, Enum.map(hearers, &elem(&1, 0))) do
      {:ok, related} ->
        hearers
        |> Enum.filter(&(elem(&1, 0) in related))
        |> Enum.flat_map(fn {_group, trigger, config, graph} ->
          waits =
            for %{"type" => "receiveTask", "related" => true, "signal" => name} <-
                  graph["nodes"] || [],
                do: name

          starts =
            if trigger == "signal" and config["related"] == true, do: [config["name"]], else: []

          Enum.uniq(waits ++ starts)
        end)
        |> Enum.frequencies()

      {:error, :timeout} ->
        %{}
    end
  end

  # Whether a process on a signal hears the groups above and below too.
  defp hears_related?("signal", %{"related" => true}), do: true
  defp hears_related?(_trigger, _config), do: false

  # The root stands above every group, so a process of its own that heard
  # them would hear all of Potok: neither its trigger nor a wait of it may.
  defp related_here(%Group{is_root: true}, config, graph) do
    cond do
      config["related"] == true ->
        {:error, {:invalid_trigger, "related", :root}}

      i = Enum.find_index(graph["nodes"] || [], &(&1["related"] == true)) ->
        {:error, {:invalid_graph, "nodes.#{i}.related", :root}}

      true ->
        :ok
    end
  end

  defp related_here(_group, _config, _graph), do: :ok

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

  # The entity a process takes when it starts, of the group's own, where its
  # trigger lets it take one.
  defp entry_entity(_group, _trigger, none) when none in [nil, ""], do: {:ok, nil}

  defp entry_entity(%Group{} = group, trigger, id) do
    id = if is_binary(id), do: parse_id(id), else: id

    cond do
      not Triggers.typed?(trigger) ->
        {:error, {:invalid_trigger, "entity", :invalid}}

      is_nil(GroupEntities.get(group, id)) ->
        {:error, {:invalid_trigger, "entity", :unknown_entity}}

      true ->
        {:ok, id}
    end
  end

  # The entity a process hands back to its caller, of the group's own: only
  # one that others call hands anything back.
  defp return_entity(_group, _trigger, none) when none in [nil, ""], do: {:ok, nil}

  defp return_entity(%Group{} = group, trigger, id) do
    id = if is_binary(id), do: parse_id(id), else: id

    cond do
      trigger != "process" ->
        {:error, {:invalid_trigger, "returns", :invalid}}

      is_nil(GroupEntities.get(group, id)) ->
        {:error, {:invalid_trigger, "returns", :unknown_entity}}

      true ->
        {:ok, id}
    end
  end

  defp parse_id(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _other -> nil
    end
  end

  # What a graph of today says, checked against what its trigger hands a
  # run, the entities of its group, the processes it calls and those that
  # wait for its signals, which is written into it (`Check`); one in the
  # first language says nothing to check. `except` is the process itself,
  # which is not among those its own signals are checked against.
  defp checked(%{"v" => 2} = graph, trigger, config, group, {entity, returns}, except) do
    env = %{
      trigger: trigger,
      config: config,
      entry_entity: entity,
      return_entity: returns,
      entities: GroupEntities.definitions(group),
      callable: contracts(graph, group),
      signals: signal_entities(group, except)
    }

    case Check.run(graph, env) do
      {:ok, graph} -> {:ok, graph}
      {:error, {"entry", reason}} -> {:error, {:invalid_trigger, "entity", reason}}
      {:error, {"returns", reason}} -> {:error, {:invalid_trigger, "returns", reason}}
      {:error, {path, reason}} -> {:error, {:invalid_graph, path, reason}}
    end
  end

  defp checked(graph, _trigger, _config, _group, _entity, _except), do: {:ok, graph}

  # What each process the graph calls takes, as that process was saved.
  defp contracts(graph, %Group{} = group),
    do: graph |> callees(group) |> Map.new(&{&1.id, contract(&1)})

  # The processes the graph calls that a drawing of the group may call: its
  # group's own, and the public ones of the groups above and below
  # (`Reach`). With `lock`, they are read `FOR SHARE`.
  defp callees(graph, %Group{id: group_id}, lock \\ false) do
    case graph |> Graph.process_refs() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        []

      ids ->
        query =
          from(p in AppProcess, where: p.drawn and p.trigger == "process" and p.id in ^ids)

        if(lock, do: lock(query, "FOR SHARE"), else: query)
        |> Repo.all()
        |> Enum.filter(&Reach.callable?(&1, group_id))
    end
  end

  @doc """
  What a process that others call takes, as it was saved: the `attributes`
  of its entity with the entities those name (`types`), none for one that
  takes plain fields; and `fields`, the names of either. `returns` is the
  id of the entity it hands back (among `types`), nil for none, and
  `returned` its attributes.
  """
  def contract(%AppProcess{entry_entity_id: id, graph: %{"types" => types}} = process)
      when is_integer(id) do
    attributes = Types.attributes(types, id) || []

    Map.merge(
      %{attributes: attributes, types: types, fields: Enum.map(attributes, & &1["name"])},
      handed_back(process)
    )
  end

  def contract(%AppProcess{trigger_config: config} = process) do
    Map.merge(
      %{
        attributes: [],
        types: (process.graph || %{})["types"] || %{},
        fields: config["fields"] || []
      },
      handed_back(process)
    )
  end

  # What a process hands back, as it was saved.
  defp handed_back(%AppProcess{graph: %{"returns" => id, "types" => types}}) when is_integer(id),
    do: %{returns: id, returned: Types.attributes(types, id) || []}

  defp handed_back(_process), do: %{returns: nil, returned: []}

  @doc """
  Whether a drawing no longer fits what it was saved with: an entity it
  names changed or went, a process it calls takes something else now, or
  those who wait for a signal it sends expect another entity. It runs on
  as it was saved; saving it again checks it against things as they are.
  """
  def stale?(%AppProcess{drawn: true, graph: %{"v" => 2} = graph} = row, %Group{} = group) do
    checked(
      graph,
      row.trigger,
      row.trigger_config,
      group,
      {row.entry_entity_id, row.return_entity_id},
      row.id
    ) !=
      {:ok, graph} or gone_callee?(graph, group)
  end

  def stale?(_row, _group), do: false

  # Whether the graph calls a process it may no longer call: one of another
  # group that was deleted or made private.
  defp gone_callee?(graph, group) do
    callable = Map.new(contracts(graph, group), fn {id, contract} -> {id, contract.fields} end)
    Graph.unknown_process(graph, callable) != nil
  end

  @doc """
  Changes the `name`, `graph`, `layout`, the trigger's settings
  (`trigger_config`; the trigger itself stays) and, where `attrs` says so,
  the entity it takes (`entry_entity_id`) and whether it is public
  (`is_public`, for one that others call) of a drawn process, from the
  `revision` the editor started from (and so `return_entity_id`, what it
  hands back to its caller); another editor's change in between
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

        # The entity it takes stays unless the editor names another, or none.
        entity =
          if Map.has_key?(attrs, "entry_entity_id") do
            case entry_entity(group, row.trigger, attrs["entry_entity_id"]) do
              {:ok, entity} -> entity
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            row.entry_entity_id
          end

        returns =
          if Map.has_key?(attrs, "return_entity_id") do
            case return_entity(group, row.trigger, attrs["return_entity_id"]) do
              {:ok, returns} -> returns
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            row.return_entity_id
          end

        graph =
          case checked(graph, row.trigger, config, group, {entity, returns}, row.id) do
            {:ok, graph} -> graph
            {:error, reason} -> Repo.rollback(reason)
          end

        with {:error, reason} <- related_here(group, config, graph), do: Repo.rollback(reason)

        public? =
          if Map.has_key?(attrs, "is_public"),
            do: row.trigger == "process" and attrs["is_public"] == true,
            else: row.is_public

        row
        |> Ecto.Changeset.change(
          name: name,
          graph: graph,
          layout: layout,
          trigger_config: config,
          entry_entity_id: entity,
          return_entity_id: returns,
          is_public: public?,
          hears_related: hears_related?(row.trigger, config),
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
  Makes a process that others call public, for the processes drawn in the
  groups above and below its group to call too, or private again, for its
  own group's alone. Only a process that starts when another calls it can
  be public (`{:error, :not_callable}`).
  """
  def set_public(%Profile{} = editor, %Group{} = group, id, public?) when is_boolean(public?) do
    changing(editor, group, id, fn row, _access ->
      if row.trigger != "process", do: Repo.rollback(:not_callable)
      row |> Ecto.Changeset.change(is_public: public?) |> Repo.update!()
    end)
  end

  @doc """
  Starts a run of a process that starts by hand, for someone holding one of
  its roles (the app's editors always may): with a `title` and a `text` its
  texts read, or, for a process that takes an entity, with a value for each
  of its attributes, read as the attribute's type (a time without an offset
  in `attrs["time_zone"]`). At most
  #{elem(PotokIde.RateLimit.limit(:process_manual_start), 0)} an hour per person and
  process. Returns `{:ok, instance}` or `{:error, reason}`: `:not_found`,
  `:invalid_title`, `:invalid_text`, `{:invalid_field, name, reason}`,
  `:process_inactive`, `:not_permitted` or `{:rate_limited, retry_after_ms}`.
  """
  def start(%Profile{} = profile, %Group{} = group, id, attrs) when is_map(attrs) do
    with %AppProcess{trigger: "manual"} = drawn <- get(group, id) || {:error, :not_found},
         {:ok, data} <- start_data(drawn, attrs),
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
          data: Map.put(data, "author", profile.username)
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

  # What a run started by hand starts with: the attributes of the entity
  # the process takes, as it was saved, or a title and a text.
  defp start_data(%AppProcess{entry_entity_id: id, graph: %{"types" => types}}, attrs)
       when is_integer(id) do
    names = for attribute <- Types.attributes(types, id) || [], do: attribute["name"]
    zone = if is_binary(attrs["time_zone"]), do: attrs["time_zone"], else: "Etc/UTC"

    case Types.cast(Map.take(attrs, names), {:entity, id}, types, required: true, zone: zone) do
      {:ok, value} -> {:ok, Types.dump(value)}
      {:error, {reason, name}} -> {:error, {:invalid_field, name, reason}}
    end
  end

  defp start_data(%AppProcess{}, attrs) do
    with {:ok, title} <- start_text(attrs["title"], 1..@max_title, :invalid_title),
         {:ok, text} <- start_text(attrs["text"] || "", 0..@max_start_text, :invalid_text) do
      {:ok, %{"title" => title, "text" => text}}
    end
  end

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
  name, each with the names of the fields its senders put in it, or of the
  attributes of the entity it is waited for with.
  """
  def signals(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn,
      select: {p.graph, p.trigger, p.trigger_config, p.entry_entity_id}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {graph, trigger, config, entry} ->
      names = fn id ->
        for attribute <- Types.attributes(graph["types"] || %{}, id) || [], do: attribute["name"]
      end

      started = if trigger == "signal", do: [{config["name"], names.(entry)}], else: []

      started ++
        Enum.flat_map(graph["nodes"] || [], fn
          %{"action" => "signal", "name" => name} = step ->
            [{name, Enum.map(step["fields"] || [], & &1["name"])}]

          %{"type" => "receiveTask", "signal" => name} = wait ->
            [{name, names.(wait["entity"])}]

          _other ->
            []
        end)
    end)
    |> Enum.reduce(%{}, fn {name, fields}, acc ->
      if is_binary(name), do: Map.update(acc, name, fields, &Enum.uniq(&1 ++ fields)), else: acc
    end)
  end

  @doc """
  The entities the group's drawn processes wait for each signal with, by
  the signal's name: the id of an entity, or nil for a wait that names
  none. `except` leaves one process out, which checks its own signals
  against the others.
  """
  def signal_entities(%Group{id: group_id}, except \\ nil) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn,
      select: {p.id, p.graph, p.trigger, p.trigger_config, p.entry_entity_id}
    )
    |> Repo.all()
    |> Enum.reject(&(elem(&1, 0) == except))
    |> Enum.flat_map(fn {_id, graph, trigger, config, entry} ->
      started = if trigger == "signal", do: [{config["name"], entry}], else: []

      started ++
        for(
          %{"type" => "receiveTask", "signal" => name} = wait <- graph["nodes"] || [],
          do: {name, wait["entity"]}
        )
    end)
    |> Enum.filter(&is_binary(elem(&1, 0)))
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, entities} -> {name, Enum.uniq(entities)} end)
  end

  @doc """
  The drawn processes a process of the group may call, as `%{id, name,
  active, public, group, fields, attributes, types}`: what each takes
  (`contract/1`), `fields` being the names a call fills in. The group's own
  come first, by name, with `group` nil; then the public ones of the groups
  above and below (`Reach`), by the name of their `group`.
  """
  def callable(%Group{id: group_id}) do
    own =
      from(p in AppProcess,
        where: p.group_id == ^group_id and p.drawn and p.trigger == "process",
        order_by: [asc: p.name, asc: p.id]
      )
      |> Repo.all()
      |> Enum.map(&offered(&1, nil))

    others =
      case Reach.public_ids(group_id) do
        [] ->
          []

        ids ->
          from(p in AppProcess,
            join: g in assoc(p, :group),
            where: p.id in ^ids and p.drawn and p.is_public and p.trigger == "process",
            order_by: [asc: g.name, asc: p.name, asc: p.id],
            select: {p, g.name}
          )
          |> Repo.all()
          |> Enum.map(fn {process, group} -> offered(process, group) end)
      end

    own ++ others
  end

  defp offered(%AppProcess{} = process, group) do
    Map.merge(contract(process), %{
      id: process.id,
      name: process.name,
      active: process.active,
      public: process.is_public,
      group: group
    })
  end

  @doc """
  Deletes a drawn process with its instances, unless another process of the
  group calls it (`{:error, {:in_use, name}}`). Those of other groups that
  call a public one do not keep it: their calls fail from then on. What it
  wrote stays, signed by its profile, which goes once nothing it wrote is
  left (`AppProcesses.sweep/0`).
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

  # The processes the graph calls must be drawn ones that start when another
  # calls them and that a process of the group may call (`callees/3`),
  # taking the fields it hands over. They are read `FOR SHARE`, so one being
  # deleted waits for this save, or this save for it (`caller/2`).
  defp known_processes!(graph, %Group{} = group) do
    callable = graph |> callees(group, true) |> Map.new(&{&1.id, contract(&1).fields})

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
