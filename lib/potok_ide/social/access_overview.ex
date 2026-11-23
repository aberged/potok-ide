defmodule PotokIde.Social.AccessOverview do
  @moduledoc """
  What the access overview on a group's page reads: who holds which roles,
  counted and never named; the rules of the things in the group the viewer
  sees; and the sub-groups one level down. Rules only, never content: a poll's
  rules and not its votes, a collection's rules and not its values.

  The page asks the rules themselves (`PotokIdeWeb.GroupLive.Show.AccessCatalog`);
  this module only reads, and only for a member: someone outside the group sees
  no more than what they may do there and how one comes in.
  """

  import Ecto.Query

  alias PotokIde.Events.Event
  alias PotokIde.Polls.Poll
  alias PotokIde.Processes.ValueProcess
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    Group,
    GroupAltDescription,
    GroupManifest,
    GroupMemberRole,
    Profile,
    Value,
    ValueRules,
    Visibility
  }

  @children_limit 50
  @polls_limit 20

  @doc "How many sub-groups the overview lists at most; `children/2` tells how many there are."
  def children_limit, do: @children_limit

  @doc "How many of the polls still open the overview lists at most, newest first."
  def polls_limit, do: @polls_limit

  @doc """
  Everything the overview shows a member of `group`, read at once when the
  tab opens. Someone outside the group gets nil: the tab shows them only
  their own column and the statute, which the manifest holds.
  """
  def load(%Group{} = group, %Access{member?: true} = access, profile) do
    alts = Enum.filter(alt_rules(group), &Access.sees_alt_description?(access, &1))
    seen_alt_ids = MapSet.new([nil | Enum.map(alts, & &1.id)])

    %{
      role_sets: role_sets(group),
      role_origins: role_origins(group),
      children: children(group, profile),
      alts: alts,
      polls: open_polls(group, DateTime.utc_now()),
      apps: Enum.filter(app_rules(group), &MapSet.member?(seen_alt_ids, &1.alt_id)),
      processes: drawn_processes(group),
      waiting: waiting_by_role(group),
      public_events: if(group.is_public, do: 0, else: public_events_count(group))
    }
  end

  def load(%Group{}, %Access{}, _profile), do: nil

  @doc """
  The people of `group` by the set of role keys they hold, through the parent
  too: `[%{keys: [key], count: n, inherited: n}]`, the keys sorted and without
  Everyone, `inherited` counting those who are members through the parent.
  One query however many members, so the overview counts the holders of a
  role, or of a permission, by working out each set once.
  """
  # The keys are gathered per person before the join, so the members are
  # grouped once: 20 ms for 10,000 members on the dev database.
  def role_sets(%Group{id: group_id}) do
    """
    SELECT coalesce(r.keys, '{}'), count(*)::int, (count(*) FILTER (WHERE gm.inherited))::int
    FROM group_memberships gm
    JOIN profiles p ON p.id = gm.profile_id AND p.kind = 'person'
    LEFT JOIN (
      SELECT profile_id, array_agg(role_key ORDER BY role_key) AS keys
      FROM group_member_roles
      WHERE group_id = $1
      GROUP BY profile_id
    ) r ON r.profile_id = gm.profile_id
    WHERE gm.group_id = $1
    GROUP BY 1
    """
    |> Repo.query!([group_id])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [keys, count, inherited] ->
      %{keys: keys, count: count, inherited: inherited}
    end)
  end

  @doc """
  How each role of `group` is held, by people: `%{key => %{count: n,
  inherited: n, decided: n}}`, where `inherited` came through the parent and
  `decided` was given by a decision of a poll.
  """
  def role_origins(%Group{id: group_id}) do
    from(r in GroupMemberRole,
      join: p in Profile,
      on: p.id == r.profile_id,
      where: r.group_id == ^group_id and p.kind == :person,
      group_by: r.role_key,
      select:
        {r.role_key,
         %{
           count: count(r.profile_id),
           inherited: filter(count(r.profile_id), r.inherited),
           decided: filter(count(r.profile_id), not is_nil(r.poll_id) and not r.inherited)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The sub-groups of `group` the profile sees, one level down, with how each
  one lets people in: `%{entries: [...], total: n}`, at most
  `children_limit/0` entries by name. Threads and direct conversations are
  not among them, and a shortcut stands in another group, so it is not either.
  """
  def children(%Group{id: group_id}, profile) do
    base =
      profile
      |> Visibility.plain_groups()
      |> where([group: g], g.parent_id == ^group_id)

    entries =
      from([group: g] in base,
        order_by: [asc: g.name, asc: g.id],
        limit: @children_limit,
        select: %{
          id: g.id,
          name: g.name,
          preset: g.preset,
          is_public: g.is_public,
          inherits_members: g.inherits_members,
          inherit_role_keys: g.inherit_role_keys,
          open_chat?: g.has_public_chat and g.is_public,
          member_count: g.member_count,
          own_manifest?:
            exists(from(m in GroupManifest, where: m.group_id == parent_as(:group).id))
        }
      )
      |> Repo.all()

    total =
      if length(entries) < @children_limit,
        do: length(entries),
        else: Repo.aggregate(base, :count)

    %{entries: entries, total: total}
  end

  @doc "The alternative descriptions of `group` with who sees them, without their text."
  def alt_rules(%Group{id: group_id}) do
    from(a in GroupAltDescription,
      where: a.group_id == ^group_id,
      order_by: [asc: a.position, asc: a.id],
      select: struct(a, [:id, :name, :uses_api, :visible_role_keys, :for_guests, :position])
    )
    |> Repo.all()
  end

  @doc "The polls of `group` still open at `now`, newest first, with their rules."
  def open_polls(%Group{id: group_id}, %DateTime{} = now) do
    from(p in Poll,
      where: p.group_id == ^group_id and is_nil(p.closed_at),
      where: is_nil(p.closes_at) or p.closes_at > ^now,
      order_by: [desc: p.id],
      limit: @polls_limit,
      select:
        struct(p, [
          :id,
          :group_id,
          :creator_id,
          :question,
          :secret,
          :is_public,
          :closes_at,
          :closed_at,
          :voter_role_keys,
          :results_role_keys,
          :details_role_keys,
          :results_when,
          :details_when,
          :unique_votes,
          :shared_votes,
          :effect,
          :effect_role_key
        ])
    )
    |> Repo.all()
  end

  @doc """
  The rules of the collections of each app of `group`: `[%{alt_id: id | nil,
  rules: %{collection => rule}}]`, `alt_id` nil for the group's own
  description, each rule as `ValueRules.rule/2` gives it.
  """
  def app_rules(%Group{id: group_id}) do
    from(v in Value,
      where: v.group_id == ^group_id and v.is_data and v.collection == "config",
      distinct: v.alt_description_id,
      order_by: [asc: v.alt_description_id, desc: v.id]
    )
    |> Repo.all()
    |> Enum.map(fn config ->
      rules = AppData.rules(config)

      %{
        alt_id: config.alt_description_id,
        rules:
          Map.new(rules, fn {collection, _raw} ->
            {collection, ValueRules.rule(rules, collection)}
          end)
      }
    end)
    |> Enum.reject(&(&1.rules == %{}))
  end

  @doc "The processes drawn in `group`, with what starts them and the roles their steps ask."
  def drawn_processes(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.drawn,
      order_by: [asc: p.name, asc: p.id],
      select: struct(p, [:id, :name, :trigger, :trigger_config, :graph, :active, :is_public])
    )
    |> Repo.all()
  end

  @doc "How many runs of the processes drawn in `group` wait on each role: `%{key => n}`."
  def waiting_by_role(%Group{id: group_id}) do
    from(i in ValueProcess,
      join: p in AppProcess,
      on: p.id == i.app_process_id,
      where: p.group_id == ^group_id and p.drawn and p.active and i.status == :waiting,
      where: not is_nil(i.asks_role),
      group_by: i.asks_role,
      select: {i.asks_role, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  How many events of `group` are public and not cancelled: every signed-in
  profile sees them in its calendar, even when the group is private.
  """
  def public_events_count(%Group{id: group_id}) do
    from(e in Event,
      where: e.group_id == ^group_id and e.is_public and is_nil(e.cancelled_at),
      select: count(e.id)
    )
    |> Repo.one()
  end
end
