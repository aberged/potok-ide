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

  alias PotokIde.Events.Event
  alias PotokIde.Polls.Poll
  alias PotokIde.Social.{Value, ValueAttachment, ValueReaction, Visibility}

  # Their order breaks ties of one second, and pages go by it: new ones go last.
  @sources ~w(message file given received)a
  @ranks @sources |> Enum.with_index(1) |> Map.new()
  @by_rank Map.new(@ranks, fn {source, rank} -> {rank, source} end)

  # Above every id of the database.
  @max_id 9_223_372_036_854_775_807

  @doc "The source of a key."
  def by_rank(rank), do: Map.fetch!(@by_rank, rank)

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
end
