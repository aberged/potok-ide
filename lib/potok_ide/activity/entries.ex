defmodule PotokIde.Activity.Entries do
  @moduledoc """
  What a page of the timeline (`PotokIde.Activity`) says of each of its keys:
  read for the page at once, and only for the sources it has.

  An entry is a key with `:key` (its name on the page), `:source`, `:group` and,
  for what is in a thread, `:parent`, the group it hangs from when the reader
  sees it; and what its source adds:

  - `:value` (`:message`, `:file`, `:given`, `:received`): the message, as
    `%{id, text, author, mine?, announces}`, `text` the start of it in one line,
    `announces` `:event` or `:poll` for one that announces such;
  - `:emoji` (`:given`, `:group_reaction`): the reader's own, as they were put;
  - `:reactions`, `:people` and `:people_count` (`:received`): `{emoji, count}`
    of the others', the names of the last of them, and how many they are;
  - `:poll` (`:ballot`, `:poll`), as `%{id, question, secret?}`, and for a ballot
    `:choice`, what the reader voted for, nil in a secret poll, which keeps no
    such thing;
  - `:event` (`:event`, `:rsvp`), and for an answer its `:status` and the date it
    is `:on`;
  - `:app` (an alternative description, nil for the default one) and `:count` of
    the day's, as far as they are counted (`Activity.counted/0`, one more where
    there are more), never what they hold (`:record`);
  - `:process`, `:label`, `:type` and `:outcome` (`:run_answer`, `:run_start`);
  - `:person`, and for a `:decision` also `:decision`, `:role_key` and `:role` as
    the group's statute has it, nil once deleted (`:decision`, `:admission`);
  - `:notice`, as `%{id, text}`;
  - `:tags` and `:target`, `{kind, item}` (`:tag`).

  What went between the keys and this (a message deleted that moment) is left
  out.
  """

  import Ecto.Query

  alias PotokIde.Activity
  alias PotokIde.Activity.Sources
  alias PotokIde.Events.{Event, Recurrence, Response}
  alias PotokIde.Notices.{GroupFollow, GroupNotice}
  alias PotokIde.PlainText
  alias PotokIde.Polls.{Poll, PollBallot, PollOption}
  alias PotokIde.Processes.RunEvent
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppProcess,
    Group,
    GroupAccessChange,
    GroupJoinRequestApproval,
    GroupMembership,
    GroupReaction,
    GroupRequestDecision,
    Profile,
    Value,
    ValueAttachment,
    ValueReaction,
    ValueRules
  }

  alias PotokIde.Tags.{Tag, Tagging}

  # How much of a message is read for its one line, how long the line is, and
  # how many of those who reacted are named.
  @read 4_000
  @text 240
  @named 3

  @doc "The entries of `keys`, in their order."
  def load(keys, reader) do
    keys = Enum.map(keys, &Map.put(&1, :source, Sources.by_rank(&1.rank)))
    by_source = Enum.group_by(keys, & &1.source, & &1.id)

    loaded =
      by_source
      |> Enum.group_by(fn {source, _ids} -> kind(source) end)
      |> Enum.flat_map(fn {kind, sources} -> load_kind(kind, Map.new(sources), reader) end)
      |> Map.new()

    keys
    |> Enum.flat_map(fn key ->
      case Map.fetch(loaded, {key.source, key.id}) do
        {:ok, entry} -> [key |> Map.merge(entry) |> put_key()]
        :error -> []
      end
    end)
    |> put_places(reader)
  end

  defp kind(source) when source in [:message, :file, :given, :received], do: :values
  defp kind(source) when source in [:run_answer, :run_start], do: :runs
  defp kind(source) when source in [:decision, :admission], do: :requests
  defp kind(source), do: source

  # A message told by its files is the same row as the message.
  defp put_key(%{source: source, id: id} = entry),
    do: Map.put_new(entry, :key, "#{name(source)}-#{id}")

  defp name(:file), do: :message
  defp name(source), do: source

  # ---------
  # Messages and reactions
  # ---------

  defp load_kind(:values, sources, reader) do
    values = sources |> Map.values() |> List.flatten() |> Enum.uniq() |> values(reader)
    emoji = own_emoji(Map.get(sources, :given, []), reader)
    reactions = others_reactions(Map.get(sources, :received, []), reader)

    for {source, ids} <- sources, id <- ids, value = values[id] do
      extra =
        case source do
          :given -> %{emoji: Map.get(emoji, id, [])}
          :received -> Map.get(reactions, id, %{reactions: [], people: [], people_count: 0})
          _message -> %{}
        end

      {{source, id}, Map.merge(value, extra)}
    end
  end

  defp load_kind(:group_reaction, %{group_reaction: ids}, %{profile: profile, until: until}) do
    emoji =
      from(r in GroupReaction,
        where: r.group_id in ^ids and r.profile_id == ^profile.id and r.inserted_at < ^until,
        order_by: [asc: r.id],
        select: {r.group_id, r.emoji}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for {id, emoji} <- emoji, do: {{:group_reaction, id}, %{group_id: id, emoji: emoji}}
  end

  # ---------
  # Polls and events
  # ---------

  defp load_kind(:ballot, %{ballot: ids}, _reader) do
    ballots =
      from(b in PollBallot,
        join: p in assoc(b, :poll),
        where: b.id in ^ids,
        select: {b.id, b.option_ids, p}
      )
      |> Repo.all()

    # A secret poll's answers are not even read.
    option_ids = for {_id, ids, %Poll{secret: false}} <- ballots, id <- ids, do: id

    texts =
      from(o in PollOption, where: o.id in ^option_ids, select: {o.id, o.text})
      |> Repo.all()
      |> Map.new()

    for {id, chosen, poll} <- ballots do
      choice = if not poll.secret, do: chosen |> Enum.map(&texts[&1]) |> Enum.reject(&is_nil/1)
      {{:ballot, id}, Map.put(of_poll(poll), :choice, choice)}
    end
  end

  defp load_kind(:poll, %{poll: ids}, _reader) do
    for poll <- Repo.all(from(p in Poll, where: p.id in ^ids)),
        do: {{:poll, poll.id}, of_poll(poll)}
  end

  defp load_kind(:event, %{event: ids}, _reader) do
    for event <- Repo.all(from(e in Event, where: e.id in ^ids)),
        do: {{:event, event.id}, %{group_id: event.group_id, event: event}}
  end

  defp load_kind(:rsvp, %{rsvp: ids}, _reader) do
    for response <- Repo.all(from(r in Response, where: r.id in ^ids, preload: :event)) do
      {{:rsvp, response.id},
       %{
         group_id: response.event.group_id,
         event: response.event,
         status: response.status,
         on: response.occurs_on
       }}
    end
  end

  # ---------
  # Groups
  # ---------

  defp load_kind(:group_made, %{group_made: ids}, _reader),
    do: for(id <- ids, do: {{:group_made, id}, %{group_id: id}})

  defp load_kind(:joined, %{joined: ids}, _reader),
    do: for(id <- ids, do: {{:joined, id}, %{group_id: id}})

  defp load_kind(:left, %{left: ids}, _reader) do
    from(c in GroupAccessChange, where: c.id in ^ids, select: {c.id, c.group_id})
    |> Repo.all()
    |> Enum.map(fn {id, group_id} -> {{:left, id}, %{group_id: group_id}} end)
  end

  # ---------
  # Records, processes and requests
  # ---------

  defp load_kind(:record, %{record: ids}, %{profile: profile, zone: zone}) do
    rows =
      from(v in Value,
        left_join: d in assoc(v, :alt_description),
        where: v.id in ^ids,
        select: %{
          id: v.id,
          group_id: v.group_id,
          kept?: not is_nil(v.collection),
          inserted_at: v.inserted_at,
          app: map(d, [:id, :name])
        }
      )
      |> Repo.all()

    for row <- rows do
      day = Recurrence.local_date(row.inserted_at, zone)
      app_id = row.app && row.app.id

      {{:record, row.id},
       %{
         key: "record-#{row.group_id}-#{app_id || 0}-#{if row.kept?, do: 1, else: 0}-#{day}",
         group_id: row.group_id,
         app: app_id && row.app,
         count: counted(row, app_id, day, profile, zone)
       }}
    end
  end

  defp load_kind(:runs, sources, _reader) do
    ids = sources |> Map.values() |> List.flatten()

    runs =
      from(r in RunEvent,
        join: p in AppProcess,
        on: p.id == r.app_process_id,
        where: r.id in ^ids,
        select:
          {r.id,
           %{
             group_id: r.group_id,
             process: p.name,
             label: r.label,
             type: r.type,
             outcome: r.outcome
           }}
      )
      |> Repo.all()
      |> Map.new()

    for {source, ids} <- sources, id <- ids, run = runs[id], do: {{source, id}, run}
  end

  defp load_kind(:requests, sources, %{profile: profile}) do
    decisions =
      from(d in GroupRequestDecision,
        where: d.id in ^Map.get(sources, :decision, []),
        preload: [:group, :profile]
      )
      |> Repo.all()

    groups = decisions |> Enum.map(& &1.group) |> Enum.uniq_by(& &1.id)
    accesses = Access.for_profile_in_groups(profile, groups)

    decisions =
      for decision <- decisions do
        {{:decision, decision.id},
         %{
           group_id: decision.group_id,
           person: decision.profile,
           decision: decision.decision,
           role_key: decision.role_key,
           role: role(accesses[decision.group_id], decision.role_key)
         }}
      end

    admissions =
      from(a in GroupJoinRequestApproval,
        where: a.id in ^Map.get(sources, :admission, []),
        preload: :requester
      )
      |> Repo.all()

    decisions ++
      for(
        admission <- admissions,
        do:
          {{:admission, admission.id},
           %{group_id: admission.group_id, person: admission.requester}}
      )
  end

  # ---------
  # Notices, follows and tags
  # ---------

  defp load_kind(:notice, %{notice: ids}, _reader) do
    for notice <- Repo.all(from(n in GroupNotice, where: n.id in ^ids)) do
      text = PlainText.excerpt(notice.body, :markdown, @text)
      {{:notice, notice.id}, %{group_id: notice.group_id, notice: %{id: notice.id, text: text}}}
    end
  end

  defp load_kind(:follow, %{follow: ids}, _reader) do
    from(f in GroupFollow, where: f.id in ^ids, select: {f.id, f.group_id})
    |> Repo.all()
    |> Enum.map(fn {id, group_id} -> {{:follow, id}, %{group_id: group_id}} end)
  end

  defp load_kind(:tag, %{tag: ids}, reader) do
    taggings =
      from(t in Tagging,
        where: t.id in ^ids,
        preload: [:profile, :event, :attachment]
      )
      |> Repo.all()

    values = taggings |> Enum.map(& &1.value_id) |> Enum.reject(&is_nil/1) |> values(reader)
    tags = own_tags(taggings, reader)

    for tagging <- taggings, {kind, item, group_id} <- target(tagging, values) do
      {{:tag, tagging.id},
       %{
         key: "tag-#{kind}-#{item.id}",
         group_id: group_id,
         target: {kind, item},
         tags: Map.get(tags, {kind, item.id}, [])
       }}
    end
  end

  defp of_poll(%Poll{} = poll) do
    %{
      group_id: poll.group_id,
      poll: %{id: poll.id, question: poll.question, secret?: poll.secret}
    }
  end

  # How many of the day's went into the app up to this one.
  defp counted(row, app_id, day, profile, zone) do
    from(v in Value,
      where: v.creator_id == ^profile.id and v.is_data and v.group_id == ^row.group_id,
      where: v.inserted_at <= ^row.inserted_at and v.inserted_at >= ^day_start(day, zone),
      where: is_nil(v.collection) == ^(not row.kept?),
      where: is_nil(v.collection) or v.collection not in ^ValueRules.reserved(),
      where: fragment("? IS NOT DISTINCT FROM ?", v.alt_description_id, type(^app_id, :integer)),
      limit: ^(Activity.counted() + 1),
      select: 1
    )
    |> Repo.all()
    |> length()
  end

  defp day_start(%Date{} = day, zone), do: Recurrence.to_utc(day, ~T[00:00:00], zone)

  defp role(_access, nil), do: nil
  defp role(%Access{manifest: nil}, _key), do: nil
  defp role(%Access{manifest: manifest}, key), do: Enum.find(manifest.roles, &(&1.key == key))

  defp target(%Tagging{group_id: id}, _values) when is_integer(id),
    do: [{:group, %{id: id}, id}]

  defp target(%Tagging{profile: %Profile{} = profile}, _values), do: [{:profile, profile, nil}]

  defp target(%Tagging{event: %Event{} = event}, _values),
    do: [{:event, event, event.group_id}]

  defp target(%Tagging{attachment: %ValueAttachment{} = file}, _values),
    do: [{:file, file, file.group_id}]

  defp target(%Tagging{value_id: id}, values) when is_integer(id) do
    case values do
      %{^id => %{value: value, group_id: group_id}} -> [{:value, value, group_id}]
      _gone -> []
    end
  end

  # All the reader put on each thing: public tags, and private ones of its own.
  defp own_tags(taggings, %{profile: profile, until: until}) do
    ids = fn column -> for t <- taggings, id = Map.fetch!(t, column), do: id end

    from(t in Tagging,
      join: tag in Tag,
      on: tag.id == t.tag_id,
      where: t.added_by_id == ^profile.id and t.inserted_at < ^until,
      where:
        t.group_id in ^ids.(:group_id) or t.profile_id in ^ids.(:profile_id) or
          t.event_id in ^ids.(:event_id) or t.value_id in ^ids.(:value_id) or
          t.attachment_id in ^ids.(:attachment_id),
      order_by: [asc: t.id],
      select: {t, tag}
    )
    |> Repo.all()
    |> Enum.group_by(fn {tagging, _tag} -> thing(tagging) end, &elem(&1, 1))
  end

  defp thing(%Tagging{group_id: id}) when is_integer(id), do: {:group, id}
  defp thing(%Tagging{profile_id: id}) when is_integer(id), do: {:profile, id}
  defp thing(%Tagging{event_id: id}) when is_integer(id), do: {:event, id}
  defp thing(%Tagging{value_id: id}) when is_integer(id), do: {:value, id}
  defp thing(%Tagging{attachment_id: id}), do: {:file, id}

  defp values(ids, %{profile: profile}) do
    from(v in Value,
      where: v.id in ^ids,
      left_join: e in Event,
      on: e.value_id == v.id,
      left_join: p in Poll,
      on: p.value_id == v.id,
      join: c in assoc(v, :creator),
      left_join: a in assoc(c, :app_process),
      select: %{
        id: v.id,
        group_id: v.group_id,
        content: fragment("left(?, ?)", v.content, @read),
        content_format: v.content_format,
        creator: %{c | app_process: a},
        event?: not is_nil(e.id),
        poll?: not is_nil(p.id)
      }
    )
    |> Repo.all()
    |> put_files(ids)
    |> Map.new(fn row ->
      {row.id,
       %{
         group_id: row.group_id,
         value: %{
           id: row.id,
           text: text(row),
           author: row.creator,
           mine?: row.creator.id == profile.id,
           announces: announces(row)
         }
       }}
    end)
  end

  defp announces(%{event?: true}), do: :event
  defp announces(%{poll?: true}), do: :poll
  defp announces(_row), do: nil

  defp put_files(rows, ids) do
    files =
      from(a in ValueAttachment,
        where: a.value_id in ^ids,
        order_by: [asc: a.id],
        select: {a.value_id, a.filename}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &%ValueAttachment{filename: elem(&1, 1)})

    Enum.map(rows, &Map.put(&1, :attachments, Map.get(files, &1.id, [])))
  end

  # A tag the cut went through would read as text.
  defp text(%{content: content, content_format: format, attachments: attachments}) do
    content =
      if format == :html and is_binary(content),
        do: String.replace(content, ~r/<[^>]*\z/u, ""),
        else: content

    Value.excerpt(
      %Value{content: content, content_format: format, attachments: attachments},
      @text
    )
  end

  defp own_emoji([], _reader), do: %{}

  defp own_emoji(ids, %{profile: profile, until: until}) do
    from(r in ValueReaction,
      where: r.value_id in ^ids and r.profile_id == ^profile.id and r.inserted_at < ^until,
      order_by: [asc: r.id],
      select: {r.value_id, r.emoji}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp others_reactions([], _reader), do: %{}

  defp others_reactions(ids, %{profile: profile, until: until}) do
    others =
      from(r in ValueReaction,
        where: r.value_id in ^ids and r.profile_id != ^profile.id and r.inserted_at < ^until
      )

    counts =
      from(r in others,
        group_by: [r.value_id, r.emoji],
        order_by: [asc: min(r.id)],
        select: {r.value_id, {r.emoji, count(r.id)}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    # Someone's last reaction says where they stand among the last.
    people =
      from(r in others,
        join: p in assoc(r, :profile),
        group_by: [r.value_id, p.id],
        select: %{value_id: r.value_id, username: p.username, last: max(r.id)}
      )

    people =
      from(p in subquery(people),
        group_by: p.value_id,
        select:
          {p.value_id,
           fragment("(array_agg(? ORDER BY ? DESC))[1:?]", p.username, p.last, @named),
           count(p.value_id)}
      )
      |> Repo.all()

    Map.new(people, fn {id, names, count} ->
      {id, %{reactions: Map.get(counts, id, []), people: names, people_count: count}}
    end)
  end

  # ---------
  # Places
  # ---------

  # The group of each entry. A direct conversation goes by its other side, so
  # it comes with its members; a thread with the group it hangs from.
  defp put_places(entries, %{profile: profile}) do
    ids = entries |> Enum.map(& &1.group_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    groups = from(g in Group, where: g.id in ^ids) |> Repo.all()
    direct = groups |> Enum.filter(& &1.is_direct) |> Repo.preload(:members)
    groups = Map.merge(Map.new(groups, &{&1.id, &1}), Map.new(direct, &{&1.id, &1}))
    parents = parents(groups, profile)

    Enum.flat_map(entries, fn entry ->
      case {entry.group_id, Map.get(groups, entry.group_id)} do
        # A tag on a profile is in no group.
        {nil, nil} -> [Map.merge(entry, %{group: nil, parent: nil})]
        {_id, nil} -> []
        {_id, group} -> [Map.merge(entry, %{group: group, parent: parents[group.id]})]
      end
    end)
  end

  defp parents(groups, %Profile{id: profile_id}) do
    threads = for {id, %Group{parent_value_id: value_id}} <- groups, value_id, do: id

    if threads == [] do
      %{}
    else
      from(t in Group,
        join: p in Group,
        on: p.id == t.parent_id,
        left_join: m in GroupMembership,
        on: m.group_id == p.id and m.profile_id == ^profile_id,
        where: t.id in ^threads and (p.is_public or not is_nil(m.profile_id)),
        select: {t.id, p}
      )
      |> Repo.all()
      |> Map.new()
    end
  end
end
