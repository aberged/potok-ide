defmodule PotokIde.History do
  @moduledoc """
  The history of a group: who changed what in it, when, and what it was
  before.

  Postgres keeps it. Triggers on the tables of `PotokIde.History.Tracked`
  write a row (`PotokIde.History.GroupChange`) in the transaction that makes a
  change, so no path of the app can leave a hole in it. What Postgres cannot
  know is who did it and why, so whoever writes signs it:

      History.signed([actor: editor], fn -> Repo.update(changeset) end)

  Signed or not, the change is kept; unsigned, it has no name on it, except
  for what a row itself proves: whoever made a thing, and whose a reaction is.

  Of messages, reactions and notices only the fact is kept, never the text.
  Votes, members and profiles are not followed at all; what changes of access
  is `PotokIde.Social.AccessHistory`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias PotokIde.History.GroupChange
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, Profile, ValueRules}

  # What the process signs with, as it stands in the transaction.
  @key {__MODULE__, :context}

  # ---------
  # Signing
  # ---------

  @doc """
  Runs `fun` in a transaction whose changes are signed, and returns what it
  returns: `{:ok, result}`, or `{:error, reason}`, which takes the changes
  back. Inside a transaction of the caller's it only signs: whether an error
  takes everything back is the caller's to say, as without a signature.

  The signature is a keyword list:

    * `:actor` - a profile or its id; nil says nobody did it (a deadline, a
      decision), which then needs one of the rest to say what did
    * `:via` - how, an atom: `:system`, `:refresh`, `:kind`, `:regrade`…
    * `:count` - of how many things the change tells
    * `:poll`, `:process`, `:restored` - the id of the poll that decided it,
      the run that did it, the change that was put back

  A signature inside another adds to it, so a step of a process keeps the run
  it belongs to whatever the functions it calls sign. All the changes of the
  outermost one share an `op_id`.
  """
  def signed(signature, fun) when is_list(signature) and is_function(fun, 0) do
    if Repo.in_transaction?(),
      do: within(signature, fun),
      else: Repo.transact(fn -> within(signature, fun) end)
  end

  @doc """
  `Repo.transaction/1` with its changes signed as in `signed/2`, for a
  function that may call `Repo.rollback/1`, or for a multi, which comes first
  as it stands at the end of a pipeline.
  """
  def transaction(signature, fun) when is_list(signature) and is_function(fun, 0),
    do: Repo.transaction(fn -> within(signature, fun) end)

  def transaction(%Multi{} = multi, signature) when is_list(signature) do
    before = Process.get(@key)

    try do
      Multi.new()
      |> Multi.run(:signed, fn _repo, _changes -> {:ok, put(signature)} end)
      |> Multi.append(multi)
      |> Multi.run(:unsigned, fn _repo, %{signed: previous} -> {:ok, restore(previous)} end)
      |> Repo.transaction()
    after
      # A multi that failed never came to `:unsigned`.
      forget(before)
    end
  end

  @doc """
  Runs `fun`, whose own signatures then say this too. It opens no transaction,
  so what `fun` tells the pages it tells after its own has committed.
  """
  def also(signature, fun) when is_list(signature) and is_function(fun, 0) do
    before = Process.get(@key)
    context = before || %{op: new_op()}
    Process.put(@key, Map.merge(context, Map.new(signature, &part/1)))

    try do
      fun.()
    after
      forget(before)
    end
  end

  @doc "`Repo.update/1`, signed."
  def update(changeset, signature) when is_list(signature),
    do: signed(signature, fn -> Repo.update(changeset) end)

  @doc "`Repo.delete/2`, signed."
  def delete(struct, signature, opts \\ []) when is_list(signature),
    do: signed(signature, fn -> Repo.delete(struct, opts) end)

  @doc """
  Runs `fun` signed, inside a transaction the caller already has. For batches,
  where each item has a signature of its own.
  """
  def within(signature, fun) when is_list(signature) and is_function(fun, 0) do
    before = Process.get(@key)
    previous = put(signature)

    try do
      case fun.() do
        {:error, _reason} = error ->
          restore_if_possible(previous)
          error

        result ->
          restore(previous)
          result
      end
    after
      # The setting goes back with the transaction when `fun` raised; here it
      # is only forgotten.
      forget(before)
    end
  end

  # A constraint that failed leaves the transaction taking no more statements,
  # and what it was signed with goes with it.
  defp restore_if_possible(previous) do
    restore(previous)
  rescue
    error in Postgrex.Error ->
      case error do
        %{postgres: %{code: :in_failed_sql_transaction}} -> :ok
        _other -> reraise error, __STACKTRACE__
      end
  end

  @doc """
  Runs `fun` in a transaction that leaves no history: for an account that is
  being deleted, which must not leave more behind, and for a write that only
  follows one the history has.
  """
  def off(fun) when is_function(fun, 0), do: transaction([off: true], fun)

  @doc """
  How long a statement that deletes all an app keeps may take: each record
  leaves a version, which doubles what the delete alone takes (100,000 records
  in 10 s, measured 2026-11-24).
  """
  def bulk_timeout, do: :timer.minutes(1)

  defp put(signature) do
    previous = Process.get(@key)

    context =
      (previous || %{op: new_op()})
      |> Map.merge(Map.new(signature, &part/1))

    set(Jason.encode!(context))
    Process.put(@key, context)
    previous
  end

  defp new_op, do: :rand.uniform(9_000_000_000_000_000)

  defp restore(nil) do
    set("")
    Process.delete(@key)
    nil
  end

  defp restore(previous) do
    set(Jason.encode!(previous))
    Process.put(@key, previous)
    nil
  end

  defp forget(nil), do: Process.delete(@key)
  defp forget(previous), do: Process.put(@key, previous)

  # Local to the transaction, as a pooled connection is another client's next.
  defp set(json), do: Repo.query!("SELECT set_config('potok.history', $1, true)", [json])

  defp part({:actor, %Profile{id: id}}), do: {:actor, id}
  defp part({:actor, id}) when is_integer(id) or is_nil(id), do: {:actor, id}
  defp part({:off, true}), do: {:off, true}
  defp part({:via, via}) when is_atom(via), do: {:via, via}

  defp part({key, id}) when key in [:poll, :process, :restored, :count] and is_integer(id),
    do: {key, id}

  @doc "When the history began: what changed before is not in it."
  def since do
    case :persistent_term.get({__MODULE__, :since}, nil) do
      nil ->
        %{rows: [[at]]} =
          Repo.query!(
            "SELECT inserted_at FROM schema_migrations WHERE version = $1",
            [20_261_124_183_712]
          )

        at = DateTime.from_naive!(at, "Etc/UTC")
        :persistent_term.put({__MODULE__, :since}, at)
        at

      at ->
        at
    end
  end

  # ---------
  # What the triggers do not see
  # ---------

  @doc """
  Writes a change the triggers cannot tell, in the caller's transaction and
  with its signature: `:fields`, `:before`, `:alt_description_id` and
  `:collection` as they are in `PotokIde.History.GroupChange`.
  """
  def record!(group_or_id, type, subject_id, op, opts \\ []) do
    group_id =
      case group_or_id do
        %Group{id: id} -> id
        id when is_integer(id) -> id
      end

    Repo.query!(
      """
      SELECT history_write($1, $2, $3, $4, $5, $6, NULL, NULL, $7, $8, false, NULL, NULL, false)
      """,
      [
        group_id,
        type,
        subject_id,
        to_string(op),
        opts[:fields] || [],
        opts[:before],
        opts[:alt_description_id],
        opts[:collection]
      ]
    )

    :ok
  end

  @doc """
  Files the history of an app's records and processes under the description
  its app moved to, with the app itself (`PotokIde.Social.AppScope`), so that
  it is read by the rules of the app it belongs to.
  """
  def move_app(repo, group_id, from, to) when is_integer(group_id) do
    GroupChange
    |> where([c], c.group_id == ^group_id and c.subject_type in ["record", "process"])
    |> filed_under(from)
    |> repo.update_all(set: [alt_description_id: to])

    :ok
  end

  defp filed_under(query, nil), do: where(query, [c], is_nil(c.alt_description_id))
  defp filed_under(query, alt_id), do: where(query, [c], c.alt_description_id == ^alt_id)

  @doc """
  Leaves the old versions of the group's default description to the holders
  of `role_keys`, as the description itself was: changing a group's kind puts
  what stood there among the descriptions only its editors see. What the
  description is now stays everyone's.
  """
  def close_description(%Group{id: group_id}, role_keys) when is_list(role_keys) do
    versions =
      from(c in GroupChange,
        where:
          c.group_id == ^group_id and c.subject_type == "group" and
            fragment("'description' = ANY(?)", c.fields)
      )

    last_id = Repo.one(from(c in versions, select: max(c.id)))

    Repo.update_all(versions, set: [keys_before: role_keys])

    Repo.update_all(from(c in versions, where: c.id < ^(last_id || 0)),
      set: [keys_after: role_keys]
    )

    :ok
  end

  # ---------
  # Forgetting
  # ---------

  # What keeps old values someone may want gone. The rest keep only the fact.
  @emptied ~w(group description template record process entity field poll event)

  # How many old versions of one thing are kept; of older ones only the fact.
  @versions 200

  @doc "How many old versions of one thing are kept."
  def versions, do: @versions

  @doc """
  Whether the holder of `access` may empty the old versions of the thing a
  change is of: an admin, and of an app's record its editors and its author
  (`profile_id`).
  """
  def may_empty?(%Access{member?: true} = access, profile_id, %GroupChange{} = change) do
    cond do
      change.subject_type not in @emptied -> false
      access.admin? -> true
      change.subject_type != "record" -> false
      change.creator_id == profile_id and not is_nil(profile_id) -> true
      true -> ValueRules.manage?(access)
    end
  end

  def may_empty?(_access, _profile_id, _change), do: false

  @doc """
  Empties the old versions of the thing `change` is of: what it was is gone,
  and that it changed, when and by whom stays, with who emptied it. Of records
  deleted at once, those of all of them. Returns `{:ok, how many}` or
  `{:error, :not_permitted}`.
  """
  def empty(%Profile{} = profile, %Group{} = group, %GroupChange{} = change) do
    access = Access.for_profile(profile, group)

    if change.group_id == group.id and may_empty?(access, profile.id, change) do
      {count, _} =
        GroupChange
        |> where([c], c.group_id == ^group.id)
        |> where([c], c.subject_type == ^change.subject_type)
        |> of_subjects(change)
        |> emptied(profile.id)

      {:ok, count}
    else
      {:error, :not_permitted}
    end
  end

  defp of_subjects(
         query,
         %GroupChange{op: :deleted, cause: %{"count" => _}, op_id: op_id} = change
       )
       when is_integer(op_id) do
    together =
      from(d in GroupChange,
        where:
          d.group_id == ^change.group_id and d.subject_type == ^change.subject_type and
            d.op == :deleted and d.op_id == ^op_id and
            fragment("? IS NOT DISTINCT FROM ?", d.collection, ^change.collection) and
            fragment("? IS NOT DISTINCT FROM ?", d.alt_description_id, ^change.alt_description_id),
        select: d.subject_id
      )

    where(query, [c], c.subject_id in subquery(together))
  end

  defp of_subjects(query, change), do: where(query, [c], c.subject_id == ^change.subject_id)

  @doc """
  Forgets deleted profiles in the history, in the caller's transaction: their
  reactions are no more, and of the records they wrote into apps no old
  version is kept. That they changed things stays, as "Deleted user".
  """
  def forget_profiles([]), do: :ok

  def forget_profiles(profile_ids) when is_list(profile_ids) do
    Repo.delete_all(
      from(c in GroupChange,
        where: c.subject_type in ["reaction", "group_reaction"] and c.creator_id in ^profile_ids
      )
    )

    GroupChange
    |> where([c], c.subject_type == "record" and c.creator_id in ^profile_ids)
    |> emptied(nil)

    :ok
  end

  @doc """
  Empties the versions past the newest #{@versions} of each thing that changed
  in the last day, so an app that writes every second does not fill the
  database. The hourly sweep calls it (`PotokIde.Social.AppFileSweeper`).
  Returns how many it emptied.
  """
  def thin(now \\ DateTime.utc_now()) do
    %{num_rows: count} =
      Repo.query!(
        """
        UPDATE group_changes c
        SET before = NULL, purged_at = date_trunc('second', timezone('utc', now()))
        FROM (
          SELECT h.id, row_number() OVER (
            PARTITION BY h.subject_type, h.subject_id ORDER BY h.id DESC
          ) AS n
          FROM group_changes h
          JOIN (
            SELECT r.subject_type, r.subject_id
            FROM group_changes r
            WHERE r.at > $1
            GROUP BY 1, 2
          ) recent USING (subject_type, subject_id)
          WHERE h.before IS NOT NULL
        ) v
        WHERE v.id = c.id AND v.n > $2
        """,
        [now |> DateTime.add(-1, :day) |> DateTime.to_naive(), @versions]
      )

    count
  end

  defp emptied(query, profile_id) do
    query
    |> where([c], not is_nil(c.before))
    |> Repo.update_all(
      set: [before: nil, purged_at: DateTime.utc_now(:second), purged_by_id: profile_id]
    )
  end
end
