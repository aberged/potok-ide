defmodule PotokIde.Polls.Effects do
  @moduledoc """
  A decision of a poll that changes roles: what it says (`Poll.effect`), who
  may put it to a vote, and how it is carried out as the poll closes.

  - `grant` gives a member a role and `revoke` takes it, when the answer
    that approves (`PollOption.approves`) wins. `end_elections` gives a
    group that elects its admins back to its founders' rule the same way.
  - `elect` gives the role to the member whose answer wins
    (`PollOption.profile_id`), and with `replace` takes it from the others
    who hold it of their own.

  The power comes from the decision: a role a decision gave keeps the poll
  (`GroupMemberRole.poll_id`), and the process that raises such a poll holds
  no more than "everyone" does.

  Who may put it to a vote: in a group that elects its admins
  (`Group.elects_admins`), anyone who may start a poll there; anywhere
  else an admin only, who hands the decision to the group. Never at the root,
  in a direct conversation or in a thread.

  It is carried out in the transaction that closes the poll and never stops
  the closing: what came of it is written to `Poll.effect_status`. A group
  never loses its last admin this way either.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query

  require Logger

  alias PotokIde.Polls.{Notifications, Poll, PollOption}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupMemberRole, GroupMembership, GroupRole, Profile}

  # The form's keys, which a process gives as atoms.
  @keys %{
    "effect" => :effect,
    "effect_role_key" => :effect_role_key,
    "effect_profile_id" => :effect_profile_id,
    "effect_replace" => :effect_replace,
    "candidate_ids" => :candidate_ids,
    "abstain" => :abstain
  }

  @kinds %{
    "grant" => :grant,
    "revoke" => :revoke,
    "elect" => :elect,
    "end_elections" => :end_elections
  }

  @doc "Whether a decision may change roles in the group at all."
  def group_allowed?(%Group{} = group),
    do: not group.is_root and not group.is_direct and is_nil(group.parent_value_id)

  @doc """
  Whether `access` may put a decision of `effect` to a vote in `group`, or
  of any kind with `:any`. `group.elects_admins` is taken as given.
  """
  def may_propose?(%Access{} = access, %Group{} = group, effect \\ :any) do
    group_allowed?(group) and access.member? and
      cond do
        effect == :end_elections -> group.elects_admins and Access.can?(access, :create_polls)
        group.elects_admins -> Access.can?(access, :create_polls)
        true -> access.admin?
      end
  end

  @doc """
  The kinds of decision `access` may put to a vote in `group`, for the form:
  none where it may not, and ending elections only where the group elects.
  """
  def available(%Access{} = access, %Group{} = group) do
    group = %{group | elects_admins: group_allowed?(group) and Social.elects_admins?(group)}

    cond do
      not may_propose?(access, group) -> []
      group.elects_admins -> [:grant, :revoke, :elect, :end_elections]
      true -> [:grant, :revoke, :elect]
    end
  end

  @doc "Members whose names start with `query`, for the form to name one."
  def suggestions(%Group{id: group_id}, query, limit \\ 6) when is_binary(query) do
    case query |> String.trim() |> String.trim_leading("@") |> String.slice(0, 32) do
      "" ->
        []

      query ->
        pattern = String.replace(query, ~r/[\\%_]/, "\\\\\\0") <> "%"

        from(p in Profile,
          join: gm in GroupMembership,
          on: gm.profile_id == p.id and gm.group_id == ^group_id,
          where: p.kind == :person and ilike(p.username, ^pattern),
          order_by: [asc: fragment("lower(?)", p.username)],
          limit: ^limit,
          select: %{id: p.id, username: p.username}
        )
        |> Repo.all()
    end
  end

  @doc "The members of `ids` as `%{id:, username:}`, in that order: people only."
  def members(ids, %Group{} = group) do
    people = people(ids, group)
    for id <- ids, name = Map.get(people, id), do: %{id: id, username: name}
  end

  @doc "The roles a decision may name: the manifest's, but \"everyone\"."
  def roles(%Access{manifest: nil}), do: []

  def roles(%Access{manifest: manifest}),
    do: Enum.reject(manifest.roles, &(&1.key == GroupRole.everyone_key()))

  @doc """
  What the form asks for, checked: `{:ok, nil, []}` for a plain poll, or
  `{:ok, chosen, answers}` with what `Poll.put_effect/3` takes and the
  answers that go with it, in order, as `%{text:, profile_id:, approves:}`.
  `{:error, :not_permitted}` when none of `proposers` (accesses, the
  creator's by default) may put it to a vote, or `{:error, {field, message}}`.

  The form's keys: `effect`, `effect_role_key`, `effect_profile_id`,
  `candidate_ids`, `effect_replace` and `abstain`.
  """
  def normalize(attrs, %Access{} = access, %Group{} = group, proposers \\ nil) do
    case Map.get(@kinds, attr(attrs, "effect")) do
      nil ->
        {:ok, nil, []}

      effect ->
        group = %{group | elects_admins: Social.elects_admins?(group)}

        with :ok <- proposable(proposers || [access], group, effect),
             {:ok, role_key} <- role(effect, attr(attrs, "effect_role_key"), access) do
          named(effect, role_key, attrs, group)
        end
    end
  end

  @doc "The kind of decision the form asks for, or nil."
  def kind(attrs), do: Map.get(@kinds, attr(attrs, "effect"))

  @doc """
  The answers a decision of `kind` fixes before it is complete, for the form
  to show: the answers to approve or not, and none yet for an election.
  """
  def fixed_answers(kind, attrs) when kind in [:grant, :revoke, :end_elections],
    do: yes_no(truthy?(attr(attrs, "abstain")))

  def fixed_answers(_kind, _attrs), do: []

  @doc """
  `attrs` with what `poll` changes, when the form left it out: what a poll
  changes is never lost to an edit that does not say.
  """
  def keep_current(attrs, %Poll{effect: nil}), do: attrs

  def keep_current(attrs, %Poll{} = poll) do
    if Map.has_key?(attrs, "effect") or Map.has_key?(attrs, :effect) do
      attrs
    else
      poll = Repo.preload(poll, :options)

      Map.merge(stringify(attrs), %{
        "effect" => to_string(poll.effect),
        "effect_role_key" => poll.effect_role_key,
        "effect_profile_id" => poll.effect_profile_id,
        "effect_replace" => poll.effect_replace,
        "candidate_ids" => for(o <- poll.options, o.profile_id, do: o.profile_id),
        "abstain" => length(poll.options) > 2
      })
    end
  end

  @doc """
  `attrs` with `answers` as the poll's answers, when a decision fixes them,
  and with what such a poll is: one answer, not public, put to everyone.
  Set before the poll's own rules run, which would otherwise drop the
  decision of a poll with several answers.
  """
  def with_answers(attrs, []), do: attrs

  def with_answers(attrs, answers) do
    options =
      answers
      |> Enum.with_index()
      |> Map.new(fn {answer, index} -> {Integer.to_string(index), %{"text" => answer.text}} end)

    attrs
    |> stringify()
    |> Map.drop(["options_sort", "options_drop"])
    |> Map.merge(%{
      "options" => options,
      "kind" => "single",
      "is_public" => "false",
      "voter_role_keys" => ["everyone"]
    })
  end

  @doc "What `Poll.put_effect/3` marks the answers with."
  def marks(answers), do: Enum.map(answers, &Map.take(&1, [:profile_id, :approves]))

  @doc """
  The member who stands in an election by adding an answer: their own name,
  once. `{:error, :candidate}` when they stand already.
  """
  def candidate(%Poll{effect: :elect, options: options}, %Profile{} = profile) do
    if Enum.any?(options, &(&1.profile_id == profile.id)),
      do: {:error, :candidate},
      else: {:ok, %{text: profile.username, profile_id: profile.id}}
  end

  @doc """
  Carries out what `poll` changes, as it closes with `outcome` and the
  answer `winner` (nil for none), in the caller's transaction. Returns
  `{status, announcements}`: the status for `Poll.effect_status` (nil for a
  plain poll), and what to run once the transaction commits.
  """
  def apply_locked(%Poll{effect: nil}, _group, _outcome, _winner), do: {nil, []}

  def apply_locked(%Poll{} = poll, %Group{} = group, :passed, %PollOption{} = winner) do
    if carried?(poll, winner),
      do: guarded(poll, fn -> carry_out(poll, group, winner) end),
      else: {:rejected, []}
  end

  def apply_locked(%Poll{}, _group, _outcome, _winner), do: {:rejected, []}

  # Polls past their deadline close together in one transaction
  # (`PotokIde.Polls.Deadlines`), so a decision that fails in the database
  # goes back to a savepoint of its own: the poll still closes, saying
  # nothing came of it, and the others close with it.
  defp guarded(%Poll{id: id}, fun) do
    Repo.query!("SAVEPOINT poll_effect")

    try do
      result = fun.()
      Repo.query!("RELEASE SAVEPOINT poll_effect")
      result
    rescue
      exception ->
        Repo.query!("ROLLBACK TO SAVEPOINT poll_effect")
        Logger.error("Decision of poll #{id} failed: " <> Exception.message(exception))
        {nil, []}
    end
  end

  defp carried?(%Poll{effect: :elect}, %PollOption{profile_id: id}), do: is_integer(id)
  defp carried?(%Poll{}, %PollOption{approves: approves}), do: approves

  defp carry_out(%Poll{effect: :grant} = poll, group, _winner) do
    target = poll.effect_profile_id
    manifest = Access.load_effective_manifest(group)

    with :ok <- member(target, group),
         {:ok, role} <- role_there(manifest, poll.effect_role_key),
         :ok <- not_held_through_parent(group, target, role.key) do
      {:ok, _member_role, announce} =
        Social.put_member_role(Repo, group, target, role.key, poll.id)

      {:applied, [announce, push(poll, group, [target], :granted, role)]}
    else
      {:error, status} -> {status, []}
    end
  end

  defp carry_out(%Poll{effect: :revoke} = poll, group, _winner) do
    target = poll.effect_profile_id
    manifest = Access.load_effective_manifest(group)

    with :ok <- member(target, group),
         {:ok, role} <- role_there(manifest, poll.effect_role_key),
         :ok <- own_role(group, target, role.key),
         :ok <- not_last_admin(group, target, role.key) do
      held? = target in holders(group, role.key)
      {:ok, announce} = Social.drop_member_roles(Repo, group, [target], role.key)
      pushes = if held?, do: [push(poll, group, [target], :revoked, role)], else: []
      {:applied, [announce | pushes]}
    else
      {:error, status} -> {status, []}
    end
  end

  defp carry_out(%Poll{effect: :elect} = poll, group, %PollOption{profile_id: elected}) do
    manifest = Access.load_effective_manifest(group)

    with :ok <- member(elected, group),
         {:ok, role} <- role_there(manifest, poll.effect_role_key),
         :ok <- not_held_through_parent(group, elected, role.key) do
      others = if poll.effect_replace, do: holders(group, role.key) -- [elected], else: []
      {:ok, _member_role, put} = Social.put_member_role(Repo, group, elected, role.key, poll.id)

      dropped =
        case others do
          [] ->
            []

          others ->
            {:ok, drop} = Social.drop_member_roles(Repo, group, others, role.key)
            [drop, push(poll, group, others, :revoked, role)]
        end

      {:applied, [put | dropped] ++ [push(poll, group, [elected], :granted, role)]}
    else
      {:error, status} -> {status, []}
    end
  end

  defp carry_out(%Poll{effect: :end_elections}, group, _winner) do
    {:ok, announce} = Social.end_elections(Repo, group)
    {:applied, [announce]}
  end

  ## Checks

  defp proposable(proposers, group, effect) do
    if group_allowed?(group) and Enum.any?(proposers, &may_propose?(&1, group, effect)),
      do: :ok,
      else: {:error, :not_permitted}
  end

  defp role(:end_elections, _key, _access), do: {:ok, nil}

  defp role(_effect, key, access) do
    if is_binary(key) and Enum.any?(roles(access), &(&1.key == key)),
      do: {:ok, key},
      else: {:error, {:effect_role_key, "pick a role"}}
  end

  defp named(effect, role_key, attrs, group) when effect in [:grant, :revoke] do
    with {:ok, profile_id} <- person(attr(attrs, "effect_profile_id"), group, :effect_profile_id),
         :ok <- holds_for_revoke(effect, group, profile_id, role_key) do
      {:ok, %{effect: effect, role_key: role_key, profile_id: profile_id},
       yes_no(truthy?(attr(attrs, "abstain")))}
    end
  end

  defp named(:end_elections, nil, attrs, group) do
    if group.elects_admins,
      do: {:ok, %{effect: :end_elections}, yes_no(truthy?(attr(attrs, "abstain")))},
      else: {:error, :not_permitted}
  end

  defp named(:elect, role_key, attrs, group) do
    ids =
      attrs
      |> attr("candidate_ids")
      |> List.wrap()
      |> Enum.map(&to_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    people = people(ids, group)

    cond do
      length(ids) < Poll.min_options() or length(ids) > Poll.max_options() ->
        {:error, {:candidate_ids, "pick from two to ten members"}}

      map_size(people) != length(ids) ->
        {:error, {:candidate_ids, "can only name members"}}

      true ->
        answers = Enum.map(ids, &%{text: Map.fetch!(people, &1), profile_id: &1})

        {:ok,
         %{effect: :elect, role_key: role_key, replace: truthy?(attr(attrs, "effect_replace"))},
         answers}
    end
  end

  defp yes_no(abstain?) do
    [
      %{text: dgettext("polls", "For"), approves: true},
      %{text: dgettext("polls", "Against")}
    ] ++ if(abstain?, do: [%{text: dgettext("polls", "Abstain")}], else: [])
  end

  defp person(value, group, field) do
    with id when is_integer(id) <- to_id(value),
         %{^id => _username} <- people([id], group) do
      {:ok, id}
    else
      _not_a_member -> {:error, {field, "can only name a member"}}
    end
  end

  # The people of `ids` who are members, by their usernames.
  defp people([], _group), do: %{}

  defp people(ids, %Group{id: group_id}) do
    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id and gm.group_id == ^group_id,
      where: p.id in ^ids and p.kind == :person,
      select: {p.id, p.username}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp holds_for_revoke(:grant, _group, _profile_id, _role_key), do: :ok

  defp holds_for_revoke(:revoke, group, profile_id, role_key) do
    if profile_id in holders(group, role_key),
      do: :ok,
      else: {:error, {:effect_profile_id, "does not hold this role of their own"}}
  end

  defp member(nil, _group), do: {:error, :not_a_member}

  defp member(profile_id, group) do
    if Social.member_of_group?(%Profile{id: profile_id}, group),
      do: :ok,
      else: {:error, :not_a_member}
  end

  defp role_there(nil, _key), do: {:error, :role_gone}

  defp role_there(manifest, key) do
    case Enum.find(manifest.roles, &(&1.key == key and key != GroupRole.everyone_key())) do
      nil -> {:error, :role_gone}
      role -> {:ok, role}
    end
  end

  # A role held through the parent is taken there.
  defp own_role(group, profile_id, key) do
    if key in Map.get(Access.inherited_by_profile(group, [profile_id]), profile_id, []),
      do: {:error, :inherited_role},
      else: :ok
  end

  # A role the member already holds through the parent is the parent's to
  # give: the group's own row cannot take its place.
  defp not_held_through_parent(%Group{id: group_id}, profile_id, key) do
    inherited? =
      Repo.exists?(
        from(r in GroupMemberRole,
          where:
            r.group_id == ^group_id and r.profile_id == ^profile_id and r.role_key == ^key and
              r.inherited
        )
      )

    if inherited?, do: {:error, :inherited_role}, else: :ok
  end

  defp not_last_admin(group, profile_id, key) do
    if key == GroupRole.admin_key() and profile_id in holders(group, key) and
         Access.count_admins(group) <= 1,
       do: {:error, :last_admin},
       else: :ok
  end

  # Who holds the role of their own, not through the parent.
  defp holders(%Group{id: group_id}, key) do
    from(r in GroupMemberRole,
      where: r.group_id == ^group_id and r.role_key == ^key and not r.inherited,
      select: r.profile_id
    )
    |> Repo.all()
  end

  defp push(poll, group, profile_ids, change, role) do
    fn -> Notifications.deliver_role_change(poll, group, profile_ids, change, role) end
  end

  ## Form values

  defp attr(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Map.fetch!(@keys, key)))

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _not_an_id -> nil
    end
  end

  defp to_id(_id), do: nil

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
