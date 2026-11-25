defmodule PotokIde.Social.ScheduledValues do
  @moduledoc """
  Messages that go out later. A member writes one now and picks its time, and
  it is sent then whether or not they are around
  (`PotokIde.Social.ScheduledValues.Scheduler` calls `run_due/1`).

  Nothing of it is in the chat until it goes out. Who may post, whom it
  mentions, which processes it starts and the cards of its links are all
  worked out at that moment, by what writes every message
  (`PotokIde.Social.insert_scheduled_value/5`), and the row goes in the same
  transaction, so a message is sent once however many nodes look for it. Only
  a member's goes out: whoever left takes their waiting messages with them.

  One that could not be sent keeps its row with the reason
  (`ScheduledValue.failure`), its author gets a push, and it waits for them to
  send it, give it another time or delete it. A message more than an hour late
  counts as that too, as what it says may no longer hold.

  It belongs to the profile, as a sent message does: every account with a
  shared profile sees it, changes it and cancels it.
  """

  import Ecto.Query

  require Logger

  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AccountProfile,
    Group,
    GroupMembership,
    Notifications,
    Profile,
    ScheduledValue,
    Value,
    ValueAttachment
  }

  alias PotokIde.Social.ScheduledValues.Scheduler
  alias PotokIde.Storage

  # How late a message still goes out by itself.
  @late_seconds 3_600

  # What one profile may have waiting, in all its groups.
  @max_waiting 100

  # Messages in one pass; the scheduler comes back for the rest.
  @batch 200

  def late_seconds, do: @late_seconds
  def max_waiting, do: @max_waiting

  @doc """
  Whether `profile`, with `access` to `group`, may schedule a message there: a
  member who may post. Someone who writes in an open chat from outside may
  not, as their messages are counted by the minute.
  """
  def can_schedule?(nil, _access, _group), do: false

  def can_schedule?(%Profile{} = profile, %Access{} = access, %Group{} = group),
    do: access.member? and not group.is_root and Access.can_post_in_chat?(profile, access, group)

  ## The author's own

  @doc "What `profile` has waiting in `group`: what failed first, then by time."
  def list(%Profile{id: profile_id}, %Group{id: group_id}) do
    from(s in ScheduledValue,
      where: s.profile_id == ^profile_id and s.group_id == ^group_id,
      order_by: [asc: is_nil(s.failure), asc: s.send_at, asc: s.id],
      preload: [parent: [:creator, :attachments]]
    )
    |> Repo.all()
  end

  @doc """
  Schedules a message for `send_at`. `files` are as in `Social.create_value/4`
  and belong to the row once this returns `{:ok, _}`; on an error they are the
  caller's to remove.
  """
  def schedule(%Profile{} = profile, %Group{} = group, attrs, files, %DateTime{} = send_at) do
    attrs = attrs |> Map.new() |> Map.take(["content", "parent_id"])
    send_at = DateTime.truncate(send_at, :second)

    with :ok <- check(profile, group, files),
         :ok <- check_time(send_at),
         :ok <- check_parent(attrs["parent_id"], group),
         :ok <- check_waiting(profile),
         {:ok, scheduled} <-
           %ScheduledValue{group_id: group.id, profile_id: profile.id, files: to_rows(files)}
           |> ScheduledValue.insert_changeset(attrs, send_at)
           |> Repo.insert() do
      changed(scheduled)
      Scheduler.nudge()
      {:ok, scheduled}
    end
  end

  @doc """
  Changes the text and the time of a message that waits, by its form. One that
  failed needs a time still to come, and then waits again.
  """
  def update(%Profile{} = profile, %Group{} = group, id, attrs, time_zone) do
    Repo.transaction(fn ->
      with %ScheduledValue{} = scheduled <- lock_own(profile, group, id),
           {:ok, scheduled} <-
             scheduled
             |> ScheduledValue.with_form_fields(time_zone)
             |> ScheduledValue.changeset(attrs, time_zone)
             |> Repo.update() do
        scheduled
      else
        nil -> Repo.rollback(:not_found)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, scheduled} ->
        changed(scheduled)
        Scheduler.nudge()
        {:ok, scheduled}

      error ->
        error
    end
  end

  @doc "Deletes a message that waits, with its files."
  def cancel(%Profile{} = profile, %Group{} = group, id) do
    case Repo.delete_all(from(s in own(profile, group, id), select: s)) do
      {1, [scheduled]} ->
        Storage.delete_later(ScheduledValue.storage_keys(scheduled.files))
        changed(scheduled)
        :ok

      {0, _none} ->
        {:error, :not_found}
    end
  end

  @doc "Sends a message that waits now, as its author would have written it."
  def send_now(%Profile{} = profile, %Group{} = group, id) do
    Repo.transaction(fn ->
      with %ScheduledValue{} = scheduled <- lock_own(profile, group, id),
           :ok <- check_member(profile, group),
           :ok <- check_direct(group),
           {:ok, value, announce} <- insert(scheduled, profile, group, unattended: false) do
        Repo.delete!(scheduled)
        {scheduled, value, announce}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {scheduled, value, announce}} ->
        changed(scheduled)
        announce.()
        {:ok, value}

      error ->
        error
    end
  end

  defp own(%Profile{id: profile_id}, %Group{id: group_id}, id) do
    from(s in ScheduledValue,
      where: s.id == ^id and s.profile_id == ^profile_id and s.group_id == ^group_id
    )
  end

  defp lock_own(profile, group, id),
    do: Repo.one(from(s in own(profile, group, id), lock: "FOR UPDATE"))

  ## Checks

  defp check(profile, group, files) do
    access = Access.for_profile(profile, group)

    cond do
      not can_schedule?(profile, access, group) -> {:error, :not_permitted}
      files != [] and not Access.can?(access, :attach_files) -> {:error, :not_permitted}
      length(files) > Storage.max_files() -> {:error, :too_many_attachments}
      true -> check_direct(group)
    end
  end

  defp check_member(profile, group) do
    if Access.for_profile(profile, group).member?, do: :ok, else: {:error, :not_permitted}
  end

  defp check_time(send_at) do
    case ScheduledValue.check_time(send_at) do
      :ok -> :ok
      reason -> {:error, reason}
    end
  end

  # A direct conversation whose other side deleted their account.
  defp check_direct(%Group{is_direct: true, id: group_id}) do
    gone? =
      Repo.exists?(
        from(m in GroupMembership,
          join: p in Profile,
          on: p.id == m.profile_id,
          where: m.group_id == ^group_id and p.kind == :deleted
        )
      )

    if gone?, do: {:error, :not_permitted}, else: :ok
  end

  defp check_direct(%Group{}), do: :ok

  defp check_parent(nil, _group), do: :ok

  defp check_parent(parent_id, %Group{id: group_id}) do
    there? =
      Repo.exists?(
        from(v in Value,
          where: v.id == ^parent_id and v.group_id == ^group_id and v.is_data == false
        )
      )

    if there?, do: :ok, else: {:error, :invalid_parent}
  end

  defp check_waiting(%Profile{id: profile_id}) do
    waiting =
      Repo.aggregate(from(s in ScheduledValue, where: s.profile_id == ^profile_id), :count)

    if waiting < @max_waiting, do: :ok, else: {:error, :too_many_scheduled}
  end

  defp to_rows(files) do
    Enum.map(files, fn file ->
      %{
        "storage_key" => Map.fetch!(file, :storage_key),
        "filename" => ValueAttachment.clean_filename(file.filename),
        "content_type" => ValueAttachment.clean_content_type(file.content_type),
        "byte_size" => file.byte_size
      }
    end)
  end

  ## Sending

  @doc "When the next message goes out, or nil."
  def next_at do
    Repo.one(from(s in ScheduledValue, where: is_nil(s.failure), select: min(s.send_at)))
  end

  @doc """
  Sends what is due at `now`, the longest due first and one after another, so
  two messages for the same minute go out in the order they were written.
  Returns how many it sent.
  """
  def run_due(now \\ DateTime.utc_now(:second)) do
    from(s in ScheduledValue,
      where: is_nil(s.failure) and s.send_at <= ^now,
      order_by: [asc: s.send_at, asc: s.id],
      limit: @batch,
      select: s.id
    )
    |> Repo.all()
    |> Enum.count(&(send_due(&1, now) == :sent))
  end

  defp send_due(id, now) do
    case attempt(id, now) do
      {:ok, {:sent, scheduled, value, announce}} ->
        # Before the message itself reaches the pages, so the author's own
        # know that it was not written on one of them.
        changed(scheduled, value.id)
        announce.()
        :sent

      {:ok, {:gone, scheduled}} ->
        Storage.delete_later(ScheduledValue.storage_keys(scheduled.files))
        changed(scheduled)
        :gone

      {:ok, :skip} ->
        :skip

      {:error, {:failed, reason}} ->
        fail(id, now, reason)
        :failed
    end
  end

  # The failure is written by a transaction of its own (`fail/3`): a write that
  # failed inside this one leaves nothing more to write in it.
  defp attempt(id, now) do
    Repo.transaction(fn ->
      case lock_due(id, now) do
        nil -> :skip
        scheduled -> deliver(scheduled, now)
      end
    end)
  rescue
    # The database's trouble, not the message's: the next pass tries again.
    exception in DBConnection.ConnectionError ->
      log(id, exception, __STACKTRACE__)
      {:ok, :skip}

    exception in Postgrex.Error ->
      log(id, exception, __STACKTRACE__)

      if match?(%{postgres: %{code: :deadlock_detected}}, exception),
        do: {:ok, :skip},
        else: {:error, {:failed, :error}}

    exception ->
      log(id, exception, __STACKTRACE__)
      {:error, {:failed, :error}}
  end

  # What a message says is nobody's but its author's until it goes out, and an
  # exception or a stacktrace may hold it: the log gets neither's arguments.
  defp log(id, exception, stacktrace) do
    places =
      Enum.map(stacktrace, fn
        {module, name, args, place} when is_list(args) -> {module, name, length(args), place}
        entry -> entry
      end)

    Logger.error(
      "Scheduled message #{id} failed: #{exception_text(exception)}\n" <>
        Exception.format_stacktrace(places)
    )
  end

  defp exception_text(%module{} = exception)
       when module in [DBConnection.ConnectionError, Postgrex.Error],
       do: Exception.message(exception)

  defp exception_text(%module{}), do: inspect(module)

  # The message, unless another node is sending it, it is gone, or its author
  # moved it meanwhile.
  defp lock_due(id, now) do
    from(s in ScheduledValue,
      where: s.id == ^id and is_nil(s.failure) and s.send_at <= ^now,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.one()
  end

  defp deliver(%ScheduledValue{} = scheduled, now) do
    profile = Repo.get!(Profile, scheduled.profile_id)
    group = Repo.get!(Group, scheduled.group_id)

    cond do
      not Access.for_profile(profile, group).member? ->
        Repo.delete!(scheduled)
        {:gone, scheduled}

      DateTime.diff(now, scheduled.send_at) > @late_seconds ->
        Repo.rollback({:failed, :late})

      true ->
        with :ok <- check_direct(group),
             {:ok, value, announce} <- insert(scheduled, profile, group, unattended: true) do
          Repo.delete!(scheduled)
          {:sent, scheduled, value, announce}
        else
          {:error, :not_permitted} -> Repo.rollback({:failed, :not_permitted})
          {:error, reason} -> Repo.rollback({:failed, refused(scheduled, reason)})
        end
    end
  end

  defp refused(%ScheduledValue{id: id}, reason) do
    reason = with %Ecto.Changeset{errors: errors} <- reason, do: errors
    Logger.error("Scheduled message #{id} was refused: #{inspect(reason)}")
    :error
  end

  defp insert(%ScheduledValue{} = scheduled, profile, group, opts) do
    Social.insert_scheduled_value(
      profile,
      group,
      %{"content" => scheduled.content, "parent_id" => scheduled.parent_id},
      ScheduledValue.attachments(scheduled),
      opts
    )
  end

  defp fail(id, now, reason) do
    from(s in ScheduledValue,
      where: s.id == ^id and is_nil(s.failure) and s.send_at <= ^now,
      select: s
    )
    |> Repo.update_all(set: [failure: reason, updated_at: DateTime.utc_now(:second)])
    |> case do
      {1, [scheduled]} ->
        changed(scheduled)
        push_failure(scheduled)

      {0, _none} ->
        :ok
    end
  end

  defp push_failure(%ScheduledValue{} = scheduled) do
    group = Repo.get!(Group, scheduled.group_id)
    payload = Notifications.scheduled_value_failed(group, scheduled)

    Dispatch.run(fn ->
      from(ap in AccountProfile,
        where: ap.profile_id == ^scheduled.profile_id,
        select: ap.account_id
      )
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_localized("scheduled message", group.id, payload)
    end)
  end

  defp changed(%ScheduledValue{} = scheduled, sent_value_id \\ nil) do
    Social.broadcast_scheduled_values_changed(
      scheduled.profile_id,
      scheduled.group_id,
      sent_value_id
    )
  end

  ## What goes with an account

  @doc """
  Deletes what the profiles have waiting, in every group, for an account that
  goes. Returns the keys of the files, to delete once that commits.
  """
  def forget_profiles(profile_ids) when is_list(profile_ids) do
    {_count, files} =
      Repo.delete_all(
        from(s in ScheduledValue, where: s.profile_id in ^profile_ids, select: s.files)
      )

    ScheduledValue.storage_keys(files)
  end
end
