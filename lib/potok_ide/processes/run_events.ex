defmodule PotokIde.Processes.RunEvents do
  @moduledoc """
  The trace of the runs of a group's processes: what each run did, step by
  step, when, and who answered it (`PotokIde.Processes.RunEvent`).

  Those who edit the group read all of it, with what the steps made of the
  variables; other members the runs they took part in, started or answered,
  without the variables. Nobody outside the group reads any.
  """

  import Ecto.Query

  alias PotokIde.Processes.RunEvent
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, Profile, ValueRules}

  @page 20
  @events 500

  # As long as a run that ended keeps its data (`Processes.slim_ended/1`).
  @vars_days 30

  @doc "How many runs a page has."
  def page_size, do: @page

  @doc """
  The runs of a process the viewer may read, the newest first, `page_size/0`
  of them after the one that started with event `before`: `{runs, more?}`, a
  run as `%{id, event_id, at, actor, last}`, `last` being its last event.
  """
  def runs(group, process_id, access, profile, before \\ nil)

  def runs(%Group{id: group_id}, process_id, %Access{member?: true} = access, profile, before)
      when is_integer(process_id) do
    started =
      from(s in RunEvent,
        as: :event,
        left_join: a in assoc(s, :actor),
        where:
          s.group_id == ^group_id and s.app_process_id == ^process_id and s.kind == "started",
        order_by: [desc: s.id],
        limit: ^(@page + 1),
        preload: [actor: a]
      )
      |> mine(access, profile)

    started = if before, do: where(started, [s], s.id < ^before), else: started
    {page, rest} = started |> Repo.all() |> Enum.split(@page)
    last = last_events(Enum.map(page, & &1.run_id))

    runs =
      for event <- page do
        %{
          id: event.run_id,
          event_id: event.id,
          at: event.at,
          actor: event.actor,
          last: Map.get(last, event.run_id, event)
        }
      end

    {runs, rest != []}
  end

  def runs(_group, _process_id, _access, _profile, _before), do: {[], false}

  defp last_events([]), do: %{}

  defp last_events(run_ids) do
    from(e in RunEvent,
      where: e.run_id in ^run_ids,
      distinct: e.run_id,
      order_by: [asc: e.run_id, desc: e.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.run_id, &1})
  end

  # Whoever does not edit the group reads what they had a part in.
  defp mine(query, %Access{} = access, profile) do
    if ValueRules.manage?(access) do
      query
    else
      profile_id = if match?(%Profile{}, profile), do: profile.id, else: 0

      part =
        from(m in RunEvent,
          where: m.run_id == parent_as(:event).run_id and m.actor_id == ^profile_id,
          select: 1
        )

      where(query, exists(part))
    end
  end

  @doc "What a run did, in order, for a viewer who may read it; `[]` for others."
  def events(%Group{id: group_id}, run_id, %Access{member?: true} = access, profile)
      when is_integer(run_id) do
    from(e in RunEvent,
      as: :event,
      left_join: a in assoc(e, :actor),
      where: e.group_id == ^group_id and e.run_id == ^run_id,
      order_by: [asc: e.id],
      limit: @events,
      preload: [actor: a]
    )
    |> mine(access, profile)
    |> Repo.all()
    |> Enum.map(&if(ValueRules.manage?(access), do: &1, else: %{&1 | vars: nil}))
  end

  def events(_group, _run_id, _access, _profile), do: []

  @doc """
  Forgets what the steps made of the variables #{@vars_days} days ago, as runs
  that ended do. The hourly sweep calls it. Returns how many events it did.
  """
  def forget_vars(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@vars_days, :day)

    {count, _} =
      from(e in RunEvent, where: not is_nil(e.vars) and e.at < ^cutoff)
      |> Repo.update_all(set: [vars: nil])

    count
  end
end
