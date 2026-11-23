defmodule PotokIde.Social.GroupRequests do
  @moduledoc """
  Requests for roles, on joining a group and from its members, and how they
  are decided.

  How a role is had is the statute's (`GroupRole.request_mode`), and how a
  request to join is decided the group's (`Group.join_mode`): nobody fits
  either to the case. Whoever asks reads the rule before sending, picks the
  roles it allows to ask for and may say why (`note`).

  - `approve`: whoever manages requests (an admin, or a role with
    `manage_join_requests`) gives it or refuses it, and may say why.
  - `choose`: the same, or they put it to a vote instead.
  - `vote`: every request raises a vote at once, which nobody stands
    before.

  A vote goes as its rule says (`PotokIde.Social.RequestPoll`), raised in the
  name of whoever asked, as the request is theirs, by the group's rule, not
  by their rights (`PotokIde.Polls.create_poll_for_request/3`). Admission is
  carried out by the poll's `admit` decision, a role by `grant`, as the poll
  closes (`PotokIde.Polls.Effects`).

  Admin is given on request only by an admin, and where the group elects its
  admins only by a vote (`mode/2`). Whoever was refused, or not carried by a
  vote, waits seven days before asking the same again, and nobody sends more
  than a few requests an hour (`RateLimit`), as each vote is a message to
  the whole group.

  Admission takes along the roles asked for: those given are given in the
  same transaction, those to be voted on get their polls, and those left for
  later wait as the new member's request for roles (`GroupRoleRequest`).
  What became of each part stays as a `GroupRequestDecision`, the trace of
  who decided what and why, which the one who asked reads too.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query

  alias PotokIde.Polls
  alias PotokIde.Polls.{Effects, Poll}
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    Group,
    GroupJoinRequest,
    GroupRequestDecision,
    GroupRole,
    GroupRoleRequest,
    Notifications,
    Profile
  }

  @wait_days 7

  def wait_days, do: @wait_days

  ## The rules

  @doc """
  How `role` is had in `group`: as the statute says, but Admin only by a vote
  where the group elects its admins.
  """
  def mode(%GroupRole{key: "admin", request_mode: mode}, %Group{elects_admins: true})
      when mode in [:approve, :choose],
      do: :vote

  def mode(%GroupRole{request_mode: mode}, %Group{}), do: mode

  @doc "Whether requests are taken in `group` at all: not at the root, in a direct conversation or a thread."
  def group_allowed?(%Group{} = group), do: Effects.group_allowed?(group)

  @doc """
  Whether the holder of `access` may ask to join `group`, as far as the
  access tells: someone outside a public group, not blocked there. Whether
  they are already invited, which also stops them, takes a query
  (`Social.may_ask_to_join/2`).
  """
  def may_ask_to_join?(%Access{} = access, %Group{} = group) do
    group_allowed?(group) and group.is_public and not access.member? and not access.blocked?
  end

  @doc "Whether the holder of `access` decides the requests of `group`."
  def may_decide?(%Access{} = access, %Group{} = group) do
    group_allowed?(group) and access.member? and
      (access.admin? or Access.can?(access, :manage_join_requests))
  end

  @doc "Whether the holder of `access` may give `role` on request, with no vote."
  def may_grant?(%Access{} = access, %Group{} = group, %GroupRole{} = role) do
    may_decide?(access, group) and mode(role, group) in [:approve, :choose] and
      (role.key != GroupRole.admin_key() or access.admin?)
  end

  @doc """
  What the holder of `access` may make of a request for `role` in `group`, in
  the order a form offers it: `:grant`, `:refuse`, `:vote` and `:later`, as
  the rule allows. A role no longer asked for can only be refused, one the
  rule always votes on only goes to a vote.
  """
  def choices(%GroupRole{} = role, %Access{} = access, %Group{} = group) do
    case mode(role, group) do
      :closed ->
        [:refuse]

      :vote ->
        [:vote]

      :approve ->
        if(may_grant?(access, group, role),
          do: [:grant, :refuse, :later],
          else: [:refuse, :later]
        )

      :choose ->
        if(may_grant?(access, group, role),
          do: [:grant, :refuse, :vote, :later],
          else: [:refuse, :vote, :later]
        )
    end
  end

  @doc "What a form picks first of `choices/3`: to wait, unless the rule decides."
  def default_choice(choices) do
    cond do
      :later in choices -> :later
      choices == [:vote] -> :vote
      true -> hd(choices)
    end
  end

  @doc """
  What whoever decides may do with a request to join `group`. Where every
  request goes to a vote, one sent before the group said so is put to a vote
  too, and nothing else.
  """
  def admission_choices(%Group{join_mode: :approve}), do: [:admit, :refuse]
  def admission_choices(%Group{join_mode: :choose}), do: [:admit, :refuse, :vote]
  def admission_choices(%Group{join_mode: :vote}), do: [:vote]

  @doc """
  A request of `group`, `{:join, id}` or `{:roles, id}`, with who asked; nil
  when there is none.
  """
  def get_request(%Group{id: group_id}, {:join, id}) when is_integer(id) do
    GroupJoinRequest
    |> Repo.get_by(id: id, group_id: group_id)
    |> then(&(&1 && Repo.preload(&1, :requester)))
  end

  def get_request(%Group{id: group_id}, {:roles, id}) when is_integer(id) do
    GroupRoleRequest
    |> Repo.get_by(id: id, group_id: group_id)
    |> then(&(&1 && Repo.preload(&1, :profile)))
  end

  def get_request(_group, _ref), do: nil

  @doc """
  The roles of `group` the holder of `access` may ask for: those its statute
  lets be asked for, but "everyone" and those it holds already, its own or
  through the parent.
  """
  def requestable_roles(%Access{manifest: nil}, _group), do: []

  def requestable_roles(%Access{manifest: manifest} = access, %Group{} = group) do
    held = if access.member?, do: access.role_keys, else: []

    Enum.filter(manifest.roles, fn role ->
      role.key != GroupRole.everyone_key() and role.key not in held and
        mode(role, group) != :closed
    end)
  end

  ## Asking

  @doc """
  `requester` asks to join `group`, with the roles it would like there
  (`"role_keys"`) and why (`"note"`), both left out if it wants. Where every
  request to join goes to a vote, the vote starts with it. `opts[:account]`
  counts how often its account asks.
  """
  def request_access(%Profile{} = requester, %Group{} = group, attrs, opts \\ []) do
    group = fresh(group)
    access = Access.for_profile(requester, group)

    with :ok <- if(group_allowed?(group), do: :ok, else: {:error, :not_allowed}),
         :ok <- Social.may_ask_to_join(requester, group),
         {:ok, roles} <- asked_roles(attrs, access, group),
         :ok <- not_lately(group, requester.id, [nil | Enum.map(roles, & &1.key)]),
         :ok <- not_too_often(requester, opts) do
      Repo.transaction(fn ->
        request =
          %GroupJoinRequest{}
          |> GroupJoinRequest.changeset(%{
            group_id: group.id,
            requester_id: requester.id,
            note: note(attrs),
            role_keys: Enum.map(roles, & &1.key)
          })
          |> Repo.insert()
          |> ok_or_rollback()

        case group.join_mode do
          :vote -> vote_on_admission(group, requester, request, nil, nil)
          _decided -> {request, []}
        end
      end)
      |> case do
        {:ok, {request, announcements}} ->
          run(announcements)
          Social.broadcast_requests_changed(group, requester)
          {:ok, request}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  `profile`, a member of `group`, asks for roles (`"role_keys"`), saying why
  if it wants (`"note"`). A role that always goes to a vote gets its vote at
  once; the others wait for whoever manages requests, along with any the
  member asked for before.
  """
  def request_roles(%Profile{} = profile, %Group{} = group, attrs, opts \\ []) do
    group = fresh(group)
    access = Access.for_profile(profile, group)

    with :ok <-
           if(group_allowed?(group) and access.member?, do: :ok, else: {:error, :not_permitted}),
         {:ok, roles} <- asked_roles(attrs, access, group),
         :ok <- if(roles == [], do: {:error, :no_roles}, else: :ok),
         :ok <- not_lately(group, profile.id, Enum.map(roles, & &1.key)),
         :ok <- not_in_vote(group, profile.id, roles),
         :ok <- not_too_often(profile, opts) do
      {to_vote, to_decide} = Enum.split_with(roles, &(mode(&1, group) == :vote))
      note = note(attrs)

      Repo.transaction(fn ->
        votes =
          Enum.flat_map(to_vote, fn role ->
            {_decision, announce} = vote_on_role(group, profile, role, note, nil, nil)
            announce
          end)

        wait(group, profile.id, Enum.map(to_decide, & &1.key), note)
        votes
      end)
      |> case do
        {:ok, announcements} ->
          run(announcements)
          Social.broadcast_requests_changed(group, profile)
          {:ok, %{voted: to_vote, waiting: to_decide}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  `profile` takes back what of its request in `group` still waits for whoever
  decides: its request to join (`:join`) or for roles (`:roles`). What went to
  a vote stays: the group decides it now.
  """
  def withdraw(%Profile{} = profile, %Group{} = group, :join) do
    case get_join_request_of(group, profile) do
      nil -> {:error, :request_not_found}
      %GroupJoinRequest{poll_id: poll_id} when not is_nil(poll_id) -> {:error, :in_vote}
      request -> deleted(Repo.delete(request), group, profile)
    end
  end

  def withdraw(%Profile{} = profile, %Group{} = group, :roles) do
    case Repo.get_by(GroupRoleRequest, group_id: group.id, profile_id: profile.id) do
      nil -> {:error, :request_not_found}
      request -> deleted(Repo.delete(request), group, profile)
    end
  end

  defp deleted({:ok, _request}, group, profile) do
    Social.broadcast_requests_changed(group, profile)
    :ok
  end

  defp deleted({:error, reason}, _group, _profile), do: {:error, reason}

  ## Deciding

  @doc """
  `actor` decides a request of `group`: `{:join, id}` or `{:roles, id}`.

  `decision` holds `"admission"` for a request to join (`"admit"`,
  `"refuse"` or, where the rule lets them choose, `"vote"`), `"roles"` with
  what becomes of each role asked for (`"grant"`, `"refuse"`, `"vote"` or
  `"later"`), and the `"reason"` the one who asked reads. A role the rule
  always puts to a vote goes to one whatever it says; one left out waits.
  """
  def decide(%Profile{} = actor, %Group{} = group, {:join, request_id}, decision) do
    group = fresh(group)
    access = Access.for_profile(actor, group)

    with :ok <- if(may_decide?(access, group), do: :ok, else: {:error, :not_permitted}),
         %GroupJoinRequest{} = request <- get_join_request(group, request_id),
         :ok <- if(request.poll_id, do: {:error, :in_vote}, else: :ok),
         {:ok, admission} <- admission(decision, group) do
      reason = reason(decision)

      case admission do
        :refuse -> refuse_admission(actor, group, request, reason)
        :vote -> admission_to_vote(actor, group, request, reason)
        :admit -> admit(actor, access, group, request, decision, reason)
      end
    else
      nil -> {:error, :request_not_found}
      error -> error
    end
  end

  def decide(%Profile{} = actor, %Group{} = group, {:roles, request_id}, decision) do
    group = fresh(group)
    access = Access.for_profile(actor, group)

    with :ok <- if(may_decide?(access, group), do: :ok, else: {:error, :not_permitted}),
         %GroupRoleRequest{} = request <-
           Repo.get_by(GroupRoleRequest, id: request_id, group_id: group.id),
         {:ok, choices} <- role_choices(decision, request.role_keys, access, group) do
      reason = reason(decision)
      profile = Repo.get!(Profile, request.profile_id)

      Repo.transaction(fn ->
        {announcements, parts, later} =
          carry_roles(group, profile, choices, actor, reason, request.note)

        case later do
          [] ->
            Repo.delete_all(from(r in GroupRoleRequest, where: r.id == ^request.id))

          keys ->
            Repo.update_all(from(r in GroupRoleRequest, where: r.id == ^request.id),
              set: [role_keys: keys, updated_at: DateTime.utc_now(:second)]
            )
        end

        {announcements, parts}
      end)
      |> case do
        {:ok, {announcements, parts}} ->
          run(announcements)
          Social.broadcast_requests_changed(group, profile)
          tell(profile, group, Map.put(parts, :url, "/groups/#{group.id}"), reason)
          {:ok, parts}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :request_not_found}
      error -> error
    end
  end

  defp admission(decision, %Group{join_mode: mode}) do
    case {Map.get(decision, "admission"), mode} do
      {"admit", mode} when mode in [:approve, :choose] -> {:ok, :admit}
      {"refuse", mode} when mode in [:approve, :choose] -> {:ok, :refuse}
      {"vote", mode} when mode in [:choose, :vote] -> {:ok, :vote}
      _not_allowed -> {:error, :not_permitted}
    end
  end

  defp refuse_admission(actor, group, request, reason) do
    profile = Repo.get!(Profile, request.requester_id)

    Repo.transaction(fn ->
      Repo.delete_all(from(r in GroupJoinRequest, where: r.id == ^request.id))
      record(group, profile.id, nil, :declined, actor, nil, reason)
    end)
    |> case do
      {:ok, _decision} ->
        Social.broadcast_requests_changed(group, profile)
        tell(profile, group, %{admitted: false}, reason)
        {:ok, %{admitted: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admission_to_vote(actor, group, request, reason) do
    profile = Repo.get!(Profile, request.requester_id)

    Repo.transaction(fn -> vote_on_admission(group, profile, request, actor, reason) end)
    |> case do
      {:ok, {_request, announcements}} ->
        run(announcements)
        Social.broadcast_requests_changed(group, profile)
        tell(profile, group, %{admission_vote: true}, reason)
        {:ok, %{admission_vote: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit(actor, access, group, request, decision, reason) do
    with {:ok, choices} <- role_choices(decision, request.role_keys, access, group) do
      profile = Repo.get!(Profile, request.requester_id)

      Repo.transaction(fn ->
        changes =
          Repo
          |> Social.admit_member(group, request, %{approver_id: actor.id})
          |> ok_or_rollback()

        {announcements, parts, later} =
          carry_roles(group, profile, choices, actor, reason, request.note)

        wait(group, profile.id, later, request.note)
        {changes, announcements, parts}
      end)
      |> case do
        {:ok, {changes, announcements, parts}} ->
          Social.announce_admission(group, profile.id, changes)
          run(announcements)
          parts = Map.merge(parts, %{admitted: true, url: "/groups/#{group.id}"})
          tell(profile, group, parts, reason)
          {:ok, parts}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # What becomes of each role asked for, checked against the rule as it
  # stands now: `[{role, choice}]`. A role gone from the statute is dropped,
  # one no longer asked for can only be refused, and one that always goes to
  # a vote goes to one.
  defp role_choices(decision, keys, access, group) do
    asked = Map.get(decision, "roles") || %{}
    roles = if access.manifest, do: access.manifest.roles, else: []

    keys
    |> Enum.flat_map(fn key ->
      case Enum.find(roles, &(&1.key == key)) do
        nil -> []
        role -> [{role, choice(Map.get(asked, key), role, access, group)}]
      end
    end)
    |> Enum.reduce_while({:ok, []}, fn
      {_role, :not_permitted}, _acc -> {:halt, {:error, :not_permitted}}
      pair, {:ok, acc} -> {:cont, {:ok, [pair | acc]}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp choice(asked, role, access, group) do
    case {mode(role, group), asked} do
      {:vote, _asked} -> :vote
      {:closed, "refuse"} -> :refuse
      {:closed, _asked} -> :refuse
      {_mode, "refuse"} -> :refuse
      {_mode, "grant"} -> if(may_grant?(access, group, role), do: :grant, else: :not_permitted)
      {:choose, "vote"} -> :vote
      {:approve, "vote"} -> :not_permitted
      {_mode, _later} -> :later
    end
  end

  # Carries the choices out in the caller's transaction, for the member
  # `profile`. Returns what to run once it commits, the parts for the push,
  # and the keys left for later.
  defp carry_roles(group, profile, choices, decider, reason, note) do
    Enum.reduce(choices, {[], %{granted: [], declined: [], voted: []}, []}, fn
      {role, :grant}, {announcements, parts, later} ->
        {:ok, _row, announce} = Social.put_member_role(Repo, group, profile.id, role.key)
        record(group, profile.id, role.key, :granted, decider, nil, reason)
        {[announce | announcements], add(parts, :granted, role), later}

      {role, :refuse}, {announcements, parts, later} ->
        record(group, profile.id, role.key, :declined, decider, nil, reason)
        {announcements, add(parts, :declined, role), later}

      {role, :vote}, {announcements, parts, later} ->
        {_decision, announce} = vote_on_role(group, profile, role, note, decider, reason)
        {announce ++ announcements, add(parts, :voted, role), later}

      {role, :later}, {announcements, parts, later} ->
        {announcements, parts, later ++ [role.key]}
    end)
  end

  defp add(parts, kind, role), do: Map.update!(parts, kind, &(&1 ++ [role]))

  ## Votes

  # Puts admission to a vote, in the caller's transaction: the poll, linked
  # from the request, and the record. Returns the request and what to run.
  defp vote_on_admission(group, requester, request, decider, reason) do
    {:ok, poll, announce} =
      requester
      |> Polls.create_poll_for_request(group, %{
        effect: :admit,
        profile_id: requester.id,
        question: admission_question(requester),
        description: request.note,
        rule: group.join_poll || %Social.RequestPoll{}
      })
      |> ok_or_rollback()

    Repo.update_all(from(r in GroupJoinRequest, where: r.id == ^request.id),
      set: [poll_id: poll.id, updated_at: DateTime.utc_now(:second)]
    )

    record(group, requester.id, nil, :voted, decider, poll, reason)
    {%{request | poll_id: poll.id}, [announce]}
  end

  defp vote_on_role(group, profile, role, note, decider, reason) do
    {:ok, poll, announce} =
      profile
      |> Polls.create_poll_for_request(group, %{
        effect: :grant,
        role_key: role.key,
        profile_id: profile.id,
        question: role_question(profile, role),
        description: note,
        rule: role.request_poll || %Social.RequestPoll{}
      })
      |> ok_or_rollback()

    {record(group, profile.id, role.key, :voted, decider, poll, reason), [announce]}
  end

  defp admission_question(%Profile{username: name}),
    do: gettext("Do we admit @%{name} to the group?", name: name)

  defp role_question(%Profile{username: name}, %GroupRole{} = role),
    do: gettext("Does @%{name} get the role %{role}?", name: name, role: role_label(role))

  defp role_label(%GroupRole{key: "admin"}), do: gettext("Admin")
  defp role_label(%GroupRole{name: name}), do: name

  @doc """
  Admits whoever asked, as the vote on their request to join carried it, in
  the transaction that closes `poll` (`PotokIde.Polls.Effects`), and takes
  along the roles they asked for: those that go to a vote get theirs, the
  others wait for whoever decides. Returns `{status, announcements}`.
  """
  def admitted_by_vote(%Poll{} = poll, %Group{} = group) do
    request =
      Repo.one(from(r in GroupJoinRequest, where: r.poll_id == ^poll.id, lock: "FOR UPDATE"))

    cond do
      is_nil(request) and Social.member_of_group?(%Profile{id: poll.effect_profile_id}, group) ->
        {:already_member, []}

      is_nil(request) ->
        {:request_gone, []}

      true ->
        case Social.admit_member(Repo, group, request, %{poll_id: poll.id}) do
          {:ok, changes} ->
            profile = Repo.get!(Profile, request.requester_id)
            group = fresh(group)
            manifest = Access.load_effective_manifest(group)
            roles = if manifest, do: manifest.roles, else: []

            {to_vote, later} =
              request.role_keys
              |> Enum.flat_map(fn key -> Enum.filter(roles, &(&1.key == key)) end)
              |> Enum.reject(&(mode(&1, group) == :closed))
              |> Enum.split_with(&(mode(&1, group) == :vote))

            votes =
              Enum.flat_map(to_vote, fn role ->
                {_decision, announce} = vote_on_role(group, profile, role, request.note, nil, nil)
                announce
              end)

            wait(group, profile.id, Enum.map(later, & &1.key), request.note)

            {:applied,
             [fn -> Social.announce_admission(group, profile.id, changes) end | votes] ++
               [fn -> tell_vote(profile, group, :admitted) end]}

          {:error, _reason} ->
            {:already_member, []}
        end
    end
  end

  @doc """
  A vote on a request that did not carry it (`PotokIde.Polls.Effects`): a
  request to join is over, and whoever asked hears of it. Returns what to
  run once the closing commits.
  """
  def not_carried(%Poll{effect: :admit} = poll, %Group{} = group) do
    {_count, requesters} =
      from(r in GroupJoinRequest, where: r.poll_id == ^poll.id, select: r.requester_id)
      |> Repo.delete_all()

    for profile_id <- requesters do
      fn ->
        profile = Repo.get!(Profile, profile_id)
        Social.broadcast_requests_changed(group, profile)
        tell_vote(profile, group, :not_admitted)
      end
    end
  end

  def not_carried(%Poll{effect: :grant} = poll, %Group{} = group) do
    case Access.effective_manifest(group) do
      nil ->
        []

      manifest ->
        case Enum.find(manifest.roles, &(&1.key == poll.effect_role_key)) do
          nil ->
            []

          role ->
            [
              fn ->
                profile = Repo.get(Profile, poll.effect_profile_id)
                if profile, do: tell_vote(profile, group, {:not_granted, role})
              end
            ]
        end
    end
  end

  def not_carried(%Poll{}, _group), do: []

  ## Reading

  @doc """
  What waits in `group`, for whoever decides: the requests to join, with
  their requesters, those in a vote too, and the members' requests for roles.
  """
  def pending(%Group{id: group_id}) do
    %{
      join:
        from(r in GroupJoinRequest,
          where: r.group_id == ^group_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          preload: :requester
        )
        |> Repo.all(),
      roles:
        from(r in GroupRoleRequest,
          where: r.group_id == ^group_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          preload: :profile
        )
        |> Repo.all()
    }
  end

  @doc "The request for roles `profile` has waiting in `group`, or nil."
  def roles_request_of(%Group{id: group_id}, %Profile{id: profile_id}),
    do: Repo.get_by(GroupRoleRequest, group_id: group_id, profile_id: profile_id)

  @doc """
  The roles of `profile` in `group` that a vote decides now: the role keys of
  open polls its requests raised.
  """
  def voting_role_keys(%Group{id: group_id}, %Profile{id: profile_id}) do
    from(p in Poll,
      where:
        p.group_id == ^group_id and p.from_request and p.effect == :grant and
          p.effect_profile_id == ^profile_id and is_nil(p.closed_at),
      select: p.effect_role_key
    )
    |> Repo.all()
  end

  @doc """
  What became of `profile`'s requests, newest first: `%{decision, group,
  decider, poll}` with the role named by its key (nil for admission).
  """
  def decisions_of(%Profile{id: profile_id}, limit \\ 50) do
    from(d in GroupRequestDecision,
      where: d.profile_id == ^profile_id,
      order_by: [desc: d.inserted_at, desc: d.id],
      limit: ^limit,
      preload: [:group, :decider, :poll]
    )
    |> Repo.all()
  end

  @doc "What `decider` decided, newest first, as `decisions_of/2` has it."
  def decided_by(%Profile{id: decider_id}, limit \\ 50) do
    from(d in GroupRequestDecision,
      where: d.decider_id == ^decider_id,
      order_by: [desc: d.inserted_at, desc: d.id],
      limit: ^limit,
      preload: [:group, :profile, :poll]
    )
    |> Repo.all()
  end

  @doc """
  The members' requests for roles in the groups where `profile` decides them,
  newest first, with their group and member.
  """
  def roles_requests_for_decider(%Profile{} = profile) do
    requests =
      from(r in GroupRoleRequest,
        join: m in Social.GroupMembership,
        on: m.group_id == r.group_id and m.profile_id == ^profile.id,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [:group, :profile]
      )
      |> Repo.all()

    groups = requests |> Enum.map(& &1.group) |> Enum.uniq_by(& &1.id)
    accesses = Access.for_profile_in_groups(profile, groups)

    Enum.filter(requests, &may_decide?(Map.fetch!(accesses, &1.group_id), &1.group))
  end

  @doc "The requests to join `profile` has waiting, with their groups."
  def join_requests_of(%Profile{id: profile_id}) do
    from(r in GroupJoinRequest,
      where: r.requester_id == ^profile_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: :group
    )
    |> Repo.all()
  end

  @doc "The requests for roles `profile` has waiting, with their groups."
  def roles_requests_of(%Profile{id: profile_id}) do
    from(r in GroupRoleRequest,
      where: r.profile_id == ^profile_id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: :group
    )
    |> Repo.all()
  end

  ## Helpers

  defp asked_roles(attrs, access, group) do
    keys =
      (Map.get(attrs, "role_keys") || Map.get(attrs, :role_keys) || [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    requestable = requestable_roles(access, group)

    case Enum.reject(keys, fn key -> Enum.any?(requestable, &(&1.key == key)) end) do
      [] -> {:ok, Enum.filter(requestable, &(&1.key in keys))}
      _others -> {:error, :role_not_requestable}
    end
  end

  defp note(attrs) do
    case Map.get(attrs, "note") || Map.get(attrs, :note) do
      note when is_binary(note) ->
        note |> String.trim() |> String.slice(0, GroupJoinRequest.max_note())

      _none ->
        nil
    end
    |> case do
      "" -> nil
      note -> note
    end
  end

  defp reason(decision) do
    case Map.get(decision, "reason") do
      reason when is_binary(reason) ->
        case reason |> String.trim() |> String.slice(0, 300) do
          "" -> nil
          reason -> reason
        end

      _none ->
        nil
    end
  end

  # Whoever was refused, or not carried by a vote, waits before asking the
  # same again: admission is the key nil.
  defp not_lately(%Group{id: group_id}, profile_id, keys) do
    since = DateTime.add(DateTime.utc_now(:second), -@wait_days, :day)
    role_keys = Enum.reject(keys, &is_nil/1)
    admission? = nil in keys

    refused? =
      from(d in GroupRequestDecision,
        left_join: p in Poll,
        on: p.id == d.poll_id,
        where: d.group_id == ^group_id and d.profile_id == ^profile_id,
        where: (is_nil(d.role_key) and ^admission?) or d.role_key in ^role_keys,
        where:
          (d.decision == :declined and d.inserted_at > ^since) or
            (d.decision == :voted and p.closed_at > ^since and
               (is_nil(p.effect_status) or p.effect_status != :applied))
      )
      |> Repo.exists?()

    if refused?, do: {:error, :asked_lately}, else: :ok
  end

  defp not_in_vote(group, profile_id, roles) do
    voting = voting_role_keys(group, %Profile{id: profile_id})

    if Enum.any?(roles, &(&1.key in voting)), do: {:error, :in_vote}, else: :ok
  end

  defp not_too_often(%Profile{id: profile_id}, opts) do
    key =
      case opts[:account] do
        %{id: account_id} -> {:account, account_id}
        _none -> {:profile, profile_id}
      end

    case RateLimit.hit(:group_request, key) do
      :ok -> :ok
      {:error, :rate_limited, _retry_after} -> {:error, :rate_limited}
    end
  end

  # The roles left for whoever decides join what the member asked for before.
  defp wait(_group, _profile_id, [], _note), do: :ok

  defp wait(%Group{id: group_id}, profile_id, keys, note) do
    now = DateTime.utc_now(:second)

    case Repo.one(
           from(r in GroupRoleRequest,
             where: r.group_id == ^group_id and r.profile_id == ^profile_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.insert!(%GroupRoleRequest{
          group_id: group_id,
          profile_id: profile_id,
          role_keys: keys,
          note: note,
          inserted_at: now,
          updated_at: now
        })

      request ->
        Repo.update_all(from(r in GroupRoleRequest, where: r.id == ^request.id),
          set: [
            role_keys: Enum.uniq(request.role_keys ++ keys),
            note: note || request.note,
            updated_at: now
          ]
        )
    end

    :ok
  end

  defp record(group, profile_id, role_key, decision, decider, poll, reason) do
    Repo.insert!(%GroupRequestDecision{
      group_id: group.id,
      profile_id: profile_id,
      role_key: role_key,
      decision: decision,
      decider_id: decider && decider.id,
      poll_id: poll && poll.id,
      reason: reason,
      inserted_at: DateTime.utc_now(:second)
    })
  end

  defp get_join_request(%Group{id: group_id}, request_id) when is_integer(request_id),
    do: Repo.get_by(GroupJoinRequest, id: request_id, group_id: group_id)

  defp get_join_request(_group, _request_id), do: nil

  defp get_join_request_of(%Group{id: group_id}, %Profile{id: profile_id}),
    do: Repo.get_by(GroupJoinRequest, group_id: group_id, requester_id: profile_id)

  # The page may hold the group from before its rules changed.
  defp fresh(%Group{id: id}), do: Repo.get!(Group, id)

  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:ok, value, announce}), do: {:ok, value, announce}
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp run(announcements), do: Enum.each(announcements, & &1.())

  defp tell(profile, group, parts, reason),
    do:
      Social.notify_profile(
        profile,
        Notifications.request_decided(group, parts, reason),
        "request"
      )

  defp tell_vote(profile, group, outcome),
    do:
      Social.notify_profile(profile, Notifications.request_vote_ended(group, outcome), "request")
end
