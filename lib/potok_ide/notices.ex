defmodule PotokIde.Notices do
  @moduledoc """
  Following groups, and the notices a group sends to those who follow it.

  Anyone who may see a plain group may follow it, member or not
  (`can_follow?/3`): a public group any signed-in profile, a private one its
  members. The root, direct conversations and threads cannot be followed.
  Whoever holds `:send_notices` in a group sends its notices; admins hold it
  as they hold every permission.

  A notice is written once for every follower who sees the group at that
  moment, except its author, as a `GroupNoticeReceipt`: the profile's list of
  notices, its unread count, and what stays after unfollowing. A follower who
  comes later finds the older notices on the group's page. Push goes to a
  follower's devices while both its follow (`GroupFollow.push`) and its
  profile (`Profile.notice_push`) allow it.

  Pages hear of notices over two topics of their own, never over `profiles:`
  or `groups:`, whose LiveViews do not all know every message:

    * `notices:<profile_id>`, which `PotokIdeWeb.ProfileAuth` follows for the
      page's profile, with `{:notices, message}` where message is
      `{:received, profile_id, notice_id, group_id}`, `{:read, profile_id}`,
      `{:deleted, profile_id, notice_id, group_id, unread?}`,
      `{:follow_changed, profile_id, group_id}` or
      `{:push_changed, profile_id, on?}`;
    * `group_notices:<group_id>`, for the group's own page, with
      `{:group_notices, {:posted, notice_id}}` or
      `{:group_notices, {:removed, notice_id}}`.

  One message goes to each follower a notice reaches: on one machine that is
  a lookup per follower, and in a cluster also a message per other node. The
  limit of notices a group sends keeps it rare.
  """

  import Ecto.Query

  alias Phoenix.PubSub
  alias PotokIde.CountMark
  alias PotokIde.Notices.{GroupFollow, GroupNotice, GroupNoticeReceipt, Notifications}
  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, AccountProfile, Group, GroupMembership, Profile, Visibility}

  @page_size 20
  # The badge shows "999+" past this, so counting further reads rows for nothing.
  @unread_cap 1_000

  # What the lists of received notices load of a group: what its row shows.
  @group_fields [
    :id,
    :name,
    :is_public,
    :is_root,
    :is_direct,
    :parent_id,
    :parent_value_id,
    :preset,
    :uses_api,
    :updated_at
  ]

  ## Topics

  @doc "Follows the notices of `profile`. Only `PotokIdeWeb.ProfileAuth` calls it, once per page."
  def subscribe(%{id: id}) when is_integer(id),
    do: PubSub.subscribe(PotokIde.PubSub, profile_topic(id))

  def unsubscribe(%{id: id}) when is_integer(id),
    do: PubSub.unsubscribe(PotokIde.PubSub, profile_topic(id))

  @doc "Follows what is sent and deleted in a group, for its page."
  def subscribe_group(%Group{id: id}), do: PubSub.subscribe(PotokIde.PubSub, group_topic(id))

  defp profile_topic(profile_id), do: "notices:#{profile_id}"
  defp group_topic(group_id), do: "group_notices:#{group_id}"

  defp tell_profile(profile_id, message),
    do: PubSub.broadcast(PotokIde.PubSub, profile_topic(profile_id), {:notices, message})

  defp tell_group(group_id, message),
    do: PubSub.broadcast(PotokIde.PubSub, group_topic(group_id), {:group_notices, message})

  ## Following

  @doc "Whether a group can be followed at all: not the root, a direct conversation or a thread."
  def followable?(%Group{} = group),
    do: not group.is_root and not group.is_direct and is_nil(group.parent_value_id)

  @doc """
  Whether `profile`, with `access` to `group`, may follow it: a group it may
  see, public or one it is a member of.
  """
  def can_follow?(nil, _group, _access), do: false

  def can_follow?(%Profile{}, %Group{} = group, %Access{member?: member?}),
    do: followable?(group) and (group.is_public or member?)

  defp may_follow?(%Profile{id: profile_id}, %Group{} = group) do
    followable?(group) and
      (group.is_public or
         Repo.exists?(
           from(m in GroupMembership,
             where: m.group_id == ^group.id and m.profile_id == ^profile_id
           )
         ))
  end

  @doc "Follows `group`; following it again changes nothing. Its push starts on."
  def follow(%Profile{} = profile, %Group{} = group) do
    if may_follow?(profile, group) do
      follow =
        Repo.insert!(%GroupFollow{group_id: group.id, profile_id: profile.id},
          on_conflict: {:replace, [:updated_at]},
          conflict_target: [:group_id, :profile_id],
          returning: true
        )

      tell_profile(profile.id, {:follow_changed, profile.id, group.id})
      {:ok, follow}
    else
      {:error, :not_allowed}
    end
  end

  @doc "Stops following; what was received stays."
  def unfollow(%Profile{id: profile_id}, group_id) when is_integer(group_id) do
    {count, _} =
      Repo.delete_all(
        from(f in GroupFollow, where: f.group_id == ^group_id and f.profile_id == ^profile_id)
      )

    if count > 0, do: tell_profile(profile_id, {:follow_changed, profile_id, group_id})
    :ok
  end

  @doc "Whether the notices of a followed group push to the follower's devices."
  def set_follow_push(%Profile{id: profile_id}, group_id, push?)
      when is_integer(group_id) and is_boolean(push?) do
    query = from(f in GroupFollow, where: f.group_id == ^group_id and f.profile_id == ^profile_id)

    case Repo.update_all(query, set: [push: push?, updated_at: DateTime.utc_now(:second)]) do
      {1, _} ->
        tell_profile(profile_id, {:follow_changed, profile_id, group_id})
        :ok

      {0, _} ->
        {:error, :not_following}
    end
  end

  @doc """
  What a group's page shows of following and notices, in one query: whether
  the group sent any notice, whether `profile` follows it and lets it push,
  and how many followers it reaches now (those who still see it).
  """
  def group_state(%Group{id: group_id}, profile) do
    %{rows: [[notices?, push, followers]]} =
      Repo.query!(
        """
        SELECT EXISTS (SELECT 1 FROM group_notices WHERE group_id = $1),
               (SELECT push FROM group_follows WHERE group_id = $1 AND profile_id = $2),
               (SELECT count(*) FROM group_follows f JOIN groups g ON g.id = f.group_id
                 WHERE f.group_id = $1 AND #{Visibility.may_see_sql("g", "f.profile_id")})
        """,
        [group_id, profile && profile.id]
      )

    %{notices?: notices?, following?: not is_nil(push), push?: push == true, followers: followers}
  end

  @doc "Whether `profile` follows the group with `group_id`, whether it still sees it or not."
  def follows?(%Profile{id: profile_id}, group_id) when is_integer(group_id) do
    Repo.exists?(
      from(f in GroupFollow, where: f.group_id == ^group_id and f.profile_id == ^profile_id)
    )
  end

  @doc "The groups `profile` follows and still sees, by name, each with whether it pushes."
  def list_followed_groups(%Profile{id: profile_id} = profile) do
    from(g in Visibility.plain_groups(profile),
      join: f in GroupFollow,
      on: f.group_id == g.id and f.profile_id == ^profile_id,
      where: not g.is_root,
      order_by: [asc: fragment("lower(?)", g.name), asc: g.id],
      select: {g, f.push}
    )
    |> Repo.all()
  end

  ## Sending

  @doc "Whether the holder of `access` sends notices from `group`."
  def can_send?(%Access{} = access, %Group{} = group),
    do: followable?(group) and Access.can?(access, :send_notices)

  @doc "Whether `profile` may delete `notice`: its author, or anyone who sends the group's notices."
  def can_delete?(%Profile{id: profile_id}, %Access{} = access, %Group{} = group, notice),
    do: notice.creator_id == profile_id or can_send?(access, group)

  def change_notice(attrs \\ %{}), do: GroupNotice.changeset(%GroupNotice{}, attrs)

  @doc """
  Sends a notice from `group` to its followers. A body that does not pass
  costs no attempt of the group's limit (`RateLimit` `:group_notice`).
  """
  def send_notice(%Profile{} = author, %Group{} = group, %Access{} = access, attrs) do
    changeset =
      GroupNotice.changeset(%GroupNotice{group_id: group.id, creator_id: author.id}, attrs)

    cond do
      not can_send?(access, group) ->
        {:error, :not_allowed}

      not changeset.valid? ->
        {:error, Map.put(changeset, :action, :insert)}

      true ->
        case RateLimit.hit(:group_notice, group.id) do
          :ok -> insert_notice(author, group, changeset)
          {:error, :rate_limited, retry_after} -> {:error, {:rate_limited, retry_after}}
        end
    end
  end

  defp insert_notice(author, group, changeset) do
    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, notice} ->
          {count, receipts} =
            Repo.insert_all(GroupNoticeReceipt, receipts_query(notice, author),
              returning: [:profile_id]
            )

          notice = Repo.update!(Ecto.Changeset.change(notice, recipients_count: count))
          {notice, Enum.map(receipts, & &1.profile_id)}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {notice, recipient_ids}} ->
        # Each follower's page before the group's, so that a page reading the
        # group's notices counts the new one before it reads it.
        Enum.each(recipient_ids, &tell_profile(&1, {:received, &1, notice.id, group.id}))
        tell_group(group.id, {:posted, notice.id})
        notify_followers(notice, group, author)
        {:ok, notice}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Every follower who may see the group now, except the author.
  defp receipts_query(%GroupNotice{id: notice_id, group_id: group_id}, %Profile{id: author_id}) do
    from(f in GroupFollow,
      as: :follow,
      join: g in Group,
      on: g.id == f.group_id,
      where: f.group_id == ^group_id and f.profile_id != ^author_id,
      where:
        g.is_public or
          exists(
            from(m in GroupMembership,
              where:
                m.group_id == parent_as(:follow).group_id and
                  m.profile_id == parent_as(:follow).profile_id
            )
          ),
      select: %{profile_id: f.profile_id, notice_id: type(^notice_id, :id)}
    )
  end

  defp notify_followers(%GroupNotice{} = notice, %Group{} = group, %Profile{} = author) do
    payload_for = Notifications.notice(group, notice)

    Dispatch.run(fn ->
      notice
      |> push_account_ids(author)
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_localized("group notice", notice.id, payload_for)
    end)
  end

  # The accounts of the followers it reached whose follow and profile both
  # allow a push, without the accounts of its author's profile.
  defp push_account_ids(%GroupNotice{id: notice_id, group_id: group_id}, %Profile{id: author_id}) do
    author_accounts =
      from(ap in AccountProfile, where: ap.profile_id == ^author_id, select: ap.account_id)

    from(r in GroupNoticeReceipt,
      join: f in GroupFollow,
      on: f.profile_id == r.profile_id and f.group_id == ^group_id,
      join: p in Profile,
      on: p.id == r.profile_id,
      join: ap in AccountProfile,
      on: ap.profile_id == r.profile_id,
      where: r.notice_id == ^notice_id and f.push and p.notice_push,
      where: ap.account_id not in subquery(author_accounts),
      select: ap.account_id
    )
  end

  @doc "Deletes a notice for everyone who received it."
  def delete_notice(%Profile{} = profile, %Group{} = group, %Access{} = access, notice_id)
      when is_integer(notice_id) do
    with %GroupNotice{} = notice <- Repo.get_by(GroupNotice, id: notice_id, group_id: group.id),
         true <- can_delete?(profile, access, group, notice) do
      {:ok, receipts} =
        Repo.transaction(fn ->
          {_count, receipts} =
            Repo.delete_all(
              from(r in GroupNoticeReceipt,
                where: r.notice_id == ^notice.id,
                select: {r.profile_id, is_nil(r.read_at)}
              )
            )

          Repo.delete!(notice)
          receipts
        end)

      Enum.each(receipts, fn {profile_id, unread?} ->
        tell_profile(profile_id, {:deleted, profile_id, notice.id, group.id, unread?})
      end)

      tell_group(group.id, {:removed, notice.id})
      {:ok, notice}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_allowed}
    end
  end

  ## Reading

  @doc "A group's notices, newest first, 20 at a time: `%{entries: notices, more?: boolean}`."
  def list_group_notices(%Group{id: group_id}, opts \\ []) do
    from(n in GroupNotice,
      where: n.group_id == ^group_id,
      order_by: [desc: n.id],
      limit: ^(@page_size + 1),
      preload: [:creator]
    )
    |> notices_before(opts[:before_id])
    |> Repo.all()
    |> page()
  end

  @doc "One notice of a group, for a page that heard it was sent."
  def get_group_notice(%Group{id: group_id}, notice_id) do
    from(n in GroupNotice,
      where: n.id == ^notice_id and n.group_id == ^group_id,
      preload: [:creator]
    )
    |> Repo.one()
  end

  defp notices_before(query, nil), do: query
  defp notices_before(query, id), do: where(query, [n], n.id < ^id)

  @doc """
  The notices `profile` received, newest first, 20 at a time, each as
  `%{notice: notice, group: group, unread?: boolean}`.
  """
  def list_received(%Profile{} = profile, opts \\ []) do
    profile
    |> received_query()
    |> limit(^(@page_size + 1))
    |> received_before(opts[:before_id])
    |> Repo.all()
    |> page()
  end

  @doc "One received notice of `profile`, as in `list_received/2`; nil when it has none such."
  def get_received(%Profile{} = profile, notice_id) do
    profile
    |> received_query()
    |> where([r], r.notice_id == ^notice_id)
    |> Repo.one()
  end

  defp received_query(%Profile{id: profile_id}) do
    from(r in GroupNoticeReceipt,
      join: n in assoc(r, :notice),
      join: g in assoc(n, :group),
      where: r.profile_id == ^profile_id,
      order_by: [desc: r.notice_id],
      select: %{notice: n, group: struct(g, ^@group_fields), unread?: is_nil(r.read_at)}
    )
  end

  defp received_before(query, nil), do: query
  defp received_before(query, id), do: where(query, [r], r.notice_id < ^id)

  defp page(rows) do
    {entries, rest} = Enum.split(rows, @page_size)
    %{entries: entries, more?: rest != []}
  end

  ## Unread

  @doc """
  SQL for how many notices the profile in `param` (such as `"$1"`) has not
  read, at most 1,000. `Social.nav_counts/2` takes it into the badges' query,
  so the badge and a recount always count the same.
  """
  def unread_count_sql(param) do
    "(SELECT count(*) FROM (SELECT 1 FROM group_notice_receipts " <>
      "WHERE profile_id = #{param} AND read_at IS NULL LIMIT #{@unread_cap}) unread_notices)"
  end

  @doc "SQL for the newest notices' ids, for what a count holds (`PotokIde.CountMark`)."
  def notice_mark_sql, do: CountMark.ids_sql("group_notices")

  @doc "The unread count, and the notices it already holds (`as_of`, a `PotokIde.CountMark`)."
  def unread_snapshot(%Profile{id: profile_id}) do
    %{rows: [[count, ids]]} =
      Repo.query!("SELECT #{unread_count_sql("$1")}, #{notice_mark_sql()}", [profile_id])

    %{count: count, as_of: CountMark.from_ids(ids)}
  end

  @doc "Reads every notice of `profile`; returns how many were unread."
  def mark_all_read(%Profile{id: profile_id}) do
    from(r in GroupNoticeReceipt, where: r.profile_id == ^profile_id and is_nil(r.read_at))
    |> mark(profile_id)
  end

  @doc "Reads the notices `profile` received from `group`."
  def mark_group_read(%Profile{id: profile_id}, %Group{id: group_id}) do
    from(r in GroupNoticeReceipt,
      join: n in assoc(r, :notice),
      where: r.profile_id == ^profile_id and is_nil(r.read_at) and n.group_id == ^group_id
    )
    |> mark(profile_id)
  end

  @doc "Reads one notice of `profile`."
  def mark_read(%Profile{id: profile_id}, notice_id) when is_integer(notice_id) do
    from(r in GroupNoticeReceipt,
      where: r.profile_id == ^profile_id and r.notice_id == ^notice_id and is_nil(r.read_at)
    )
    |> mark(profile_id)
  end

  defp mark(query, profile_id) do
    {count, _} = Repo.update_all(query, set: [read_at: DateTime.utc_now(:second)])
    if count > 0, do: tell_profile(profile_id, {:read, profile_id})
    count
  end

  ## The profile's switch

  @doc "Turns the push of every notice `profile` receives on or off; its follows keep their own."
  def set_notice_push(%Profile{id: profile_id} = profile, on?) when is_boolean(on?) do
    Repo.update_all(from(p in Profile, where: p.id == ^profile_id), set: [notice_push: on?])
    tell_profile(profile_id, {:push_changed, profile_id, on?})
    {:ok, %{profile | notice_push: on?}}
  end
end
