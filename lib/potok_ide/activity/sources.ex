defmodule PotokIde.Activity.Sources do
  @moduledoc """
  Where `PotokIde.Activity` reads what a profile did: a query of `%{id, at}` for
  each source, with the rights the profile has now in it, put together into one
  that gives a page's keys, `%{rank, id, at}`.

  Each source gives a page's worth of its own newest, and the page takes the
  newest of them all, so a page costs the same wherever it is. The order is by
  time, then source (`rank`), then id, and a page goes on after the last key of
  the page before. Times come as they were kept, most to the second.

  Where a thing has one row for many (a message for all its reactions), the
  upper bound of the time belongs inside the grouping, as it says which of them
  count, and the place of the page outside, as a thing told on one page is not
  told again on the next.
  """

  import Ecto.Query

  alias PotokIde.Events.{Event, Response}
  alias PotokIde.Notices.{GroupFollow, GroupNotice}
  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, PollBallot}
  alias PotokIde.Processes.RunEvent
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppProcess,
    Group,
    GroupAccessChange,
    GroupAltDescription,
    GroupJoinRequestApproval,
    GroupMembership,
    GroupReaction,
    GroupRequestDecision,
    Profile,
    Value,
    ValueAttachment,
    ValueReaction,
    ValueRules,
    Visibility
  }

  alias PotokIde.Tags
  alias PotokIde.Tags.Tagging

  # Their order breaks ties of one second, and pages go by it: new ones go last.
  @sources ~w(message file given received ballot poll event rsvp group_made joined left
              group_reaction record run_answer run_start decision admission notice follow tag)a
  @ranks @sources |> Enum.with_index(1) |> Map.new()
  @by_rank Map.new(@ranks, fn {source, rank} -> {rank, source} end)

  # Those that depend on which apps of a group the reader sees.
  @of_apps ~w(record run_answer run_start)a

  # Above every id of the database.
  @max_id 9_223_372_036_854_775_807

  @doc "The source of a key."
  def by_rank(rank), do: Map.fetch!(@by_rank, rank)

  @doc """
  The reader with what its sources need read beforehand: `alts`, the
  alternative descriptions for some roles only whose app it sees.
  """
  def prepare(reader, sources) do
    alts = if Enum.any?(sources, &(&1 in @of_apps)), do: seen_alts(reader.profile), else: []
    Map.put(reader, :alts, alts)
  end

  # What a role sees goes by the group's statute, which a query cannot follow;
  # few descriptions are for some roles only.
  defp seen_alts(%Profile{id: profile_id} = profile) do
    rows =
      from(d in GroupAltDescription,
        join: m in GroupMembership,
        on: m.group_id == d.group_id and m.profile_id == ^profile_id,
        join: g in assoc(d, :group),
        where: fragment("cardinality(?) > 0", d.visible_role_keys),
        select: {g, struct(d, [:id, :group_id, :visible_role_keys])}
      )
      |> Repo.all()

    groups = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(& &1.id)
    accesses = Access.for_profile_in_groups(profile, groups)

    for {group, alt} <- rows, Access.sees_alt_description?(accesses[group.id], alt), do: alt.id
  end

  @doc "The keys of `sources` after the reader's cursor, at most `limit`, the newest first."
  def query(sources, reader, limit) do
    [first | rest] = Enum.map(sources, &arm(&1, reader, limit))

    union = Enum.reduce(rest, first, &union_all(&2, ^&1))

    from(k in subquery(union),
      order_by: [desc: k.at, asc: k.rank, desc: k.id],
      limit: ^limit,
      select: %{rank: k.rank, id: k.id, at: k.at}
    )
  end

  defp arm(source, reader, limit) do
    rank = Map.fetch!(@ranks, source)
    {at, id} = place(reader.cursor, rank)

    page =
      from(s in subquery(source(source, reader)),
        where:
          fragment(
            "(?, ?) < (?, ?)",
            s.at,
            s.id,
            type(^at, :utc_datetime_usec),
            type(^id, :integer)
          ),
        order_by: [desc: s.at, desc: s.id],
        limit: ^limit,
        # Without its precision, as the sources differ in it.
        select: %{
          rank: type(^rank, :integer),
          id: s.id,
          at: type(fragment("?::timestamp", s.at), :utc_datetime_usec)
        }
      )

    from(p in subquery(page), select: %{rank: p.rank, id: p.id, at: p.at})
  end

  # What follows the cursor in the order of time, source and id, as a bound of
  # time and id for one source.
  defp place(nil, _rank), do: {PotokIde.Activity.start(), @max_id}
  defp place(%{at: at, rank: rank, id: id}, rank), do: {at, id}
  defp place(%{at: at, rank: last}, rank) when rank > last, do: {at, @max_id}
  defp place(%{at: at}, _rank), do: {at, 0}

  # The day of `at` in `zone`; times are kept in UTC.
  defmacrop local_day(at, zone) do
    quote do
      fragment(
        "((?) AT TIME ZONE 'UTC' AT TIME ZONE ?)::date",
        unquote(at),
        type(unquote(zone), :string)
      )
    end
  end

  @doc """
  What the reader wrote into apps. An app may write by the hundred, so what went
  into one app of a group in one day of the reader's is one row, at the last of
  it: `%{id, at, group_id, alt_description_id, kept, count}`, `kept` false for
  values of no collection, which are apart. The query's binding is `:value`.

  It groups all the reader ever wrote, which takes as long as there is of it
  (35,000 in 0.1 s). Asking of each record whether another came after it would
  stop at a page, but where Postgres has no fresh statistics of the table it
  looks among all of the group's records, again for each (0.7 s for 2,000).
  """
  def written(%{profile: profile, until: until, zone: zone}) do
    from(v in Value,
      as: :value,
      where: v.creator_id == ^profile.id and v.is_data and v.inserted_at < ^until,
      where: is_nil(v.collection) or v.collection not in ^ValueRules.reserved(),
      group_by: [
        v.group_id,
        v.alt_description_id,
        is_nil(v.collection),
        local_day(v.inserted_at, ^zone)
      ],
      select: %{
        id: max(v.id),
        at: max(v.inserted_at),
        group_id: v.group_id,
        alt_description_id: v.alt_description_id,
        kept: type(fragment("bool_and(? IS NOT NULL)", v.collection), :boolean),
        count: count(v.id)
      }
    )
  end

  # ---------
  # Messages
  # ---------

  # An event or a poll is told as one, not as the message that announces it.
  defp source(:message, %{profile: profile, until: until}) do
    event = from(e in Event, where: e.value_id == parent_as(:value).id, select: 1)
    poll = from(p in Poll, where: p.value_id == parent_as(:value).id, select: 1)

    from(v in Value,
      as: :value,
      where: v.creator_id == ^profile.id and not v.is_data and v.inserted_at < ^until,
      where: not exists(event) and not exists(poll)
    )
    |> Visibility.in_read_chats(profile)
    |> select([value: v], %{id: v.id, at: v.inserted_at})
  end

  # From the files, as a profile has few of them next to its messages.
  defp source(:file, %{profile: profile, until: until}) do
    files =
      from(a in ValueAttachment,
        where: a.profile_id == ^profile.id and not is_nil(a.value_id),
        group_by: a.value_id,
        select: %{value_id: a.value_id}
      )

    from(v in Value,
      as: :value,
      join: f in subquery(files),
      on: f.value_id == v.id,
      where: v.creator_id == ^profile.id and not v.is_data and v.inserted_at < ^until
    )
    |> Visibility.in_read_chats(profile)
    |> select([value: v], %{id: v.id, at: v.inserted_at})
  end

  # ---------
  # Reactions
  # ---------

  defp source(:given, %{profile: profile, until: until}) do
    from(r in ValueReaction,
      where: r.profile_id == ^profile.id and r.inserted_at < ^until,
      group_by: r.value_id,
      select: %{value_id: r.value_id, at: max(r.inserted_at)}
    )
    |> reacted_values(profile)
  end

  defp source(:received, %{profile: profile, until: until}) do
    from(r in ValueReaction,
      join: v in Value,
      on: v.id == r.value_id,
      where: v.creator_id == ^profile.id and not v.is_data,
      where: r.profile_id != ^profile.id and r.inserted_at < ^until,
      group_by: r.value_id,
      select: %{value_id: r.value_id, at: max(r.inserted_at)}
    )
    |> reacted_values(profile)
  end

  # One row for a group, as for a message.
  defp source(:group_reaction, %{profile: profile, until: until}) do
    reactions =
      from(r in GroupReaction,
        where: r.profile_id == ^profile.id and r.inserted_at < ^until,
        group_by: r.group_id,
        select: %{group_id: r.group_id, at: max(r.inserted_at)}
      )

    from([group: g] in Visibility.plain_groups(profile),
      join: r in subquery(reactions),
      on: r.group_id == g.id,
      select: %{id: g.id, at: r.at}
    )
  end

  # ---------
  # Polls and events
  # ---------

  # A holder of a shared profile who votes for themself sees only their own
  # ballot, and one whose account is gone is nobody's to see.
  defp source(:ballot, %{profile: profile, account: account, until: until}) do
    from(b in PollBallot,
      as: :ballot,
      join: p in assoc(b, :poll),
      as: :poll,
      join: g in assoc(p, :group),
      as: :group,
      where: b.profile_id == ^profile.id,
      where: not b.by_holder or b.account_id == ^account.id,
      where: coalesce(b.changed_at, b.inserted_at) < ^until
    )
    |> Polls.where_open_to(profile)
    |> select([ballot: b], %{
      id: b.id,
      at: type(coalesce(b.changed_at, b.inserted_at), :utc_datetime)
    })
  end

  # A poll a request raised is in the name of who asked, not their doing.
  defp source(:poll, %{profile: profile, until: until}) do
    from(p in Poll,
      as: :poll,
      join: g in assoc(p, :group),
      as: :group,
      where: p.creator_id == ^profile.id and not p.from_request and p.inserted_at < ^until
    )
    |> Polls.where_open_to(profile)
    |> select([poll: p], %{id: p.id, at: p.inserted_at})
  end

  defp source(:event, %{profile: profile, until: until}) do
    from(e in Event,
      as: :event,
      join: g in assoc(e, :group),
      as: :group,
      where: e.creator_id == ^profile.id and e.inserted_at < ^until
    )
    |> open_events(profile)
    |> select([event: e], %{id: e.id, at: e.inserted_at})
  end

  # By the last answer, which is the one that counts.
  defp source(:rsvp, %{profile: profile, until: until}) do
    from(r in Response,
      as: :response,
      join: e in assoc(r, :event),
      as: :event,
      join: g in assoc(e, :group),
      as: :group,
      where: r.profile_id == ^profile.id and r.updated_at < ^until
    )
    |> open_events(profile)
    |> select([response: r], %{id: r.id, at: r.updated_at})
  end

  # ---------
  # Groups
  # ---------

  defp source(:group_made, %{profile: profile, until: until}) do
    from([group: g] in Visibility.plain_groups(profile),
      where: g.creator_id == ^profile.id and g.inserted_at < ^until,
      where: not g.is_root and is_nil(g.external_key),
      select: %{id: g.id, at: g.inserted_at}
    )
  end

  # Whoever made the group, or was put in it as it was made, did not join it.
  defp source(:joined, %{profile: profile, until: until}) do
    from(m in GroupMembership,
      join: g in assoc(m, :group),
      where: m.profile_id == ^profile.id and not m.inherited and m.inserted_at < ^until,
      where:
        not g.is_root and not g.is_direct and is_nil(g.parent_value_id) and
          is_nil(g.external_key),
      where: m.inserted_at > datetime_add(g.inserted_at, 5, "second"),
      select: %{id: m.group_id, at: m.inserted_at}
    )
  end

  defp source(:left, %{profile: profile, until: until}) do
    from([group: g] in Visibility.plain_groups(profile),
      join: c in GroupAccessChange,
      on: c.group_id == g.id,
      where: c.subject_id == ^profile.id and c.kind == :member_left and c.inserted_at < ^until,
      select: %{id: c.id, at: c.inserted_at}
    )
  end

  # ---------
  # Records, processes and requests
  # ---------

  # Values of no collection are read by the group's members only.
  defp source(:record, %{profile: profile, alts: alts} = reader) do
    inside = Visibility.inside(profile)

    public =
      dynamic(
        [written: w, group: g],
        g.is_public and not g.is_root and not g.is_direct and is_nil(g.parent_value_id) and
          w.kept
      )

    from(w in subquery(written(reader)),
      as: :written,
      join: g in Group,
      on: g.id == w.group_id,
      as: :group,
      left_join: d in GroupAltDescription,
      on: d.id == w.alt_description_id,
      as: :alt
    )
    |> seen_apps(alts)
    |> Visibility.with_membership(profile)
    |> where(^dynamic(^inside or ^public))
    |> select([written: w], %{id: w.id, at: w.at})
  end

  # What a person finished: a decision, or a form filled in. The rest of a
  # run's trace names who was behind a change, not who did something in it.
  defp source(:run_answer, %{profile: profile, until: until} = reader) do
    from(r in RunEvent,
      as: :run,
      join: a in AppProcess,
      on: a.id == r.app_process_id,
      as: :process,
      where: r.actor_id == ^profile.id and r.kind == "answered" and r.at < ^until
    )
    |> runs(reader)
  end

  # Started by hand. One that a message, a record or a call started names
  # their author too, who may not know of it.
  defp source(:run_start, %{profile: profile, until: until} = reader) do
    from(r in RunEvent,
      as: :run,
      join: a in AppProcess,
      on: a.id == r.app_process_id,
      as: :process,
      where: r.actor_id == ^profile.id and r.kind == "started" and r.at < ^until,
      where: a.trigger == "manual"
    )
    |> runs(reader)
  end

  # Roles given and refused, admissions refused and put to a vote; one that
  # was granted is kept as an approval (`:admission`).
  defp source(:decision, %{profile: profile, until: until}) do
    from(d in GroupRequestDecision,
      as: :decision,
      join: g in assoc(d, :group),
      as: :group,
      where: d.decider_id == ^profile.id and d.inserted_at < ^until
    )
    |> Visibility.with_membership(profile)
    |> where([membership: m], not is_nil(m.profile_id))
    |> select([decision: d], %{id: d.id, at: d.inserted_at})
  end

  defp source(:admission, %{profile: profile, until: until}) do
    from(a in GroupJoinRequestApproval,
      as: :approval,
      join: g in assoc(a, :group),
      as: :group,
      where: a.approver_id == ^profile.id and a.approved_at < ^until
    )
    |> Visibility.with_membership(profile)
    |> where([membership: m], not is_nil(m.profile_id))
    |> select([approval: a], %{id: a.id, at: a.approved_at})
  end

  # ---------
  # Notices, follows and tags
  # ---------

  defp source(:notice, %{profile: profile, until: until}) do
    from([group: g] in Visibility.plain_groups(profile),
      join: n in GroupNotice,
      on: n.group_id == g.id,
      where: n.creator_id == ^profile.id and n.inserted_at < ^until and not g.is_root,
      select: %{id: n.id, at: n.inserted_at}
    )
  end

  defp source(:follow, %{profile: profile, until: until}) do
    from([group: g] in Visibility.plain_groups(profile),
      join: f in GroupFollow,
      on: f.group_id == g.id,
      where: f.profile_id == ^profile.id and f.inserted_at < ^until and not g.is_root,
      select: %{id: f.id, at: f.inserted_at}
    )
  end

  # One row for a thing, whatever the tags put on it.
  defp source(:tag, %{profile: profile, until: until}) do
    [first | rest] =
      for kind <- Tags.kinds() do
        column = Tags.column(kind)

        put =
          from(t in Tagging,
            where: t.added_by_id == ^profile.id and t.inserted_at < ^until,
            where: not is_nil(field(t, ^column)),
            group_by: field(t, ^column),
            select: %{item_id: field(t, ^column), id: max(t.id), at: max(t.inserted_at)}
          )

        Tags.open_items(profile, kind)
        |> join(:inner, [item], p in subquery(put), on: p.item_id == item.id, as: :put)
        |> select([put: p], %{id: p.id, at: p.at})
      end

    from(t in subquery(Enum.reduce(rest, first, &union_all(&2, ^&1))),
      select: %{id: t.id, at: t.at}
    )
  end

  defp reacted_values(reactions, profile) do
    from(v in Value,
      as: :value,
      join: r in subquery(reactions),
      as: :reaction,
      on: r.value_id == v.id,
      where: not v.is_data
    )
    |> Visibility.in_read_chats(profile)
    |> select([value: v, reaction: r], %{id: v.id, at: r.at})
  end

  defp open_events(query, profile) do
    inside = Visibility.inside(profile)
    public = dynamic([event: e], e.is_public)

    query
    |> Visibility.with_membership(profile)
    |> where(^dynamic(^inside or ^public))
  end

  defp runs(query, %{profile: profile, alts: alts}) do
    query
    |> join(:inner, [run: r], g in assoc(r, :group), as: :group)
    |> join(:left, [process: a], d in assoc(a, :alt_description), as: :alt)
    |> seen_apps(alts)
    |> Visibility.with_membership(profile)
    |> where([membership: m], not is_nil(m.profile_id))
    |> select([run: r], %{id: r.id, at: r.at})
  end

  # The apps of descriptions everyone sees, and of those for some roles the
  # ones the reader holds.
  defp seen_apps(query, alts) do
    where(
      query,
      [alt: d],
      is_nil(d.id) or fragment("cardinality(?) = 0", d.visible_role_keys) or d.id in ^alts
    )
  end
end
