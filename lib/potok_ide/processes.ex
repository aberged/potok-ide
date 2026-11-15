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
        where: p.group_id == ^group.id and p.collection == ^collection,
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

  @doc "Takes up again a failed instance of this app, for its editors."
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

  defp of_this_app(%Group{id: group_id}, alt, id) when is_integer(id) do
    from(i in ValueProcess,
      join: p in AppProcess,
      on: p.id == i.app_process_id,
      where: i.id == ^id and p.group_id == ^group_id
    )
    |> of_app(AppData.alt_id(alt))
    |> Repo.one()
  end

  defp of_this_app(_group, _alt, _id), do: nil

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
      log:
        Enum.map(instance.log, fn entry ->
          %{
            at: entry["at"],
            element: entry["element"],
            outcome: entry["outcome"],
            comment: entry["comment"],
            by: %{id: entry["by"], username: Map.get(names, entry["by"])}
          }
        end)
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
