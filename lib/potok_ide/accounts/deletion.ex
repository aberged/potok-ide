defmodule PotokIde.Accounts.Deletion do
  @moduledoc """
  Deletes an account, as its person asks in the settings or on the public page
  `/brisanje-naloga`.

  What the person wrote stays in the groups, under a profile that keeps no
  trace of them:

    * A profile only this account used becomes a deleted one (`kind:
      :deleted`): its name becomes `obrisan-<id>`, its picture, description
      and details (`PotokIde.Social.ProfileField`) go, and wherever people are listed, mentioned or invited it is left out,
      as a process's profile is. Its messages, files, polls, events and notices
      stay and show "Obrisan korisnik".
    * A profile other accounts use as well stays as it is for them; only this
      account's link to it goes.

  For a deleted profile:

    * deleted: its memberships and roles (direct conversations aside, so the
      other side still sees whom it talked to), read markers, follows, notice
      receipts, pinned groups, reactions, answers to events and their
      settings, the tags it owns and those put on it, invitations it sent or
      got, join requests, account invitations it sent (they hold the
      addresses of people who never signed up), blocks of it in groups, the
      profiles it blocked and the blocks of it by others
      (`PotokIde.Social.ProfileBlocks`), the messages it reported
      (`PotokIde.Social.ValueReports`), the hidden
      values that ask an app for pushes, the personal memory of apps
      (`PotokIde.Social.AppProfileStore`), the messages it scheduled with
      their files (`PotokIde.Social.ScheduledValues`), and the history of its
      reactions (`PotokIde.History`);
    * emptied: who added a tag, who blocked someone, who dismissed a report,
      who invited an account,
      the old versions of the records it wrote into apps;
    * kept: values (an app's and "anonymous" ones too), files, polls and
      ballots (the ballot loses only its account, so no count changes),
      events, notices, shortcuts, descriptions, groups it made, processes it
      owns or started, approvals it gave, and in the history of a group that
      it changed something there.

  A group never loses its last admin, so a group where a deleted profile is
  the only admin who is a person, with other people in it or with sub-groups,
  blocks the deletion until the admin is handed over (`preview/1` names them).
  A group where it is the only person and an admin goes with the account, with
  its files, when all its sub-groups go too; threads never do, as other people
  read them.

  The account goes last, and its sessions, sign-in links and devices with it.
  """

  import Ecto.Query

  require Logger

  alias PotokIde.Accounts.{Account, AccountToken}
  alias PotokIde.History
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccountProfile, Group, GroupRole, Profile, ScheduledValues}
  alias PotokIde.Storage

  # How long an account someone invited by email waits for its person before
  # `purge_unclaimed/0` deletes it, when nothing invites it any more.
  @unclaimed_days 90

  @type preview :: %{
          tombstones: [Profile.t()],
          kept_shared: [Profile.t()],
          blocking: [Group.t()],
          deleted_groups: [Group.t()]
        }

  def unclaimed_days, do: @unclaimed_days

  @doc """
  What deleting the account would do: the profiles that become deleted ones,
  those that stay for other accounts, the groups that block it and the groups
  that go with it.
  """
  @spec preview(Account.t()) :: preview()
  def preview(%Account{} = account) do
    {tombstones, kept_shared} = profiles(account)
    {blocking, deleted_groups} = groups(Enum.map(tombstones, & &1.id))

    %{
      tombstones: tombstones,
      kept_shared: kept_shared,
      blocking: blocking,
      deleted_groups: deleted_groups
    }
  end

  @doc """
  Deletes the account. Returns `{:ok, %{email: email, tokens: tokens}}`, with
  the tokens whose sessions the caller disconnects, or `{:error, {:blocked,
  groups}}` while a group would lose its last admin.
  """
  @spec delete(Account.t()) ::
          {:ok, %{email: String.t(), tokens: [AccountToken.t()]}}
          | {:error, {:blocked, [Group.t()]}}
          | {:error, :not_found}
  def delete(%Account{} = account) do
    preview = preview(account)

    if preview.blocking != [] do
      {:error, {:blocked, preview.blocking}}
    else
      ids = Enum.map(preview.tombstones, & &1.id)
      # The account leaves no history of its own going.
      Enum.each(leaves_first(preview.deleted_groups), &Social.remove_group(&1, off: true))

      History.off(fn -> delete_now(account, ids) end)
      |> case do
        {:ok, {email, tokens, touched, storage_keys}} ->
          Storage.delete_later(storage_keys)
          after_commit(ids, touched)
          {:ok, %{email: email, tokens: tokens}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes the accounts someone opened by inviting an address whose person
  never came: unconfirmed, with no profile, and with nothing that invited them
  (no invitation to a group, no link sent) in the last #{@unclaimed_days} days.
  Returns how many went. The hourly sweep calls it.
  """
  def purge_unclaimed do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@unclaimed_days, :day)

    {count, _} =
      from(a in Account,
        as: :account,
        where: is_nil(a.confirmed_at) and a.inserted_at < ^cutoff,
        where:
          not exists(from(ap in AccountProfile, where: ap.account_id == parent_as(:account).id)),
        where:
          not exists(
            from(i in "group_account_invitations",
              where: i.account_id == parent_as(:account).id and i.inserted_at >= ^cutoff,
              select: 1
            )
          ),
        where:
          not exists(
            from(t in AccountToken,
              where: t.account_id == parent_as(:account).id and t.inserted_at >= ^cutoff
            )
          )
      )
      |> Repo.delete_all()

    count
  end

  ## Profiles

  # The person profiles of the account: those only it uses, and those it shares.
  defp profiles(%Account{id: account_id}) do
    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id and ap.account_id == ^account_id,
      where: p.kind == :person,
      select:
        {p, fragment("(SELECT count(*) FROM accounts_profiles o WHERE o.profile_id = ?)", p.id)},
      order_by: p.id
    )
    |> Repo.all()
    |> Enum.split_with(fn {_profile, accounts} -> accounts <= 1 end)
    |> then(fn {only, shared} ->
      {Enum.map(only, &elem(&1, 0)), Enum.map(shared, &elem(&1, 0))}
    end)
  end

  ## Groups

  # `{blocking, deleted}` for the profiles that become deleted ones.
  defp groups([]), do: {[], []}

  defp groups(ids) do
    rows = group_rows(ids)

    candidates =
      for row <- rows, row.admin and not row.others and not row.root, into: %{}, do: {row.id, row}

    children = children(Map.keys(candidates))
    deleted = closed(candidates, children)

    blocking =
      for row <- rows, row.admin and not row.other_admin and not Map.has_key?(deleted, row.id) do
        row
      end

    {to_groups(blocking), deleted |> Map.values() |> to_groups()}
  end

  # The groups the profiles are members of, threads and direct conversations
  # aside: whether they hold its admin role, whether another person does, and
  # whether other people are in it.
  defp group_rows(ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT g.id, g.parent_id, g.is_root,
          EXISTS (SELECT 1 FROM group_member_roles r
                  WHERE r.group_id = g.id AND r.role_key = $2 AND r.profile_id = ANY($1)),
          EXISTS (SELECT 1 FROM group_member_roles r JOIN profiles p ON p.id = r.profile_id
                  WHERE r.group_id = g.id AND r.role_key = $2 AND p.kind = 'person'
                    AND NOT r.profile_id = ANY($1)),
          EXISTS (SELECT 1 FROM group_memberships m JOIN profiles p ON p.id = m.profile_id
                  WHERE m.group_id = g.id AND p.kind = 'person' AND NOT m.profile_id = ANY($1))
        FROM groups g
        WHERE NOT g.is_direct AND g.parent_value_id IS NULL
          AND EXISTS (SELECT 1 FROM group_memberships m
                      WHERE m.group_id = g.id AND m.profile_id = ANY($1))
        ORDER BY g.id
        """,
        [ids, GroupRole.admin_key()]
      )

    for [id, parent_id, root, admin, other_admin, others] <- rows do
      %{
        id: id,
        parent_id: parent_id,
        root: root,
        admin: admin,
        other_admin: other_admin,
        others: others
      }
    end
  end

  defp children([]), do: %{}

  defp children(parent_ids) do
    from(g in Group, where: g.parent_id in ^parent_ids, select: {g.parent_id, g.id})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The candidates whose sub-groups all go too, again until none drops out.
  defp closed(candidates, children) do
    kept =
      Map.filter(candidates, fn {id, _row} ->
        Enum.all?(Map.get(children, id, []), &Map.has_key?(candidates, &1))
      end)

    if map_size(kept) == map_size(candidates), do: kept, else: closed(kept, children)
  end

  defp to_groups([]), do: []

  defp to_groups(rows) do
    ids = Enum.map(rows, & &1.id)
    from(g in Group, where: g.id in ^ids, order_by: g.name) |> Repo.all()
  end

  # Sub-groups before their parents, as a group with sub-groups is never deleted.
  defp leaves_first(groups) do
    by_id = Map.new(groups, &{&1.id, &1})
    depth = fn group -> depth(group, by_id, 0) end
    Enum.sort_by(groups, depth, :desc)
  end

  defp depth(%Group{parent_id: parent_id}, by_id, n) do
    case Map.get(by_id, parent_id) do
      nil -> n
      parent -> depth(parent, by_id, n + 1)
    end
  end

  ## The deletion

  defp delete_now(%Account{id: account_id}, ids) do
    account =
      Repo.one(from(a in Account, where: a.id == ^account_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:not_found)

    # Somebody may have left or joined since the preview.
    case groups(ids) do
      {[], _deleted} -> :ok
      {blocking, _deleted} -> Repo.rollback({:blocked, blocking})
    end

    tokens = Repo.all(from(t in AccountToken, where: t.account_id == ^account_id))
    storage_keys = ScheduledValues.forget_profiles(ids)
    touched = forget_profiles(ids)

    Repo.delete!(account)
    {account.email, tokens, touched, storage_keys}
  end

  # Applies the rules of the moduledoc to the profiles. Returns the groups whose
  # members changed.
  defp forget_profiles([]), do: []

  defp forget_profiles(ids) do
    # While the profiles are still people, so the groups count one member less.
    {_, touched} =
      from(m in "group_memberships",
        join: g in Group,
        on: g.id == m.group_id,
        where: m.profile_id in type(^ids, {:array, :integer}) and not g.is_direct,
        select: m.group_id
      )
      |> Repo.delete_all()

    rename_direct_groups(ids)

    for {table, column} <- [
          {"group_value_reads", :profile_id},
          {"group_follows", :profile_id},
          {"group_notice_receipts", :profile_id},
          {"pinned_groups", :profile_id},
          {"value_reactions", :profile_id},
          {"group_reactions", :profile_id},
          {"group_event_responses", :profile_id},
          {"group_event_member_settings", :profile_id},
          {"tags", :owner_id},
          {"taggings", :profile_id},
          {"group_invitations", :inviter_id},
          {"group_invitations", :invitee_id},
          {"profile_invitations", :profile_id},
          {"profile_invitations", :inviter_id},
          {"profile_invitations", :invitee_id},
          {"group_join_requests", :requester_id},
          {"group_join_request_approvals", :requester_id},
          {"group_role_requests", :profile_id},
          {"group_request_decisions", :profile_id},
          {"group_account_invitations", :inviter_id},
          {"group_blocks", :profile_id},
          {"profile_blocks", :blocker_id},
          {"profile_blocks", :blocked_id},
          {"value_reports", :reporter_id},
          {"app_profile_entries", :profile_id},
          {"profile_fields", :profile_id}
        ] do
      from(r in table, where: field(r, ^column) in type(^ids, {:array, :integer}))
      |> Repo.delete_all()
    end

    History.forget_profiles(ids)

    from(v in "values",
      where: v.collection == "notify" and v.creator_id in type(^ids, {:array, :integer})
    )
    |> Repo.delete_all()

    for {table, column} <- [
          {"taggings", :added_by_id},
          {"group_blocks", :blocked_by_id},
          {"value_reports", :dismissed_by_id},
          {"accounts", :invited_by_id}
        ] do
      from(r in table, where: field(r, ^column) in type(^ids, {:array, :integer}))
      |> Repo.update_all(set: [{column, nil}])
    end

    now = DateTime.utc_now(:second)

    for id <- ids do
      from(p in Profile, where: p.id == ^id)
      |> Repo.update_all(
        set: [
          kind: :deleted,
          username: deleted_username(id),
          profile_picture_url: nil,
          description: "",
          description_audience: :only_me,
          description_group_ids: [],
          sharing: :unique,
          notice_push: false,
          updated_at: now
        ]
      )
    end

    Enum.uniq(touched)
  end

  # The name nobody may pick (`Profile.changeset/2`), unless an account made
  # before that rule holds it.
  defp deleted_username(id) do
    name = Profile.deleted_username(id)

    if Repo.exists?(from(p in Profile, where: p.username == ^name and p.id != ^id)),
      do: name <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(3)),
      else: name
  end

  # A direct conversation is named after its two sides, so the old name of the
  # deleted side goes from it as well.
  defp rename_direct_groups(ids) do
    from(g in Group,
      join: m in "group_memberships",
      on: m.group_id == g.id and m.profile_id in type(^ids, {:array, :integer}),
      join: om in "group_memberships",
      on: om.group_id == g.id and om.profile_id not in type(^ids, {:array, :integer}),
      join: other in Profile,
      on: other.id == om.profile_id,
      where: g.is_direct,
      select: {g.id, m.profile_id, other.username}
    )
    |> Repo.all()
    |> Enum.each(fn {group_id, profile_id, other_name} ->
      name = Enum.join(Enum.sort([other_name, Profile.deleted_username(profile_id)]), " & ")
      from(g in Group, where: g.id == ^group_id) |> Repo.update_all(set: [name: name])
    end)
  end

  defp after_commit(ids, touched) do
    Access.forget(touched)

    for group_id <- touched, profile_id <- ids do
      Social.broadcast_group_members_changed(group_id, [:members], profile_id: profile_id)
    end
  rescue
    error ->
      Logger.warning("After deleting an account: " <> Exception.message(error))
  end
end
