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
  - `:emoji` (`:given`): the reader's own, as they were put;
  - `:reactions`, `:people` and `:people_count` (`:received`): `{emoji, count}`
    of the others', the names of the last of them, and how many they are.

  What went between the keys and this (a message deleted that moment) is left
  out.
  """

  import Ecto.Query

  alias PotokIde.Activity.Sources
  alias PotokIde.Events.Event
  alias PotokIde.Polls.Poll
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Group,
    GroupMembership,
    Profile,
    Value,
    ValueAttachment,
    ValueReaction
  }

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
    ids = entries |> Enum.map(& &1.group_id) |> Enum.uniq()

    groups = from(g in Group, where: g.id in ^ids) |> Repo.all()
    direct = groups |> Enum.filter(& &1.is_direct) |> Repo.preload(:members)
    groups = Map.merge(Map.new(groups, &{&1.id, &1}), Map.new(direct, &{&1.id, &1}))
    parents = parents(groups, profile)

    Enum.flat_map(entries, fn entry ->
      case Map.fetch(groups, entry.group_id) do
        {:ok, group} -> [Map.merge(entry, %{group: group, parent: parents[group.id]})]
        :error -> []
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
