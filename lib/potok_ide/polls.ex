defmodule PotokIde.Polls do
  @moduledoc """
  Voting in groups. A poll lives on the server with its rules, so that a card in
  the chat, the overview and an app all read one record and none of them can
  show more than `PotokIde.Polls.Rules` allows. See `PotokIde.Polls.Poll` for
  what its settings promise.

  A poll is carried by a message in the chat when it was announced there, and
  the two go together: deleting the message deletes the poll. Everything that
  reaches a viewer goes through `views/4`.

  Votes take a lock on their poll, so a vote and the closing of a poll cannot
  race and the counts need no care beyond that. They are told over the group's
  own topic `group_polls:<id>`, to the pages that show polls, with the counts of
  the answers, so that a vote costs an open page no query. An open secret poll
  sends only how many voted. What changes the card in any other way goes through
  `Social.refresh_value/1`.
  """

  import Ecto.Query

  alias Phoenix.PubSub
  alias PotokIde.Accounts.Account
  alias PotokIde.History
  alias PotokIde.PlainText
  alias PotokIde.Polls.{Effects, Notifications, Outcome, Poll, PollBallot, PollOption, Rules}
  alias PotokIde.Processes
  alias PotokIde.Processes.ValueProcess
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccountProfile, Group, Identity, Profile, RequestPoll, Value}

  # What someone outside the group may do, enough to hold back a loop.
  @outsider_votes_per_minute 10
  @nudge_interval_seconds 3600
  @page_size 30
  # "Waiting for my vote" is decided by the rules, past what a query can tell,
  # so it looks through this many open polls without paging.
  @waiting_candidates 200

  ## Topics

  @doc "Subscribes to the polls of a group, or with `:public` to every public poll."
  def subscribe(group_id_or_public),
    do: PubSub.subscribe(PotokIde.PubSub, topic(group_id_or_public))

  def unsubscribe(group_id_or_public),
    do: PubSub.unsubscribe(PotokIde.PubSub, topic(group_id_or_public))

  defp topic(:public), do: "public_polls"
  defp topic(group_id), do: "group_polls:#{group_id}"

  defp broadcast(%Poll{} = poll, message) do
    PubSub.broadcast(PotokIde.PubSub, topic(poll.group_id), {:polls, message})
    if poll.is_public, do: PubSub.broadcast(PotokIde.PubSub, topic(:public), {:polls, message})
    :ok
  end

  @doc "Tells open pages that the poll is gone. `Social.delete_value/2` calls it for its poll."
  def broadcast_deleted(%Poll{} = poll), do: broadcast(poll, {:deleted, poll.id})

  @doc "Sends the poll to whoever shows it again, after something other than a vote changed."
  def refresh(%Poll{} = poll) do
    Social.refresh_value(poll.value_id)
    broadcast(poll, {:changed, poll.id})
  end

  ## Reading

  @doc "The poll with its answers and group, or nil."
  def get_poll(id) when is_integer(id) do
    Repo.one(from(p in Poll, where: p.id == ^id, preload: [:options, :group, :effect_profile]))
  end

  @doc "Whether the group has a poll at all, for the section in its bar."
  def any?(%Group{id: group_id}) do
    Repo.exists?(from(p in Poll, where: p.group_id == ^group_id))
  end

  @doc "Whether the group has a poll open to non-members."
  def public_polls?(%Group{} = group) do
    Group.guest_preview?(group) and
      Repo.exists?(from(p in Poll, where: p.group_id == ^group.id and p.is_public))
  end

  @doc """
  The page of the overview, newest first, as `%{rows: [...], more?: boolean}`. A
  row has the poll's `:id`, its `:view` and `:group`.

  `scope` is what the viewer looks at: `{:groups, ids}` (its own groups),
  `{:public_of, group_id}` (a public group it is outside of), `:public`, or
  `{:groups_and_public, ids}`. `:status` is `:open`, `:closed` or `:waiting`.

  A guest, nil for both the profile and the account, looks only at the public
  polls of one group (`{:public_of, group_id}`), where an app of that group's
  description shows them, and votes in none.
  """
  def overview(profile, account, scope, opts \\ [])
      when is_struct(profile, Profile) or
             (is_nil(profile) and is_nil(account) and tuple_size(scope) == 2 and
                elem(scope, 0) == :public_of) do
    status = Keyword.get(opts, :status, :open)
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:second) end)
    limit = if status == :waiting, do: @waiting_candidates, else: @page_size

    polls =
      Poll
      |> from(as: :poll)
      |> join(:inner, [p], g in assoc(p, :group), as: :group)
      |> in_scope(scope)
      |> with_status(status, now)
      |> before(Keyword.get(opts, :before_id))
      |> without_my_ballot(status, profile)
      |> order_by([p], desc: p.id)
      |> limit(^(limit + 1))
      |> preload([p, g], [:options, :effect_profile, group: g])
      |> Repo.all()

    {polls, rest} = Enum.split(polls, limit)
    views = views(polls, profile, account, contexts(polls, profile), now)

    rows =
      polls
      |> Enum.map(&%{id: &1.id, view: Map.fetch!(views, &1.id), group: &1.group})
      |> keep_status(status)

    %{rows: rows, more?: status != :waiting and rest != []}
  end

  defp in_scope(query, {:groups, group_ids}), do: where(query, [p], p.group_id in ^group_ids)

  defp in_scope(query, {:public_of, group_id}),
    do: where(query, [p], p.group_id == ^group_id and p.is_public)

  defp in_scope(query, :public), do: where(query, ^public_poll())

  defp in_scope(query, {:groups_and_public, group_ids}) do
    public = public_poll()
    where(query, ^dynamic([p], p.group_id in ^group_ids or ^public))
  end

  # As `Group.guest_preview?/1`: a group that stopped being public keeps its polls.
  defp public_poll do
    dynamic(
      [p, g],
      p.is_public and g.is_public and not g.is_root and not g.is_direct and
        is_nil(g.parent_value_id)
    )
  end

  defp with_status(query, :closed, now) do
    where(
      query,
      [p],
      not is_nil(p.closed_at) or (not is_nil(p.closes_at) and p.closes_at <= ^now)
    )
  end

  defp with_status(query, _open_or_waiting, now) do
    where(query, [p], is_nil(p.closed_at) and (is_nil(p.closes_at) or p.closes_at > ^now))
  end

  defp before(query, nil), do: query
  defp before(query, id), do: where(query, [p], p.id < ^id)

  # One holder's ballot through a shared profile leaves it to the others:
  # the view then tells whose it is.
  defp without_my_ballot(query, :waiting, %Profile{id: profile_id}) do
    from([p] in query,
      left_join: b in PollBallot,
      on: b.poll_id == p.id and b.profile_id == ^profile_id and not b.by_holder,
      where: is_nil(b.id)
    )
  end

  defp without_my_ballot(query, _status, _profile), do: query

  defp keep_status(rows, :waiting),
    do: Enum.filter(rows, &(&1.view.can_vote? and not &1.view.voted?))

  defp keep_status(rows, _status), do: rows

  defp contexts(polls, profile) do
    groups = polls |> Enum.map(& &1.group) |> Enum.uniq_by(& &1.id)
    accesses = Access.for_profile_in_groups(profile, groups)

    Map.new(groups, &{&1.id, {&1, Map.fetch!(accesses, &1.id)}})
  end

  @doc """
  What `profile` sees of each poll, as `%{poll_id => %View{}}`. The polls need
  their answers; `contexts` is `%{group_id => {group, access}}`.
  """
  def views(polls, profile, account, contexts, now \\ DateTime.utc_now(:second))

  # A guest has no ballot, and `Rules.view/7` shows it what anyone outside sees.
  def views(polls, nil, nil, contexts, now) do
    Map.new(polls, fn %Poll{} = poll ->
      {group, access} = Map.fetch!(contexts, poll.group_id)

      {poll.id, Rules.view(poll, group, access, nil, nil, nil, now)}
    end)
  end

  def views(polls, %Profile{} = profile, %Account{} = account, contexts, now) do
    shared? = Identity.really_shared?(profile)
    ballots = ballots_of_viewer(polls, profile, account.id)

    Map.new(polls, fn %Poll{} = poll ->
      {group, access} = Map.fetch!(contexts, poll.group_id)
      voter = voter(poll, shared?, profile, account)

      {own, other} =
        ballots
        |> Map.get(poll.id, [])
        |> Enum.filter(&of_voter?(&1, profile, voter))
        |> split_ballots(profile)

      {poll.id, Rules.view(poll, group, access, profile, own, other, now, Identity.kind(shared?))}
    end)
  end

  # Every ballot that could be the viewer's in any poll: each poll then keeps
  # those its own rule makes the viewer's (`of_voter?/3`).
  defp ballots_of_viewer(polls, %Profile{id: profile_id}, account_id) do
    case for %Poll{id: id, voters_count: count} <- polls, count > 0, do: id do
      [] ->
        %{}

      poll_ids ->
        from(b in PollBallot,
          where:
            b.poll_id in ^poll_ids and
              (b.profile_id == ^profile_id or b.account_id == ^account_id)
        )
        |> Repo.all()
        |> Enum.group_by(& &1.poll_id)
    end
  end

  # Who the vote of `profile` counts as in the poll (`Identity.voter/5`).
  defp voter(%Poll{} = poll, shared?, %Profile{} = profile, %Account{id: account_id}),
    do: Identity.voter(shared?, profile, account_id, poll.unique_votes, poll.shared_votes)

  # The ballots that stand in the way of `voter`'s vote, or are its own: those
  # of its account, whichever profile gave them, and its profile's own. A
  # shared profile that votes once has only its own, and one holder of it only
  # those of their account, not the other holders'.
  defp of_voter(query, %Profile{id: profile_id}, {:account, account_id}),
    do: where(query, [b], b.profile_id == ^profile_id or b.account_id == ^account_id)

  defp of_voter(query, %Profile{id: profile_id}, {:profile, _id}),
    do: where(query, [b], b.profile_id == ^profile_id)

  defp of_voter(query, %Profile{}, {:each_holder, account_id}),
    do: where(query, [b], b.account_id == ^account_id)

  defp of_voter(query, %Profile{id: profile_id}, :excluded),
    do: where(query, [b], b.profile_id == ^profile_id)

  defp of_voter?(%PollBallot{} = b, %Profile{id: profile_id}, {:account, account_id}),
    do: b.profile_id == profile_id or b.account_id == account_id

  defp of_voter?(%PollBallot{} = b, %Profile{id: profile_id}, {:profile, _id}),
    do: b.profile_id == profile_id

  defp of_voter?(%PollBallot{} = b, %Profile{}, {:each_holder, account_id}),
    do: b.account_id == account_id

  defp of_voter?(%PollBallot{} = b, %Profile{id: profile_id}, :excluded),
    do: b.profile_id == profile_id

  defp split_ballots(ballots, %Profile{id: profile_id}) do
    own = Enum.find(ballots, &(&1.profile_id == profile_id))
    {own, Enum.find(ballots, &(&1.profile_id != profile_id))}
  end

  @doc """
  What `profile` sees of one poll, with its answers and group loaded; nil for
  both the profile and the account is a guest.
  """
  def view_of(%Poll{group: %Group{} = group} = poll, profile, account)
      when is_struct(profile, Profile) or (is_nil(profile) and is_nil(account)) do
    access = Access.for_profile(profile, group)

    [poll]
    |> views(profile, account, %{group.id => {group, access}})
    |> Map.fetch!(poll.id)
  end

  @doc """
  Puts on each value that carries a poll what `profile` sees of it. This is the
  one place that does: a value read for someone else, or a broadcast, carries
  none. Costs nothing when no value has a poll, and always reads the poll afresh,
  as a broadcast value is as old as the vote before it.
  """
  def put_views(values, %Group{} = group, %Access{} = access, %Profile{} = profile, account) do
    case for %Value{poll: %Poll{id: id}} <- values, do: id do
      [] ->
        values

      poll_ids ->
        polls =
          Repo.all(
            from(p in Poll, where: p.id in ^poll_ids, preload: [:options, :effect_profile])
          )

        views = views(polls, profile, account, %{group.id => {group, access}})

        Enum.map(values, fn
          %Value{poll: %Poll{id: id}} = value -> %{value | poll_view: Map.get(views, id)}
          value -> value
        end)
    end
  end

  ## Writing

  @doc "The params an empty form starts from: rows for the fewest answers a poll can have."
  def blank_attrs do
    %{
      "options" => Map.new(0..(Poll.min_options() - 1), &{Integer.to_string(&1), %{"text" => ""}})
    }
  end

  @doc "The changeset of the poll's form; a poll with votes changes only its schedule."
  def change_poll(%Poll{} = poll, attrs, time_zone) do
    if poll.voters_count > 0,
      do: Poll.schedule_changeset(poll, attrs, time_zone),
      else: Poll.changeset(poll, attrs, time_zone)
  end

  @doc """
  The form's changeset, with what a decision changes as it would be saved for
  `access`: its fixed answers, and what it names that is wrong as errors.
  """
  def change_poll(%Poll{} = poll, attrs, time_zone, %Access{} = access, %Group{} = group) do
    if poll.voters_count > 0 do
      change_poll(poll, attrs, time_zone)
    else
      attrs = Effects.keep_current(attrs, poll)

      case effect_changeset(poll, attrs, time_zone, access, group, nil) do
        {:ok, changeset} -> changeset
        {:error, %Ecto.Changeset{} = changeset} -> changeset
        {:error, _not_permitted} -> change_poll(poll, attrs, time_zone)
      end
    end
  end

  @doc """
  Starts a poll in `group`; the deadline is read in `time_zone`. With
  `announce: true` (the default) it is posted in the group's chat when the
  creator may post there, and members get a push.

  A decision that changes roles (`Effects.normalize/4`) needs one of
  `proposers` (accesses, by default the creator's) to be allowed it;
  `process_instance_id` names the run of a process that waits for the poll.
  """
  def create_poll(%Profile{} = creator, %Group{} = group, attrs, time_zone, opts \\ []) do
    access = Access.for_profile(creator, group)

    if Rules.can_create?(access, group) do
      attrs = only_if_published(attrs, access, group)

      poll = %Poll{
        group_id: group.id,
        creator_id: creator.id,
        process_instance_id: Keyword.get(opts, :process_instance_id)
      }

      with {:ok, changeset} <-
             effect_changeset(poll, attrs, time_zone, access, group, opts[:proposers]) do
        insert_poll(changeset, creator, group, access, opts)
      end
    else
      {:error, :not_permitted}
    end
  end

  # The poll's changeset with what its decision changes, checked by
  # `Effects`, and the answers that go with it.
  defp effect_changeset(%Poll{} = poll, attrs, time_zone, access, group, proposers) do
    case Effects.normalize(attrs, access, group, proposers) do
      {:ok, chosen, answers} ->
        {:ok,
         poll
         |> change_poll(Effects.with_answers(attrs, answers), time_zone)
         |> Poll.put_effect(chosen, Effects.marks(answers))}

      # The decision as far as it goes, so that the form keeps asking for it.
      {:error, {field, message}} ->
        kind = Effects.kind(attrs)

        changeset =
          poll
          |> change_poll(
            Effects.with_answers(attrs, Effects.fixed_answers(kind, attrs)),
            time_zone
          )
          |> Ecto.Changeset.put_change(:effect, kind)
          |> Ecto.Changeset.add_error(field, message)

        {:error, %{changeset | action: :validate}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_poll(changeset, creator, group, access, opts) do
    case Repo.insert(changeset) do
      {:ok, poll} ->
        poll =
          if Keyword.get(opts, :announce, true) and Access.can?(access, :post_values),
            do: announce(creator, group, poll),
            else: poll

        broadcast(poll, {:changed, poll.id})
        {:ok, %{poll | group: group}}

      error ->
        error
    end
  end

  @doc """
  Starts a poll for the run of a drawn process (`PotokIde.Processes.Engine`),
  in the caller's transaction, by the process's profile: `process_instance_id`
  names the run that waits for it, and `proposers` who may put its decision
  to a vote. Returns `{:ok, poll, announce}`: its message goes out, and pages
  hear of it, once the caller commits and calls `announce`.
  """
  def create_poll_for_process(%Profile{} = process, %Group{} = group, attrs, time_zone, opts) do
    access = Access.for_profile(process, group)

    if Rules.can_create?(access, group) do
      poll = %Poll{
        group_id: group.id,
        creator_id: process.id,
        process_instance_id: Keyword.fetch!(opts, :process_instance_id)
      }

      with {:ok, changeset} <-
             effect_changeset(poll, attrs, time_zone, access, group, opts[:proposers]),
           {:ok, poll} <- Repo.insert(changeset) do
        {:ok, poll,
         fn ->
           poll =
             if Access.can?(access, :post_values),
               do: announce(process, group, poll),
               else: poll

           broadcast(poll, {:changed, poll.id})
         end}
      end
    else
      {:error, :not_permitted}
    end
  end

  @doc """
  Starts the poll a request raises (`PotokIde.Social.GroupRequests`), in the
  caller's transaction, in the name of `requester`, whose request it is: the
  group's rule puts it to a vote, not the requester's rights. `attrs` name
  the decision (`effect`, `:admit` or `:grant`, with `role_key` and
  `profile_id`), its `question` and `description`, and `rule`, the
  `PotokIde.Social.RequestPoll` it goes by. Returns `{:ok, poll, announce}`,
  as `create_poll_for_process/5` does.
  """
  def create_poll_for_request(
        %Profile{} = requester,
        %Group{} = group,
        %{effect: effect, rule: %RequestPoll{} = rule} = attrs
      ) do
    access = Access.for_profile(requester, group)

    closes_local =
      DateTime.utc_now(:second)
      |> DateTime.add(rule.hours, :hour)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()

    form = %{
      "question" => String.slice(attrs.question, 0, Poll.max_question()),
      "description" => Map.get(attrs, :description) || "",
      "majority" => to_string(rule.majority),
      "quorum_percent" => to_string(rule.quorum_percent),
      "secret" => to_string(rule.secret),
      "unique_votes" => to_string(rule.unique_votes),
      "shared_votes" => to_string(rule.shared_votes),
      "closes_local" => closes_local,
      "effect" => to_string(effect),
      "effect_role_key" => Map.get(attrs, :role_key),
      "effect_profile_id" => attrs.profile_id
    }

    poll = %Poll{group_id: group.id, creator_id: requester.id, from_request: true}

    with {:ok, changeset} <- effect_changeset(poll, form, "Etc/UTC", access, group, :request),
         {:ok, poll} <- Repo.insert(changeset) do
      {:ok, poll,
       fn ->
         poll = announce(requester, group, poll, by_rule: true)
         broadcast(poll, {:changed, poll.id})
       end}
    end
  end

  # Only `publish_polls` opens a poll to non-members. Without it the setting is
  # dropped before the changeset, as it takes other settings with it.
  defp only_if_published(attrs, access, group) do
    if Rules.can_publish?(access, group),
      do: attrs,
      else: Map.drop(attrs, [:is_public, "is_public"])
  end

  defp announce(creator, group, poll, opts \\ []) do
    link = fn repo, value ->
      {count, _} =
        repo.update_all(from(p in Poll, where: p.id == ^poll.id), set: [value_id: value.id])

      {:ok, count}
    end

    case Social.post_announcement(
           creator,
           group,
           announcement_content(poll),
           link,
           Notifications.created(creator, group, poll),
           "group poll",
           opts
         ) do
      {:ok, value} -> %{poll | value_id: value.id}
      {:error, _reason} -> poll
    end
  end

  # The value's text, for reply quotes and excerpts; the chat shows the card in
  # its place.
  defp announcement_content(%Poll{question: question}) do
    "📊 **#{PlainText.escape_markdown(question)}**"
  end

  @doc """
  Changes the poll. Until the first vote everything can change; after it only
  the deadline and the reminder, as voters saw the rest. The deadline is read in
  `time_zone`.
  """
  def update_poll(%Profile{} = actor, %Poll{} = poll, attrs, time_zone) do
    with_locked_poll(poll, actor, fn locked, group, access ->
      cond do
        not Rules.manage?(locked, access, actor) ->
          {:error, :not_permitted}

        not Poll.open?(locked, DateTime.utc_now(:second)) ->
          {:error, :closed}

        locked.voters_count > 0 ->
          locked
          |> Repo.preload(:options)
          |> change_poll(attrs, time_zone)
          |> Repo.update()

        # What a decision changes is set by those who may put it to a vote.
        locked.effect && not Effects.may_propose?(access, group, locked.effect) ->
          {:error, :not_permitted}

        true ->
          attrs = attrs |> only_if_published(access, group) |> Effects.keep_current(locked)

          before = Repo.preload(locked, :options)

          with {:ok, changeset} <-
                 effect_changeset(before, attrs, time_zone, access, group, nil),
               {:ok, updated} <- Repo.update(changeset) do
            if Enum.map(updated.options, & &1.text) != Enum.map(before.options, & &1.text),
              do: record_options(before, before.options)

            {:ok, updated}
          end
      end
    end)
    |> case do
      {:ok, updated} ->
        rewrite_announcement(poll, updated)
        refresh(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  defp rewrite_announcement(%Poll{question: same}, %Poll{question: same}), do: :ok
  defp rewrite_announcement(_old, %Poll{value_id: nil}), do: :ok

  defp rewrite_announcement(_old, %Poll{value_id: value_id} = updated) do
    # The history has the poll's change; nobody edited a message.
    {:ok, _} =
      History.off(fn ->
        from(v in Value, where: v.id == ^value_id)
        |> Repo.update_all(set: [content: announcement_content(updated)])
      end)

    :ok
  end

  @doc """
  Records the vote of `profile`, of `account`, for `option_ids`, and returns the
  poll. One account gives one vote, whichever of its profiles it uses, and a
  shared profile votes as the poll says (`Identity.voter/5`); a poll that
  allows it takes a new vote in place of the old one.
  """
  def vote(%Profile{} = profile, %Account{} = account, %Poll{id: poll_id}, option_ids)
      when is_list(option_ids) do
    now = DateTime.utc_now(:second)
    shared? = Identity.really_shared?(profile)

    Repo.transaction(fn ->
      poll = Repo.one(locked_poll(poll_id)) || Repo.rollback(:not_found)
      group = Repo.get!(Group, poll.group_id)
      access = Access.for_profile(profile, group)

      case Rules.vote_block(poll, group, access, profile, now, Identity.kind(shared?)) do
        nil -> :ok
        reason -> Repo.rollback(reason)
      end

      if not access.member? and voted_a_lot?(profile, group, now),
        do: Repo.rollback(:rate_limited)

      option_ids = checked_choice(poll, option_ids)
      voter = voter(poll, shared?, profile, account)

      ballots =
        from(b in PollBallot, where: b.poll_id == ^poll.id)
        |> of_voter(profile, voter)
        |> Repo.all()

      case split_ballots(ballots, profile) do
        {nil, nil} -> first_vote(poll, profile, voter, option_ids, now)
        {nil, _other} -> Repo.rollback(:voted_with_other_profile)
        {ballot, _} -> change_vote(poll, ballot, option_ids, now)
      end
    end)
    |> case do
      {:ok, {poll, counts}} ->
        broadcast_tally(poll, profile, counts)
        {:ok, poll}

      {:ok, %Poll{} = poll} ->
        {:ok, poll}

      {:error, _reason} = error ->
        error
    end
  end

  # Nothing that can be read back may tie a voter to an answer in a secret poll.
  defp first_vote(%Poll{} = poll, profile, voter, option_ids, now) do
    Repo.insert!(%PollBallot{
      poll_id: poll.id,
      profile_id: profile.id,
      account_id: ballot_account_id(voter),
      by_holder: match?({:each_holder, _}, voter),
      option_ids: if(poll.secret, do: [], else: option_ids),
      inserted_at: now
    })

    {1, [voters_count]} =
      from(p in Poll, where: p.id == ^poll.id, select: p.voters_count)
      |> Repo.update_all(inc: [voters_count: 1])

    {%{poll | voters_count: voters_count}, count_votes(poll, option_ids, [])}
  end

  defp change_vote(%Poll{allow_change: false}, _ballot, _option_ids, _now),
    do: Repo.rollback(:already_voted)

  defp change_vote(%Poll{} = poll, %PollBallot{option_ids: old} = ballot, option_ids, now) do
    if Enum.sort(old) == Enum.sort(option_ids) do
      poll
    else
      ballot
      |> Ecto.Changeset.change(option_ids: option_ids, changed_at: now)
      |> Repo.update!()

      {poll, count_votes(poll, option_ids -- old, old -- option_ids)}
    end
  end

  # One statement over every answer of the poll, so that the row versions it
  # leaves behind do not single out the chosen ones.
  defp count_votes(%Poll{id: poll_id}, added, removed) do
    {_count, rows} =
      from(o in PollOption,
        where: o.poll_id == ^poll_id,
        select: {o.id, o.votes_count},
        update: [
          set: [
            votes_count:
              fragment(
                "? + (CASE WHEN ? = ANY(?) THEN 1 ELSE 0 END) - (CASE WHEN ? = ANY(?) THEN 1 ELSE 0 END)",
                o.votes_count,
                o.id,
                type(^added, {:array, :integer}),
                o.id,
                type(^removed, {:array, :integer})
              )
          ]
        ]
      )
      |> Repo.update_all([])

    Map.new(rows)
  end

  defp broadcast_tally(%Poll{} = poll, %Profile{id: voter_id}, counts) do
    broadcast(
      poll,
      {:tally,
       %{
         poll_id: poll.id,
         value_id: poll.value_id,
         voter_id: voter_id,
         voters_count: poll.voters_count,
         # An open secret poll shows no counts to anyone.
         counts: if(poll.secret, do: nil, else: counts)
       }}
    )
  end

  defp checked_choice(%Poll{} = poll, option_ids) do
    known =
      Repo.all(from(o in PollOption, where: o.poll_id == ^poll.id, select: o.id))

    chosen = Enum.uniq(option_ids)

    if chosen != [] and chosen -- known == [] and fits_kind?(poll, chosen),
      do: chosen,
      else: Repo.rollback(:invalid_choice)
  end

  defp fits_kind?(%Poll{kind: :single}, chosen), do: length(chosen) == 1
  defp fits_kind?(%Poll{max_choices: nil}, _chosen), do: true
  defp fits_kind?(%Poll{max_choices: max}, chosen), do: length(chosen) <= max

  defp voted_a_lot?(%Profile{id: profile_id}, %Group{id: group_id}, now) do
    since = DateTime.add(now, -60, :second)

    from(b in PollBallot,
      join: p in Poll,
      on: p.id == b.poll_id,
      where:
        p.group_id == ^group_id and b.profile_id == ^profile_id and
          (b.inserted_at > ^since or b.changed_at > ^since),
      select: count()
    )
    |> Repo.one()
    |> Kernel.>=(@outsider_votes_per_minute)
  end

  # The account a ballot counts against: none for a profile that several accounts
  # really share and that votes for all of them. Forms answer by the same rule.
  defp ballot_account_id({:account, account_id}), do: account_id
  defp ballot_account_id({:each_holder, account_id}), do: account_id
  defp ballot_account_id({:profile, _profile_id}), do: nil

  @doc """
  Adds an answer of a member to an open poll that allows it. It takes the next
  place, and the same words in any letter case are refused.
  """
  def add_option(%Profile{} = profile, %Poll{} = poll, attrs) do
    kind = Identity.kind(Identity.really_shared?(profile))

    with_locked_poll(poll, profile, fn locked, group, access ->
      locked = Repo.preload(locked, :options)
      now = DateTime.utc_now(:second)
      vote_block = Rules.vote_block(locked, group, access, profile, now, kind)
      view = Rules.view(locked, group, access, profile, nil, nil, now, kind)

      if not is_nil(vote_block) or not view.can_add_option? do
        {:error, :not_permitted}
      else
        # Nobody sees who added an answer, and the history does not say.
        with {:ok, _poll} = added <- insert_option(locked, profile, attrs) do
          History.within([actor: nil, via: :member_option], fn ->
            record_options(locked, locked.options)
          end)

          added
        end
      end
    end)
    |> refreshed()
  end

  # In an election a member stands for themselves, under their own name.
  defp insert_option(%Poll{effect: :elect} = poll, profile, _attrs) do
    with {:ok, candidate} <- Effects.candidate(poll, profile) do
      %PollOption{}
      |> PollOption.text_changeset(%{text: candidate.text})
      |> Ecto.Changeset.put_change(:profile_id, candidate.profile_id)
      |> put_option_place(poll, profile)
      |> Repo.insert()
      |> with_poll(poll)
    end
  end

  defp insert_option(%Poll{} = poll, profile, attrs) do
    changeset = PollOption.text_changeset(%PollOption{}, attrs)
    text = changeset |> Ecto.Changeset.get_field(:text) |> PollOption.normalize()

    if Enum.any?(poll.options, &(PollOption.normalize(&1.text) == text)) do
      {:error, :duplicate}
    else
      changeset
      |> put_option_place(poll, profile)
      |> Repo.insert()
      |> with_poll(poll)
    end
  end

  defp put_option_place(changeset, poll, profile) do
    changeset
    |> Ecto.Changeset.put_change(:poll_id, poll.id)
    |> Ecto.Changeset.put_change(:creator_id, profile.id)
    |> Ecto.Changeset.put_change(:position, next_position(poll))
  end

  defp next_position(%Poll{options: options}) do
    (options |> Enum.map(& &1.position) |> Enum.max(fn -> -1 end)) + 1
  end

  @doc """
  Takes out an answer nobody voted for. A poll keeps at least two, and a secret
  one keeps them all, as being refused would tell which answers have votes.
  """
  def delete_option(%Profile{} = actor, %Poll{} = poll, option_id) do
    with_locked_poll(poll, actor, fn locked, _group, access ->
      locked = Repo.preload(locked, :options)
      option = Enum.find(locked.options, &(&1.id == option_id))

      cond do
        not Rules.manage?(locked, access, actor) or locked.secret -> {:error, :not_permitted}
        # A decision's answers are fixed, and its candidates stand for themselves.
        locked.effect -> {:error, :not_permitted}
        is_nil(option) -> {:error, :not_found}
        option.votes_count > 0 -> {:error, :has_votes}
        length(locked.options) <= Poll.min_options() -> {:error, :too_few_options}
        true -> delete_locked_option(locked, option)
      end
    end)
    |> refreshed()
  end

  defp delete_locked_option(%Poll{} = poll, option) do
    with {:ok, _deleted} <- Repo.delete(option) do
      record_options(poll, poll.options)
      {:ok, poll}
    end
  end

  # The answers as they were, for the history: their words, or whose a
  # candidate's is. Never how many chose them.
  defp record_options(%Poll{} = poll, options) do
    History.record!(poll.group_id, "poll", poll.id, :changed,
      fields: ["options"],
      before: %{"options" => Enum.map(options, &option_words/1)}
    )
  end

  defp option_words(%PollOption{profile_id: nil, text: text}), do: %{"text" => text}
  defp option_words(%PollOption{profile_id: profile_id}), do: %{"profile_id" => profile_id}

  defp with_poll({:ok, _option}, poll), do: {:ok, poll}
  defp with_poll(error, _poll), do: error

  defp refreshed({:ok, poll}) do
    refresh(poll)
    {:ok, poll}
  end

  defp refreshed(error), do: error

  @doc """
  Ends the voting now, and works out the decision. A decision that changes
  roles ends at its deadline and not before, as voters counted on it.
  """
  def close_poll(%Profile{} = actor, %Poll{} = poll) do
    now = DateTime.utc_now(:second)

    with_locked_poll(poll, actor, fn locked, group, access ->
      cond do
        not Rules.manage?(locked, access, actor) -> {:error, :not_permitted}
        locked.closed_at -> {:error, :closed}
        locked.effect && Poll.open?(locked, now) -> {:error, :effect_poll}
        true -> {:ok, close_locked(locked, group, now)}
      end
    end)
    |> case do
      {:ok, {closed, announcements}} ->
        Enum.each(announcements, & &1.())
        Notifications.deliver_closed(closed, actor)
        refresh(closed)
        {:ok, closed}

      error ->
        error
    end
  end

  @doc """
  Writes the end of a poll whose row the caller has locked. The right to vote is
  counted here, so that a later change of members leaves the decision as it was,
  and what the decision changes is carried out (`Effects.apply_locked/4`).
  Returns `{poll, announcements}`: run them once the transaction commits.
  """
  def close_locked(%Poll{} = poll, %Group{} = group, %DateTime{} = closed_at) do
    options = Repo.all(from(o in PollOption, where: o.poll_id == ^poll.id))
    eligible = eligible_count(poll, group)
    {outcome, winner_id} = Outcome.decide(poll, options, poll.voters_count, eligible || 0)
    winner = Enum.find(options, &(&1.id == winner_id))
    # Whoever or whatever ended the voting, what comes of it is the decision's.
    {effect_status, announcements} =
      History.within([actor: nil, poll: poll.id], fn ->
        Effects.apply_locked(poll, group, outcome, winner)
      end)

    announcements = announcements ++ wake_process(poll, closed_at)

    closed =
      poll
      |> Ecto.Changeset.change(
        closed_at: closed_at,
        remind_at: nil,
        eligible_count: eligible,
        outcome: outcome,
        winner_option_id: winner_id,
        effect_status: effect_status
      )
      |> Repo.update!()

    {closed, announcements}
  end

  # The run of a process that waits for the poll goes on.
  defp wake_process(%Poll{process_instance_id: nil}, _closed_at), do: []

  defp wake_process(%Poll{process_instance_id: id}, closed_at) do
    {count, _rows} =
      from(i in ValueProcess, where: i.id == ^id and i.status == :waiting)
      |> Repo.update_all(set: [wake_at: closed_at])

    if count > 0, do: [&Processes.Scheduler.nudge/0], else: []
  end

  @doc """
  Takes votes again and forgets the decision. A deadline that has passed goes
  with it. A secret poll stays closed: the difference between two closings,
  next to the list of new voters, would give away what they chose. So does a
  decision that changes roles: what it decided is done.
  """
  def reopen_poll(%Profile{} = actor, %Poll{} = poll) do
    now = DateTime.utc_now(:second)

    with_locked_poll(poll, actor, fn locked, _group, access ->
      cond do
        not Rules.manage?(locked, access, actor) -> {:error, :not_permitted}
        locked.secret -> {:error, :secret}
        locked.effect -> {:error, :effect_poll}
        Poll.open?(locked, now) -> {:ok, locked}
        true -> {:ok, reopen_locked(locked, now)}
      end
    end)
    |> refreshed()
  end

  defp reopen_locked(%Poll{} = poll, now) do
    deadline_passed? = poll.closes_at && DateTime.compare(poll.closes_at, now) != :gt

    poll
    |> Ecto.Changeset.change(
      closed_at: nil,
      closes_at: if(deadline_passed?, do: nil, else: poll.closes_at),
      eligible_count: nil,
      outcome: nil,
      winner_option_id: nil
    )
    |> Repo.update!()
  end

  @doc "Reminds those who may vote and have not, at most once an hour."
  def nudge(%Profile{} = actor, %Poll{} = poll) do
    now = DateTime.utc_now(:second)

    with_locked_poll(poll, actor, fn locked, group, access ->
      cond do
        not Rules.manage?(locked, access, actor) ->
          {:error, :not_permitted}

        not Poll.open?(locked, now) ->
          {:error, :closed}

        nudged_lately?(locked, now) ->
          {:error, :too_soon}

        true ->
          {:ok, {locked |> Ecto.Changeset.change(last_nudged_at: now) |> Repo.update!(), group}}
      end
    end)
    |> case do
      {:ok, {nudged, group}} ->
        Notifications.deliver_reminder(nudged, group)
        {:ok, nudged}

      error ->
        error
    end
  end

  defp nudged_lately?(%Poll{last_nudged_at: nil}, _now), do: false

  defp nudged_lately?(%Poll{last_nudged_at: at}, now),
    do: DateTime.diff(now, at) < @nudge_interval_seconds

  @doc """
  Deletes the poll with all its votes, and the message that carries it. A
  decision that changes roles stays once it has a vote: it is the record of
  what the group decided (`decision?/1`).
  """
  def delete_poll(%Profile{} = actor, %Poll{} = poll) do
    group = Repo.get!(Group, poll.group_id)

    cond do
      decision?(Repo.reload(poll) || poll) ->
        {:error, :decision}

      Rules.manage?(poll, Access.for_profile(actor, group), actor) ->
        delete_poll_and_value(poll, actor)

      true ->
        {:error, :not_permitted}
    end
  end

  @doc """
  Whether the poll is a decision that changes roles and has a vote, or ended,
  or one a request raised, which waits on it: neither it nor its message can
  be deleted then.
  """
  def decision?(%Poll{from_request: true}), do: true
  def decision?(%Poll{effect: nil}), do: false
  def decision?(%Poll{} = poll), do: poll.voters_count > 0 or not is_nil(poll.closed_at)

  defp delete_poll_and_value(%Poll{} = poll, actor) do
    case poll.value_id && Repo.get(Value, poll.value_id) do
      %Value{} = value ->
        # Takes the poll with it, and tells open pages.
        Social.remove_value(value, actor: actor)
        {:ok, poll}

      _no_value ->
        {:ok, _deleted} = History.delete(poll, actor: actor)
        broadcast_deleted(poll)
        {:ok, poll}
    end
  end

  defp with_locked_poll(%Poll{id: poll_id}, %Profile{} = profile, fun) do
    History.transaction([actor: profile], fn ->
      poll = Repo.one(locked_poll(poll_id)) || Repo.rollback(:not_found)
      group = Repo.get!(Group, poll.group_id)

      case fun.(poll, group, Access.for_profile(profile, group)) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp locked_poll(poll_id), do: from(p in Poll, where: p.id == ^poll_id, lock: "FOR UPDATE")

  ## Who may vote

  @doc "The members who may vote in the poll, as far as their roles go."
  def eligible_profile_ids(%Poll{} = poll, %Group{} = group) do
    group
    |> Access.for_members()
    |> Enum.filter(fn {_profile_id, access} ->
      Access.can?(access, :vote_polls) and
        Enum.any?(poll.voter_role_keys, &(&1 in access.role_keys))
    end)
    |> Enum.map(fn {profile_id, _access} -> profile_id end)
  end

  @doc """
  The members who may vote in the poll, by their roles and by the kinds of
  profile it takes, each with what its vote counts as
  (`Identity.counted_voters/5`): `[{profile_id, counted}]`.
  """
  def voting_profiles(%Poll{} = poll, %Group{} = group) do
    profile_ids = eligible_profile_ids(poll, group)

    # One row per holder; a profile no account holds counts on its own, so
    # its `sharing` does not matter.
    holders =
      from(ap in AccountProfile,
        join: p in Profile,
        on: p.id == ap.profile_id,
        where: ap.profile_id in ^profile_ids,
        select: {ap.profile_id, {ap.account_id, p.sharing}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for profile_id <- profile_ids,
        rows = Map.get(holders, profile_id, []),
        counted =
          Identity.counted_voters(
            profile_id,
            rows |> List.first({nil, :unique}) |> elem(1),
            Enum.map(rows, &elem(&1, 0)),
            poll.unique_votes,
            poll.shared_votes
          ),
        counted != [],
        do: {profile_id, counted}
  end

  @doc """
  How many may vote: people, not profiles, as one account votes once, and a
  shared profile as the poll says. nil for a public poll, where anyone may.
  """
  def eligible_count(%Poll{is_public: true}, %Group{}), do: nil

  def eligible_count(%Poll{} = poll, %Group{} = group) do
    poll
    |> voting_profiles(group)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.uniq()
    |> length()
  end
end
