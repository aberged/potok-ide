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
  alias PotokIde.PlainText
  alias PotokIde.Polls.{Notifications, Outcome, Poll, PollBallot, PollOption, Rules}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccountProfile, Group, Identity, Profile, Value}

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
    Repo.one(from(p in Poll, where: p.id == ^id, preload: [:options, :group]))
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
      |> preload([p, g], [:options, group: g])
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

  defp without_my_ballot(query, :waiting, %Profile{id: profile_id}) do
    from([p] in query,
      left_join: b in PollBallot,
      on: b.poll_id == p.id and b.profile_id == ^profile_id,
      where: is_nil(b.id)
    )
  end

  defp without_my_ballot(query, _status, _profile), do: query

  defp keep_status(rows, :waiting), do: Enum.filter(rows, & &1.view.can_vote?)
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

  def views(polls, %Profile{} = profile, account, contexts, now) do
    account_id = ballot_account_id(profile, account)
    ballots = ballots_of_viewer(polls, profile, account_id)

    Map.new(polls, fn %Poll{} = poll ->
      {group, access} = Map.fetch!(contexts, poll.group_id)
      {own, other} = split_ballots(Map.get(ballots, poll.id, []), profile)

      {poll.id, Rules.view(poll, group, access, profile, own, other, now)}
    end)
  end

  defp ballots_of_viewer(polls, profile, account_id) do
    case for %Poll{id: id, voters_count: count} <- polls, count > 0, do: id do
      [] ->
        %{}

      poll_ids ->
        from(b in PollBallot, where: b.poll_id in ^poll_ids)
        |> of_voter(profile, account_id)
        |> Repo.all()
        |> Enum.group_by(& &1.poll_id)
    end
  end

  defp of_voter(query, %Profile{id: profile_id}, nil),
    do: where(query, [b], b.profile_id == ^profile_id)

  defp of_voter(query, %Profile{id: profile_id}, account_id) do
    where(query, [b], b.profile_id == ^profile_id or b.account_id == ^account_id)
  end

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
        polls = Repo.all(from(p in Poll, where: p.id in ^poll_ids, preload: :options))
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
  Starts a poll in `group`; the deadline is read in `time_zone`. With
  `announce: true` (the default) it is posted in the group's chat when the
  creator may post there, and members get a push.
  """
  def create_poll(%Profile{} = creator, %Group{} = group, attrs, time_zone, opts \\ []) do
    access = Access.for_profile(creator, group)

    if Rules.can_create?(access, group) do
      attrs = only_if_published(attrs, access, group)

      %Poll{group_id: group.id, creator_id: creator.id}
      |> Poll.changeset(attrs, time_zone)
      |> Repo.insert()
      |> case do
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
    else
      {:error, :not_permitted}
    end
  end

  # Only `publish_polls` opens a poll to non-members. Without it the setting is
  # dropped before the changeset, as it takes other settings with it.
  defp only_if_published(attrs, access, group) do
    if Rules.can_publish?(access, group),
      do: attrs,
      else: Map.drop(attrs, [:is_public, "is_public"])
  end

  defp announce(creator, group, poll) do
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
           "group poll"
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

        true ->
          locked
          |> Repo.preload(:options)
          |> change_poll(only_if_published(attrs, access, group), time_zone)
          |> Repo.update()
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
    from(v in Value, where: v.id == ^value_id)
    |> Repo.update_all(set: [content: announcement_content(updated)])

    :ok
  end

  @doc """
  Records the vote of `profile`, of `account`, for `option_ids`, and returns the
  poll. One account gives one vote, whichever of its profiles it uses; a poll
  that allows it takes a new vote in place of the old one.
  """
  def vote(%Profile{} = profile, %Account{} = account, %Poll{id: poll_id}, option_ids)
      when is_list(option_ids) do
    now = DateTime.utc_now(:second)
    account_id = ballot_account_id(profile, account)

    Repo.transaction(fn ->
      poll = Repo.one(locked_poll(poll_id)) || Repo.rollback(:not_found)
      group = Repo.get!(Group, poll.group_id)
      access = Access.for_profile(profile, group)

      case Rules.vote_block(poll, group, access, profile, now) do
        nil -> :ok
        reason -> Repo.rollback(reason)
      end

      if not access.member? and voted_a_lot?(profile, group, now),
        do: Repo.rollback(:rate_limited)

      option_ids = checked_choice(poll, option_ids)

      ballots =
        from(b in PollBallot, where: b.poll_id == ^poll.id)
        |> of_voter(profile, account_id)
        |> Repo.all()

      case split_ballots(ballots, profile) do
        {nil, nil} -> first_vote(poll, profile, account_id, option_ids, now)
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
  defp first_vote(%Poll{} = poll, profile, account_id, option_ids, now) do
    Repo.insert!(%PollBallot{
      poll_id: poll.id,
      profile_id: profile.id,
      account_id: account_id,
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
  # really share, which votes for all of them. Forms answer by the same rule.
  defp ballot_account_id(%Profile{} = profile, %Account{} = account),
    do: Identity.counted_account_id(profile, account)

  @doc """
  Adds an answer of a member to an open poll that allows it. It takes the next
  place, and the same words in any letter case are refused.
  """
  def add_option(%Profile{} = profile, %Poll{} = poll, attrs) do
    with_locked_poll(poll, profile, fn locked, group, access ->
      locked = Repo.preload(locked, :options)
      vote_block = Rules.vote_block(locked, group, access, profile, DateTime.utc_now(:second))
      view = Rules.view(locked, group, access, profile, nil, nil, DateTime.utc_now(:second))
      changeset = PollOption.text_changeset(%PollOption{}, attrs)
      text = changeset |> Ecto.Changeset.get_field(:text) |> PollOption.normalize()

      cond do
        not is_nil(vote_block) or not view.can_add_option? ->
          {:error, :not_permitted}

        Enum.any?(locked.options, &(PollOption.normalize(&1.text) == text)) ->
          {:error, :duplicate}

        true ->
          changeset
          |> Ecto.Changeset.put_change(:poll_id, locked.id)
          |> Ecto.Changeset.put_change(:creator_id, profile.id)
          |> Ecto.Changeset.put_change(:position, next_position(locked))
          |> Repo.insert()
          |> with_poll(locked)
      end
    end)
    |> refreshed()
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
        is_nil(option) -> {:error, :not_found}
        option.votes_count > 0 -> {:error, :has_votes}
        length(locked.options) <= Poll.min_options() -> {:error, :too_few_options}
        true -> option |> Repo.delete() |> with_poll(locked)
      end
    end)
    |> refreshed()
  end

  defp with_poll({:ok, _option}, poll), do: {:ok, poll}
  defp with_poll(error, _poll), do: error

  defp refreshed({:ok, poll}) do
    refresh(poll)
    {:ok, poll}
  end

  defp refreshed(error), do: error

  @doc "Ends the voting now, and works out the decision."
  def close_poll(%Profile{} = actor, %Poll{} = poll) do
    now = DateTime.utc_now(:second)

    with_locked_poll(poll, actor, fn locked, group, access ->
      cond do
        not Rules.manage?(locked, access, actor) -> {:error, :not_permitted}
        locked.closed_at -> {:error, :closed}
        true -> {:ok, close_locked(locked, group, now)}
      end
    end)
    |> case do
      {:ok, closed} ->
        Notifications.deliver_closed(closed, actor)
        refresh(closed)
        {:ok, closed}

      error ->
        error
    end
  end

  @doc """
  Writes the end of a poll whose row the caller has locked. The right to vote is
  counted here, so that a later change of members leaves the decision as it was.
  """
  def close_locked(%Poll{} = poll, %Group{} = group, %DateTime{} = closed_at) do
    options = Repo.all(from(o in PollOption, where: o.poll_id == ^poll.id))
    eligible = eligible_count(poll, group)
    {outcome, winner_id} = Outcome.decide(poll, options, poll.voters_count, eligible || 0)

    poll
    |> Ecto.Changeset.change(
      closed_at: closed_at,
      remind_at: nil,
      eligible_count: eligible,
      outcome: outcome,
      winner_option_id: winner_id
    )
    |> Repo.update!()
  end

  @doc """
  Takes votes again and forgets the decision. A deadline that has passed goes
  with it. A secret poll stays closed: the difference between two closings,
  next to the list of new voters, would give away what they chose.
  """
  def reopen_poll(%Profile{} = actor, %Poll{} = poll) do
    now = DateTime.utc_now(:second)

    with_locked_poll(poll, actor, fn locked, _group, access ->
      cond do
        not Rules.manage?(locked, access, actor) -> {:error, :not_permitted}
        locked.secret -> {:error, :secret}
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

  @doc "Deletes the poll with all its votes, and the message that carries it."
  def delete_poll(%Profile{} = actor, %Poll{} = poll) do
    group = Repo.get!(Group, poll.group_id)

    if Rules.manage?(poll, Access.for_profile(actor, group), actor) do
      case poll.value_id && Repo.get(Value, poll.value_id) do
        %Value{} = value ->
          # Takes the poll with it, and tells open pages.
          Social.remove_value(value)
          {:ok, poll}

        _no_value ->
          Repo.delete!(poll)
          broadcast_deleted(poll)
          {:ok, poll}
      end
    else
      {:error, :not_permitted}
    end
  end

  defp with_locked_poll(%Poll{id: poll_id}, %Profile{} = profile, fun) do
    Repo.transaction(fn ->
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
  How many may vote: people, not profiles, as one account votes once, and each
  shared profile as one. nil for a public poll, where anyone may.
  """
  def eligible_count(%Poll{is_public: true}, %Group{}), do: nil

  def eligible_count(%Poll{} = poll, %Group{} = group) do
    profile_ids = eligible_profile_ids(poll, group)

    holders =
      from(ap in AccountProfile,
        join: p in Profile,
        on: p.id == ap.profile_id,
        where: ap.profile_id in ^profile_ids,
        select: {ap.profile_id, ap.account_id, p.sharing}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0))

    profile_ids
    |> Enum.map(fn profile_id ->
      case Map.get(holders, profile_id, []) do
        [{_profile_id, account_id, _sharing}] -> {:account, account_id}
        [] -> {:profile, profile_id}
        _several_accounts -> {:shared, profile_id}
      end
    end)
    |> Enum.uniq()
    |> length()
  end
end
