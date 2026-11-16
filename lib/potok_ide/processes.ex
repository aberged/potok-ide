defmodule PotokIde.Processes do
  @moduledoc """
  The instances of apps' processes as an app shows them and acts on them
  (`PotokIdeWeb.GroupLive.Show.AppApi`): always within one app, the one its
  group's page has open.

  - The viewer sees the instances of the values they may read in full, and of
    their own values (`ValueRules.full_reader?/2`).
  - A task is finished by someone holding its role (`Engine.complete_task/5`);
    a failed instance is taken up again, and one under way cancelled, by the
    app's editors (`ValueRules.manage?/1`).
  - What moves an instance wakes this node's scheduler, so its next steps do
    not wait for the next pass.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Processes.{Engine, Graph, Scheduler, ValueProcess}
  alias PotokIde.Social.{Access, AppData, AppProcess, Group, Profile, Value, ValueRules}

  @max_list 100
  @max_tasks 50
  @max_rows 30
  @max_depth 3
  @max_cell 200

  @doc """
  The instances of `collection` the viewer may see, newest first, at most
  #{@max_list}; `ids` keeps those of these values.
  """
  def list(profile, %Group{} = group, alt, %Access{} = access, collection, opts \\ []) do
    rule = group |> AppData.get_config(alt) |> AppData.rule(collection)

    query =
      from(i in ValueProcess,
        join: p in AppProcess,
        on: p.id == i.app_process_id,
        join: v in Value,
        on: v.id == i.value_id,
        where: p.group_id == ^group.id and p.collection == ^collection and not p.drawn,
        order_by: [desc: i.id],
        limit: @max_list
      )
      |> of_app(AppData.alt_id(alt))
      |> only_values(opts[:ids])
      |> seen_by(profile, ValueRules.full_reader?(rule, access))

    instances = Repo.all(query)
    names = names(Enum.flat_map(instances, fn instance -> Enum.map(instance.log, & &1["by"]) end))

    Enum.map(instances, &present(&1, access, names))
  end

  # `:any` is every app of the group, for its page's list of processes.
  defp of_app(query, :any), do: query
  defp of_app(query, nil), do: where(query, [_i, p], is_nil(p.alt_description_id))
  defp of_app(query, alt_id), do: where(query, [_i, p], p.alt_description_id == ^alt_id)

  defp only_values(query, ids) when is_list(ids), do: where(query, [i], i.value_id in ^ids)
  defp only_values(query, _ids), do: query

  defp seen_by(query, _profile, true), do: query
  defp seen_by(query, nil, false), do: where(query, false)

  defp seen_by(query, %Profile{id: profile_id}, false),
    do: where(query, [_i, _p, v], v.creator_id == ^profile_id)

  @doc """
  Finishes the task instance `id` waits on, as `profile` picks `outcome`,
  when the instance is of this app. Returns `{:ok, presented}` or the
  engine's refusal.
  """
  def complete_task(
        %Profile{} = profile,
        %Group{} = group,
        alt,
        %Access{} = access,
        id,
        element,
        outcome,
        comment
      ) do
    with %ValueProcess{} <- of_this_app(group, alt, id) || {:error, :not_found},
         true <- (is_binary(element) and is_binary(outcome)) || {:error, :invalid_outcome},
         {:ok, instance} <- Engine.complete_task(profile, id, element, outcome, comment) do
      Scheduler.nudge()
      {:ok, present(instance, access)}
    end
  end

  @doc """
  Takes up again a failed instance of this app, for its editors; `alt`
  `:any` takes any app of the group, as the group's list of processes does.
  """
  def retry(%Group{} = group, alt, %Access{} = access, id) do
    with :ok <- editor(access),
         %ValueProcess{} <- of_this_app(group, alt, id) || {:error, :not_found},
         {:ok, instance} <- Engine.retry(id) do
      Scheduler.nudge()
      {:ok, present(instance, access)}
    end
  end

  @doc "Cancels an instance of this app that runs or waits, for its editors."
  def cancel(%Group{} = group, alt, %Access{} = access, id) do
    with :ok <- editor(access),
         %ValueProcess{} <- of_this_app(group, alt, id) || {:error, :not_found},
         {:ok, instance} <- Engine.cancel(id) do
      {:ok, present(instance, access)}
    end
  end

  defp editor(access), do: if(ValueRules.manage?(access), do: :ok, else: {:error, :not_permitted})

  # An app reaches only its own process's instances; the group's page, any.
  defp of_this_app(%Group{id: group_id}, :any, id) when is_integer(id) do
    from(i in ValueProcess,
      join: p in AppProcess,
      on: p.id == i.app_process_id,
      where: i.id == ^id and p.group_id == ^group_id
    )
    |> Repo.one()
  end

  defp of_this_app(%Group{id: group_id}, alt, id) when is_integer(id) do
    from(i in ValueProcess,
      join: p in AppProcess,
      on: p.id == i.app_process_id,
      where: i.id == ^id and p.group_id == ^group_id and not p.drawn
    )
    |> of_app(AppData.alt_id(alt))
    |> Repo.one()
  end

  defp of_this_app(_group, _alt, _id), do: nil

  @doc """
  How many instances of each of `app_process_ids` are in each state, as
  `%{app_process_id => %{running: n, waiting: n, done: n, failed: n, cancelled: n}}`,
  with the states that have none left out.
  """
  def counts([]), do: %{}

  def counts(app_process_ids) when is_list(app_process_ids) do
    from(i in ValueProcess,
      where: i.app_process_id in ^app_process_ids,
      group_by: [i.app_process_id, i.status],
      select: {i.app_process_id, i.status, count()}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, status, n}, acc ->
      Map.update(acc, id, %{status => n}, &Map.put(&1, status, n))
    end)
  end

  @doc "The failed instances of a process, the latest first, at most `limit`."
  def failed(app_process_id, limit \\ 20) do
    from(i in ValueProcess,
      where: i.app_process_id == ^app_process_id and i.status == :failed,
      order_by: [desc: i.updated_at, desc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  The tasks of processes drawn in Potok (`PotokIde.Social.DrawnProcesses`)
  that wait on a role the viewer holds in `group`, the nearest deadline first,
  at most #{@max_tasks}. The app knows nothing of these, so the group's page
  shows them, each with what set it going (`kind`):

  - `:value`, a value of an app's collection: its author, unless the value is
    anonymous, and its data and the sub-groups the instance made only for
    those who may read the value in full, or wrote it
    (`ValueRules.full_reader?/2`);
  - `:message`, a chat message of the group, which its members read;
  - `:group`, a new sub-group, with a link to it;
  - `:data`, a run started by hand or by a schedule, with what it was given;
  - `:call`, a run another process called, and `:signal`, one a signal
    started, with the fields it was given and that process's name as its
    title (a run on a value or a sub-group shows that instead).
  """
  def tasks_for(%Profile{} = profile, %Group{} = group, %Access{member?: true} = access)
      when access.role_keys != [] do
    rows =
      from(i in ValueProcess,
        join: p in AppProcess,
        on: p.id == i.app_process_id,
        left_join: v in Value,
        on: v.id == i.value_id,
        left_join: sg in Group,
        on: sg.id == i.subject_group_id,
        where: p.group_id == ^group.id and p.drawn and p.active and i.status == :waiting,
        where:
          fragment(
            "(jsonb_path_query_first(?, '$.nodes[*] \\? (@.id == $e)', jsonb_build_object('e', ?)) ->> 'role') = ANY(?)",
            i.graph,
            i.element,
            type(^access.role_keys, {:array, :string})
          ),
        order_by: [asc_nulls_last: i.wake_at, asc: i.id],
        limit: @max_tasks,
        preload: [value: {v, :creator}, subject_group: sg],
        select: {i, p}
      )
      |> Repo.all()

    rules = rules_by_app(group, for({%ValueProcess{value: %Value{} = v}, _p} <- rows, do: v))
    names = names(Enum.flat_map(rows, fn {i, _p} -> Enum.map(i.log, & &1["by"]) end))
    group_names = group_names(Enum.flat_map(rows, fn {i, _p} -> Map.values(i.groups) end))

    Enum.map(rows, fn {instance, process} ->
      task = Graph.node(instance.graph, instance.element)
      subject = subject(instance, process, group, profile, access, rules)

      Map.merge(subject, %{
        id: instance.id,
        process: process,
        element: instance.element,
        label: Graph.label(task),
        outcomes: task["outcomes"],
        deadline_at: instance.wake_at,
        groups:
          if(subject.reads?,
            do:
              for(
                {_element, id} <- instance.groups,
                name = Map.get(group_names, id),
                do: %{id: id, name: name}
              ),
            else: []
          ),
        log: log(instance, names)
      })
    end)
  end

  def tasks_for(_profile, _group, _access), do: []

  # What set a run going, as its task card shows it. A value of a collection
  # is read by its own collection's rule, also in a run another process
  # started on it.
  defp subject(
         %ValueProcess{value: %Value{collection: collection} = value},
         _process,
         _group,
         profile,
         access,
         rules
       )
       when is_binary(collection) do
    rule = Map.fetch!(rules, {value.alt_description_id, collection})
    reads? = ValueRules.full_reader?(rule, access) or value.creator_id == profile.id

    %{
      kind: :value,
      reads?: reads?,
      sent_at: value.inserted_at,
      author_name: if(value.anonymous, do: nil, else: value.creator.username),
      title: nil,
      text: nil,
      link: nil,
      data: if(reads?, do: data_rows(value.data), else: [])
    }
  end

  defp subject(%ValueProcess{value: %Value{} = value}, _process, group, _profile, _access, _rules) do
    %{
      kind: :message,
      reads?: true,
      sent_at: value.inserted_at,
      author_name: value.creator.username,
      title: nil,
      text: value.content,
      link: "/groups/#{group.id}/values?value=#{value.id}",
      data: []
    }
  end

  defp subject(
         %ValueProcess{subject_group: %Group{} = sub} = instance,
         _process,
         _group,
         _profile,
         _access,
         _rules
       ) do
    %{
      kind: :group,
      reads?: true,
      sent_at: instance.inserted_at,
      author_name: instance.data["author"],
      title: sub.name,
      text: instance.data["description"],
      link: "/groups/#{sub.id}",
      data: []
    }
  end

  # A run another process called, or started by a signal, on nothing but the
  # fields it was given.
  defp subject(
         %ValueProcess{depth: depth} = instance,
         _process,
         _group,
         _profile,
         _access,
         _rules
       )
       when depth > 0 do
    %{
      kind: if(instance.data["signal"], do: :signal, else: :call),
      reads?: true,
      sent_at: instance.inserted_at,
      author_name: nil,
      title: instance.data["from"],
      text: nil,
      link: nil,
      data: data_rows(Map.drop(instance.data, ["from", "signal"]))
    }
  end

  defp subject(%ValueProcess{} = instance, _process, _group, _profile, _access, _rules) do
    %{
      kind: :data,
      reads?: true,
      sent_at: instance.inserted_at,
      author_name: instance.data["author"],
      title: instance.data["title"] || instance.data["date"],
      text: instance.data["text"],
      link: nil,
      data: []
    }
  end

  defp rules_by_app(group, values) do
    values
    |> Enum.filter(&is_binary(&1.collection))
    |> Enum.map(&{&1.alt_description_id, &1.collection})
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {alt_id, collections} ->
      config = AppData.get_config(group, alt_id)
      for collection <- collections, do: {{alt_id, collection}, AppData.rule(config, collection)}
    end)
    |> Map.new()
  end

  defp group_names(ids) do
    case ids |> Enum.filter(&is_integer/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(g in Group, where: g.id in ^ids, select: {g.id, g.name}) |> Repo.all() |> Map.new()
    end
  end

  @doc """
  A value's data as rows of `{path, text}` a person can read, such as
  `{"a.q1", "Da"}`: at most #{@max_rows}, #{@max_depth} levels deep, long
  texts cut short.
  """
  def data_rows(data) when is_map(data) do
    data
    |> flatten([], 1)
    |> Enum.take(@max_rows)
  end

  def data_rows(_data), do: []

  defp flatten(map, path, depth) when is_map(map) and depth <= @max_depth do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} -> flatten(value, path ++ [to_string(key)], depth + 1) end)
  end

  defp flatten(list, path, depth) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) or is_number(&1) or is_boolean(&1))),
      do: [{Enum.join(path, "."), list |> Enum.map_join(", ", &to_string/1) |> cell()}],
      else: flatten(list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end), path, depth)
  end

  defp flatten(value, path, _depth)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: [{Enum.join(path, "."), value |> to_string() |> cell()}]

  defp flatten(nil, _path, _depth), do: []
  defp flatten(_deeper, path, _depth), do: [{Enum.join(path, "."), "…"}]

  defp cell(text) do
    if String.length(text) > @max_cell, do: String.slice(text, 0, @max_cell) <> "…", else: text
  end

  defp log(instance, names) do
    Enum.map(instance.log, fn entry ->
      %{
        at: entry["at"],
        element: entry["element"],
        outcome: entry["outcome"],
        comment: entry["comment"],
        by: %{id: entry["by"], username: Map.get(names, entry["by"])}
      }
    end)
  end

  @doc """
  An instance as the app gets it: where it stands, the task it waits on and
  whether the viewer may finish it, the sub-groups it made, and who decided
  what so far.
  """
  def present(%ValueProcess{} = instance, %Access{} = access, names \\ nil) do
    names = names || names(Enum.map(instance.log, & &1["by"]))

    %{
      id: instance.id,
      value_id: instance.value_id,
      status: Atom.to_string(instance.status),
      element: instance.element,
      wake_at: instance.wake_at && DateTime.to_iso8601(instance.wake_at),
      error: instance.error,
      groups: instance.groups,
      task: task(instance, access),
      log: log(instance, names)
    }
  end

  defp task(%ValueProcess{status: :waiting} = instance, access) do
    case Graph.node(instance.graph, instance.element) do
      %{"type" => "userTask"} = task ->
        %{
          element: task["id"],
          outcomes: task["outcomes"],
          deadline_at: instance.wake_at && DateTime.to_iso8601(instance.wake_at),
          can_complete: task["role"] in access.role_keys
        }

      _timer ->
        nil
    end
  end

  defp task(_instance, _access), do: nil

  defp names(ids) do
    case ids |> Enum.filter(&is_integer/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(p in Profile, where: p.id in ^ids, select: {p.id, p.username})
        |> Repo.all()
        |> Map.new()
    end
  end
end
