defmodule PotokIde.Activity do
  @moduledoc """
  What a profile did over all its groups, and what others did with its
  messages, the newest first, a page at a time. Only the profile itself reads
  it, so every account that holds a shared one.

  Nothing is recorded for it: a page reads the things themselves
  (`PotokIde.Activity.Sources`), so what is deleted is gone from here too, and
  by the rights the profile has now: what is in a group it does not read any
  more is left out, and is there again when it is back.

  An entry is `%{key, source, id, at, ...}` (`PotokIde.Activity.Entries`). `key`
  stays the same for the same thing: a message has one row for all its
  reactions, at the newest, and one that moves is the same row.
  """

  alias PotokIde.Accounts.Account
  alias PotokIde.Activity.{Entries, Sources}
  alias PotokIde.Repo
  alias PotokIde.Social.Profile

  @page 30
  @timeout 3_000

  # What each filter reads. Files are messages too, so "all" tells them once.
  @filters [
    all: ~w(message given received ballot poll event rsvp group_made joined left group_reaction
            record run_answer run_start decision admission notice follow tag)a,
    messages: ~w(message)a,
    files: ~w(file)a,
    given: ~w(given group_reaction)a,
    received: ~w(received)a,
    votes: ~w(ballot poll)a,
    events: ~w(event rsvp)a,
    groups: ~w(group_made joined left)a,
    work: ~w(record run_answer run_start decision admission)a,
    notices: ~w(notice follow tag)a
  ]

  # Later than anything, and no id is as high.
  @start ~U[9999-12-31 23:59:59.000000Z]

  @doc "What the timeline can be narrowed to."
  def filters, do: Keyword.keys(@filters)

  @doc "How many entries a page has."
  def page_size, do: @page

  @doc """
  A page of what `profile` did, as `account`, one of its holders, reads it:
  `{:ok, %{entries, cursor}}`, `cursor` nil at the end, or `{:error, :timeout}`.

  Options: `:filter` (`filters/0`), `:until` (a `DateTime`: only what came
  before it), `:zone` (the reader's, for what is told once a day), `:cursor`
  (from the page before) and `:limit`.
  """
  def page(%Profile{} = profile, %Account{} = account, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page)

    sources = Keyword.fetch!(@filters, Keyword.get(opts, :filter, :all))

    # Before the transaction, inside which no cache of rights is read.
    reader =
      Sources.prepare(
        %{
          profile: profile,
          account: account,
          until: opts[:until] || @start,
          zone: opts[:zone] || "Etc/UTC",
          cursor: opts[:cursor]
        },
        sources
      )

    Repo.with_statement_timeout(
      @timeout,
      fn ->
        # What is the right plan for one profile is a wrong one for another,
        # with a few memberships or a hundred thousand.
        Repo.query!("SET LOCAL plan_cache_mode = force_custom_plan")

        rows = sources |> Sources.query(reader, limit + 1) |> Repo.all()

        {shown, rest} = Enum.split(rows, limit)
        %{entries: Entries.load(shown, reader), cursor: if(rest != [], do: cursor(shown))}
      end,
      jit: false
    )
  end

  defp cursor(shown) do
    %{at: at, rank: rank, id: id} = List.last(shown)
    %{at: at, rank: rank, id: id}
  end

  @doc false
  def start, do: @start
end
