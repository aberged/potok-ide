defmodule PotokIde.Social do
  @moduledoc """
  Social domain context.

  Owns Profiles, Groups, Values, and the relationships between them.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias PotokIde.Presence
  alias PotokIde.Repo

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account

  alias PotokIde.Social.{
    AccountProfile,
    Group,
    GroupInvitation,
    GroupMembership,
    Profile,
    ProfileInvitation,
    Value
  }

  def subscribe_account(%Account{id: account_id}) when is_integer(account_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, account_topic(account_id))
  end

  def subscribe_profile(%Profile{id: profile_id}) when is_integer(profile_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, profile_topic(profile_id))
  end

  def unsubscribe_profile(%Profile{id: profile_id}) when is_integer(profile_id) do
    Phoenix.PubSub.unsubscribe(PotokIde.PubSub, profile_topic(profile_id))
  end

  def subscribe_group(%Group{id: group_id}) when is_integer(group_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, group_topic(group_id))
  end

  def subscribe_group_presence(%Group{id: group_id}) when is_integer(group_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, group_presence_topic(group_id))
  end

  def track_group_presence(pid, %Group{} = group, %Profile{} = profile) when is_pid(pid) do
    Presence.track(pid, group_presence_topic(group), Integer.to_string(profile.id), %{
      profile_id: profile.id,
      username: profile.username,
      online_at: System.system_time(:second)
    })
  end

  def untrack_group_presence(pid, %Group{} = group, %Profile{id: profile_id}) when is_pid(pid) do
    untrack_group_presence(pid, group, profile_id)
  end

  def untrack_group_presence(pid, %Group{} = group, profile_id)
      when is_pid(pid) and is_integer(profile_id) do
    Presence.untrack(pid, group_presence_topic(group), Integer.to_string(profile_id))
  end

  def list_online_profile_ids_for_group(%Group{} = group) do
    group
    |> group_presence_topic()
    |> Presence.list()
    |> Map.keys()
    |> Enum.reduce(MapSet.new(), fn key, acc ->
      case Integer.parse(key) do
        {profile_id, ""} -> MapSet.put(acc, profile_id)
        _ -> acc
      end
    end)
  end

  # ---------
  # Root group
  # ---------

  def get_root_group! do
    Repo.get_by!(Group, is_root: true)
  end

  # ---------
  # Profiles
  # ---------

  def get_profile!(id), do: Repo.get!(Profile, id)

  def create_profile(attrs) do
    root_group = get_root_group!()

    Multi.new()
    |> Multi.insert(:profile, Profile.changeset(%Profile{}, attrs))
    |> Multi.insert(:root_membership, fn %{profile: profile} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: root_group.id,
        profile_id: profile.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def create_profile_for_account(%Account{} = account, attrs) do
    root_group = get_root_group!()

    Multi.new()
    |> Multi.insert(:profile, Profile.changeset(%Profile{}, attrs))
    |> Multi.insert(:account_profile, fn %{profile: profile} ->
      AccountProfile.changeset(%AccountProfile{}, %{
        account_id: account.id,
        profile_id: profile.id
      })
    end)
    |> Multi.insert(:root_membership, fn %{profile: profile} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: root_group.id,
        profile_id: profile.id
      })
    end)
    |> Multi.run(:set_current_profile, fn repo, %{profile: profile} ->
      if account.current_profile_id do
        {:ok, account}
      else
        account
        |> Ecto.Changeset.change(current_profile_id: profile.id)
        |> repo.update()
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: profile, set_current_profile: updated_account}} ->
        broadcast_account_profiles_updated(updated_account)
        {:ok, profile}

      {:ok, %{profile: profile}} ->
        broadcast_account_profiles_updated(account)
        {:ok, profile}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def update_profile_for_account(%Account{} = account, profile_id, attrs)
      when is_integer(profile_id) do
    case get_profile_for_account(account, profile_id) do
      nil ->
        {:error, :not_found}

      profile ->
        profile
        |> Profile.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated_profile} = ok ->
            broadcast_account_profiles_updated(account)
            broadcast_profile_updated(updated_profile)
            ok

          error ->
            error
        end
    end
  end

  def add_profile_to_account(%Profile{} = profile, %Account{} = account) do
    case link_profile_to_account(Repo, profile, account) do
      {:ok, %AccountProfile{}} = ok ->
        broadcast_account_profiles_updated(account)
        ok

      other ->
        other
    end
  end

  def invite_profile_to_profile(
        %Account{} = inviter_account,
        %Profile{} = inviter,
        %Profile{} = profile,
        %Profile{} = invitee
      ) do
    cond do
      profile.sharing != :shared ->
        {:error, :profile_not_shared}

      is_nil(get_profile_for_account(inviter_account, profile.id)) ->
        {:error, :inviter_not_linked}

      inviter.id == invitee.id ->
        {:error, :cannot_invite_self}

      true ->
        %ProfileInvitation{}
        |> ProfileInvitation.changeset(%{
          profile_id: profile.id,
          inviter_id: inviter.id,
          invitee_id: invitee.id
        })
        |> Repo.insert()
        |> case do
          {:ok, _invitation} = ok ->
            broadcast_profile_share_invitations_updated(invitee)
            broadcast_pending_invitations_count_updated(invitee)
            notify_profile_invitee_of_shared_profile_invitation(inviter, profile, invitee)
            ok

          error ->
            error
        end
    end
  end

  def accept_profile_invitation(
        %ProfileInvitation{} = invitation,
        %Profile{} = invitee,
        %Account{} = invitee_account
      ) do
    invitation = Repo.preload(invitation, [:profile, :inviter])

    if invitation.invitee_id != invitee.id do
      {:error, :invitee_mismatch}
    else
      Multi.new()
      |> Multi.update(:invitation, ProfileInvitation.accept_changeset(invitation))
      |> Multi.run(:account_profile, fn repo, _changes ->
        link_profile_to_account(repo, invitation.profile, invitee_account)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: accepted_invitation}} ->
          broadcast_profile_share_invitations_updated(invitee)
          broadcast_pending_invitations_count_updated(invitee)
          broadcast_account_profiles_updated(invitee_account)

          notify_profile_inviter_of_shared_profile_acceptance(
            invitation,
            invitee,
            invitee_account
          )

          {:ok, accepted_invitation}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # ---------
  # Groups
  # ---------

  def get_group!(id), do: Repo.get!(Group, id)

  def create_group(%Profile{} = creator, %Group{} = parent, attrs) do
    if not member_of_group?(creator, parent) do
      {:error, :not_a_member_of_parent_group}
    else
      attrs =
        attrs
        |> Map.new()
        |> Map.put_new("creator_id", creator.id)
        |> Map.put_new("parent_id", parent.id)
        |> Map.put_new("is_root", false)

      Multi.new()
      |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
      |> Multi.insert(:membership, fn %{group: group} ->
        GroupMembership.changeset(%GroupMembership{}, %{
          group_id: group.id,
          profile_id: creator.id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{group: group}} ->
          broadcast_group_updated(parent)
          {:ok, group}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def update_group(%Profile{} = editor, %Group{} = group, attrs) do
    if not member_of_group?(editor, group) do
      {:error, :not_a_group_member}
    else
      group
      |> Group.update_changeset(Map.new(attrs))
      |> Repo.update()
      |> case do
        {:ok, updated_group} ->
          broadcast_group_updated(updated_group)

          if updated_group.parent_id do
            broadcast_group_updated(updated_group.parent_id)
          end

          {:ok, updated_group}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def invite_profile_to_group(%Profile{} = inviter, %Group{} = group, %Profile{} = invitee) do
    cond do
      not member_of_group?(inviter, group) ->
        {:error, :inviter_not_a_member}

      inviter.id == invitee.id ->
        {:error, :cannot_invite_self}

      true ->
        %GroupInvitation{}
        |> GroupInvitation.changeset(%{
          group_id: group.id,
          inviter_id: inviter.id,
          invitee_id: invitee.id
        })
        |> Repo.insert()
        |> case do
          {:ok, _invitation} = ok ->
            broadcast_profile_invitations_updated(invitee)
            broadcast_pending_invitations_count_updated(invitee)
            notify_profile_invitee_of_group_invitation(inviter, group, invitee)
            ok

          error ->
            error
        end
    end
  end

  def accept_group_invitation(%GroupInvitation{} = invitation, %Profile{} = invitee) do
    invitation = Repo.preload(invitation, [:group, :inviter])

    if invitation.invitee_id != invitee.id do
      {:error, :invitee_mismatch}
    else
      Multi.new()
      |> Multi.update(:invitation, GroupInvitation.accept_changeset(invitation))
      |> Multi.insert(:membership, fn %{invitation: inv} ->
        GroupMembership.changeset(%GroupMembership{}, %{
          group_id: inv.group_id,
          profile_id: inv.invitee_id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: inv}} ->
          broadcast_profile_invitations_updated(invitee)
          broadcast_pending_invitations_count_updated(invitee)
          broadcast_group_updated(inv.group_id)
          broadcast_profile_group_unread_counts_updated(invitee, inv.group_id)
          notify_profile_inviter_of_group_invitation_acceptance(invitation, invitee)
          {:ok, inv}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # ---------
  # Values
  # ---------

  def get_value!(id), do: Repo.get!(Value, id)

  def create_value(%Profile{} = creator, %Group{} = group, attrs) do
    if not member_of_group?(creator, group) do
      {:error, :not_a_member_of_group}
    else
      attrs =
        attrs
        |> Map.new()
        |> Map.put_new("creator_id", creator.id)
        |> Map.put_new("group_id", group.id)

      Multi.new()
      |> Multi.insert(:value, Value.changeset(%Value{}, attrs))
      |> Multi.run(:mark_creator_read, fn repo, %{value: value} ->
        upsert_group_value_read(repo, creator.id, group.id, value.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{value: value}} ->
          broadcast_group_updated(group)
          broadcast_group_unread_counts_updated(group)
          notify_group_members_of_new_value(creator, group, value)
          {:ok, value}

        error ->
          error
      end
    end
  end

  def update_value(%Profile{} = profile, %Value{} = value, attrs) do
    if value.creator_id != profile.id do
      {:error, :not_value_creator}
    else
      value
      |> Value.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated_value} = ok ->
          broadcast_group_updated(updated_value.group_id)
          ok

        error ->
          error
      end
    end
  end

  def delete_value(%Profile{} = profile, %Value{} = value) do
    if value.creator_id != profile.id do
      {:error, :not_value_creator}
    else
      Repo.delete(value)
      |> case do
        {:ok, deleted_value} = ok ->
          broadcast_group_updated(deleted_value.group_id)
          broadcast_group_unread_counts_updated(deleted_value.group_id)
          ok

        error ->
          error
      end
    end
  end

  # ---------
  # Queries
  # ---------

  def list_profiles_for_account(%Account{} = account) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: ap.account_id == ^account.id,
      order_by: [asc: p.username]
    )
    |> Repo.all()
  end

  def get_profile_by_username(username) when is_binary(username) do
    Repo.get_by(Profile, username: username)
  end

  def get_account_current_profile(%Account{} = account) do
    import Ecto.Query, only: [from: 2]

    case account.current_profile_id do
      nil ->
        nil

      profile_id ->
        from(p in Profile,
          join: ap in AccountProfile,
          on: ap.profile_id == p.id,
          where: p.id == ^profile_id and ap.account_id == ^account.id,
          select: p
        )
        |> Repo.one()
    end
  end

  def list_child_groups(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(g in Group, where: g.parent_id == ^group.id, order_by: [asc: g.name])
    |> Repo.all()
  end

  def list_group_path(%Group{} = group) do
    do_list_group_path(group, [])
  end

  def list_visible_group_path_for_profile(%Group{} = group, nil), do: [group]

  def list_visible_group_path_for_profile(%Group{} = group, %Profile{} = profile) do
    list_group_path(group)
    |> Enum.filter(fn path_group ->
      path_group.id == group.id or path_group.is_public or member_of_group?(profile, path_group)
    end)
  end

  def list_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(g in Group,
      join: gm in GroupMembership,
      on: gm.group_id == g.id,
      where: g.parent_id == ^group.id and (gm.profile_id == ^profile.id or g.is_public == true),
      order_by: [asc: g.name],
      distinct: g.id
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def count_child_groups_for_profile(%Group{} = group, %Profile{} = profile) do
    import Ecto.Query, only: [from: 2]

    from(g in Group,
      join: gm in GroupMembership,
      on: gm.group_id == g.id,
      where: g.parent_id == ^group.id and (gm.profile_id == ^profile.id or g.is_public == true),
      select: count(g.id, :distinct)
    )
    |> Repo.one()
  end

  def list_group_members(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id,
      order_by: [asc: p.username]
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def count_group_members(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(gm in GroupMembership,
      where: gm.group_id == ^group.id,
      select: count(gm.profile_id)
    )
    |> Repo.one()
  end

  def list_first3_group_members(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id,
      limit: 3
    )
    |> Repo.all()
  end

  def list_group_values(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id,
      order_by: [asc: v.inserted_at, asc: v.id],
      preload: [:creator, :parent]
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def count_group_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id,
      select: count(v.id)
    )
    |> Repo.one()
  end

  def mark_group_values_read(nil, _group), do: :ok

  def mark_group_values_read(%Profile{} = profile, %Group{} = group) do
    case latest_group_value_id(group) do
      nil ->
        :ok

      latest_value_id ->
        case upsert_group_value_read(Repo, profile.id, group.id, latest_value_id) do
          {:ok, _last_read_value_id} ->
            broadcast_profile_group_unread_counts_updated(profile, group.id)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_group_unread_counts(nil, _groups), do: %{}

  def list_group_unread_counts(%Profile{} = profile, groups) when is_list(groups) do
    group_ids =
      groups
      |> Enum.map(&extract_group_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case group_ids do
      [] -> %{}
      _ -> unread_counts_query(profile.id, group_ids)
    end
  end

  def count_group_unread_values(%Profile{} = profile, %Group{} = group) do
    profile
    |> list_group_unread_counts([group])
    |> Map.get(group.id, 0)
  end

  def list_pending_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id,
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at
      ],
      preload: [:group, :inviter]
    )
    |> Repo.all()
  end

  def count_pending_invitations(%Profile{} = invitee) do
    count_pending_group_invitations(invitee) + count_pending_profile_invitations(invitee)
  end

  defp do_list_group_path(%Group{parent_id: nil} = group, acc), do: [group | acc]

  defp do_list_group_path(%Group{parent_id: parent_id} = group, acc) when is_integer(parent_id) do
    parent = get_group!(parent_id)
    do_list_group_path(parent, [group | acc])
  end

  defp count_pending_group_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      select: count(i.id)
    )
    |> Repo.one()
  end

  defp count_pending_profile_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in ProfileInvitation,
      where: i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def list_pending_profile_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in ProfileInvitation,
      where: i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      order_by: [desc: i.inserted_at],
      preload: [:profile, :inviter]
    )
    |> Repo.all()
  end

  def get_pending_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      preload: [:group, :inviter]
    )
    |> Repo.one()
  end

  def get_pending_profile_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in ProfileInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      preload: [:profile, :inviter]
    )
    |> Repo.one()
  end

  def get_profile_for_account(%Account{} = account, profile_id) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: p.id == ^profile_id and ap.account_id == ^account.id,
      select: p
    )
    |> Repo.one()
  end

  def member_of_group?(%Profile{} = profile, %Group{} = group),
    do: member_of_group_private?(profile, group)

  defp member_of_group_private?(%Profile{} = profile, %Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(gm in GroupMembership,
      where: gm.group_id == ^group.id and gm.profile_id == ^profile.id,
      select: 1
    )
    |> Repo.exists?()
  end

  defp maybe_paginate(query, opts) do
    query
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
  end

  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0 do
    limit(query, ^limit)
  end

  defp maybe_limit(query, _limit), do: query

  defp maybe_offset(query, offset) when is_integer(offset) and offset >= 0 do
    offset(query, ^offset)
  end

  defp maybe_offset(query, _offset), do: query

  defp notify_group_members_of_new_value(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    payload = group_value_notification_payload(creator, group, value)

    group
    |> recipient_accounts_for_group_value_notification(creator)
    |> Enum.each(fn account ->
      case Accounts.deliver_push_notification(account, payload) do
        {:ok, _results} ->
          :ok

        {:error, :no_push_subscriptions} ->
          :ok
      end
    end)
  end

  defp notify_profile_invitee_of_group_invitation(
         %Profile{} = inviter,
         %Group{} = group,
         %Profile{} = invitee
       ) do
    payload = group_invitation_notification_payload(inviter, group)

    invitee
    |> recipient_accounts_for_profile_notification()
    |> Enum.each(&deliver_profile_notification(&1, payload, "group invitation", inviter.id))
  end

  defp notify_profile_inviter_of_group_invitation_acceptance(
         %GroupInvitation{} = invitation,
         %Profile{} = invitee
       ) do
    payload = group_invitation_accepted_notification_payload(invitation.group, invitee)

    invitation.inviter
    |> recipient_accounts_for_profile_notification()
    |> Enum.each(
      &deliver_profile_notification(&1, payload, "group invitation acceptance", invitee.id)
    )
  end

  defp notify_profile_invitee_of_shared_profile_invitation(
         %Profile{} = inviter,
         %Profile{} = shared_profile,
         %Profile{} = invitee
       ) do
    payload = shared_profile_invitation_notification_payload(inviter, shared_profile)

    invitee
    |> recipient_accounts_for_profile_notification()
    |> Enum.each(
      &deliver_profile_notification(&1, payload, "shared profile invitation", inviter.id)
    )
  end

  defp notify_profile_inviter_of_shared_profile_acceptance(
         %ProfileInvitation{} = invitation,
         %Profile{} = invitee,
         %Account{} = invitee_account
       ) do
    payload = shared_profile_invitation_accepted_notification_payload(invitation.profile, invitee)

    invitation.inviter
    |> recipient_accounts_for_profile_notification([invitee_account.id])
    |> Enum.each(
      &deliver_profile_notification(
        &1,
        payload,
        "shared profile invitation acceptance",
        invitee.id
      )
    )
  end

  defp recipient_accounts_for_group_value_notification(%Group{} = group, %Profile{} = creator) do
    from(account in Account,
      join: ap in AccountProfile,
      on: ap.account_id == account.id,
      join: gm in GroupMembership,
      on: gm.profile_id == ap.profile_id,
      where: gm.group_id == ^group.id and gm.profile_id != ^creator.id,
      distinct: account.id,
      order_by: [asc: account.id]
    )
    |> Repo.all()
  end

  defp recipient_accounts_for_profile_notification(
         %Profile{} = profile,
         excluded_account_ids \\ []
       ) do
    from(account in Account,
      join: ap in AccountProfile,
      on: ap.account_id == account.id,
      where: ap.profile_id == ^profile.id,
      where: account.id not in ^excluded_account_ids,
      distinct: account.id,
      order_by: [asc: account.id]
    )
    |> Repo.all()
  end

  defp deliver_profile_notification(%Account{} = account, payload, _context, _profile_id) do
    case Accounts.deliver_push_notification(account, payload) do
      {:ok, _results} ->
        :ok

      {:error, :no_push_subscriptions} ->
        :ok
    end
  end

  defp group_value_notification_payload(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    %{
      title: "#{creator.username} added a new value",
      body: group_value_notification_body(group, value),
      tag: "group-#{group.id}-value-created",
      url: "/groups/#{group.id}/values",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp group_invitation_notification_payload(%Profile{} = inviter, %Group{} = group) do
    %{
      title: "#{inviter.username} invited you to #{group.name}",
      body: "Open Potok to review this group invitation.",
      tag: "group-#{group.id}-invitation",
      url: "/invitations",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp group_invitation_accepted_notification_payload(%Group{} = group, %Profile{} = invitee) do
    %{
      title: "#{invitee.username} accepted your invitation",
      body: "#{invitee.username} joined #{group.name}.",
      tag: "group-#{group.id}-invitation-accepted",
      url: "/groups/#{group.id}",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp shared_profile_invitation_notification_payload(
         %Profile{} = inviter,
         %Profile{} = shared_profile
       ) do
    %{
      title: "#{inviter.username} shared #{shared_profile.username}",
      body: "Open Potok to review this shared profile invitation.",
      tag: "profile-#{shared_profile.id}-invitation",
      url: "/profiles",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp shared_profile_invitation_accepted_notification_payload(
         %Profile{} = shared_profile,
         %Profile{} = invitee
       ) do
    %{
      title: "#{invitee.username} accepted your shared profile invitation",
      body: "#{invitee.username} now has access to #{shared_profile.username}.",
      tag: "profile-#{shared_profile.id}-invitation-accepted",
      url: "/profiles",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp group_value_notification_body(%Group{} = group, %Value{} = value) do
    excerpt = notification_excerpt(value.content)

    case excerpt do
      nil ->
        "New value in #{group.name}"

      snippet ->
        "New value in #{group.name}: #{snippet}"
    end
  end

  defp notification_excerpt(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= 120 -> trimmed
      true -> String.slice(trimmed, 0, 117) <> "..."
    end
  end

  defp notification_excerpt(_content), do: nil

  defp extract_group_id(%Group{id: id}), do: id
  defp extract_group_id(id) when is_integer(id), do: id
  defp extract_group_id(_group), do: nil

  defp latest_group_value_id(%Group{} = group) do
    from(v in Value,
      where: v.group_id == ^group.id,
      select: max(v.id)
    )
    |> Repo.one()
  end

  defp unread_counts_query(profile_id, group_ids) do
    sql = """
    WITH RECURSIVE requested AS (
      SELECT UNNEST($2::bigint[]) AS root_id
    ),
    subtree(root_id, group_id) AS (
      SELECT r.root_id, g.id
      FROM requested r
      JOIN groups g ON g.id = r.root_id

      UNION ALL

      SELECT s.root_id, child.id
      FROM subtree s
      JOIN groups child ON child.parent_id = s.group_id
    ),
    counts AS (
      SELECT
        s.root_id,
        COUNT(v.id) FILTER (WHERE v.id > COALESCE(gvr.last_read_value_id, 0))::bigint AS unread_count
      FROM subtree s
      JOIN groups g ON g.id = s.group_id
      JOIN group_memberships gm
        ON gm.group_id = s.group_id AND gm.profile_id = $1
      LEFT JOIN values v ON v.group_id = s.group_id AND g.is_root = FALSE
      LEFT JOIN group_value_reads gvr
        ON gvr.group_id = s.group_id AND gvr.profile_id = $1
      GROUP BY s.root_id
    )
    SELECT r.root_id, COALESCE(c.unread_count, 0)::bigint AS unread_count
    FROM requested r
    LEFT JOIN counts c ON c.root_id = r.root_id
    """

    case Repo.query(sql, [profile_id, group_ids]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [group_id, unread_count] ->
          {group_id, unread_count}
        end)

      {:error, _reason} ->
        Map.new(group_ids, &{&1, 0})
    end
  end

  defp upsert_group_value_read(repo, profile_id, group_id, last_read_value_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    sql = """
    INSERT INTO group_value_reads (profile_id, group_id, last_read_value_id, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (profile_id, group_id)
    DO UPDATE SET
      last_read_value_id = GREATEST(COALESCE(group_value_reads.last_read_value_id, 0), EXCLUDED.last_read_value_id),
      updated_at = EXCLUDED.updated_at
    """

    case repo.query(sql, [profile_id, group_id, last_read_value_id, now, now]) do
      {:ok, _result} -> {:ok, last_read_value_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_topic(account_id), do: "accounts:#{account_id}"
  defp profile_topic(profile_id), do: "profiles:#{profile_id}"
  defp group_topic(group_id), do: "groups:#{group_id}"

  def group_presence_topic(%Group{id: group_id}), do: group_presence_topic(group_id)
  def group_presence_topic(group_id) when is_integer(group_id), do: "groups:#{group_id}:presence"

  defp broadcast_account_profiles_updated(%Account{id: account_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      account_topic(account_id),
      {:account_profiles_updated, account_id}
    )
  end

  defp broadcast_profile_share_invitations_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_share_invitations_updated, profile_id}
    )
  end

  defp broadcast_profile_invitations_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_invitations_updated, profile_id}
    )
  end

  defp broadcast_pending_invitations_count_updated(%Profile{id: profile_id} = profile) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:pending_invitations_count_updated, profile_id, count_pending_invitations(profile)}
    )
  end

  defp broadcast_profile_group_unread_counts_updated(%Profile{id: profile_id}, group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:group_unread_counts_updated, profile_id, group_id}
    )
  end

  defp broadcast_group_unread_counts_updated(%Group{id: group_id}) do
    broadcast_group_unread_counts_updated(group_id)
  end

  defp broadcast_group_unread_counts_updated(group_id) when is_integer(group_id) do
    from(gm in GroupMembership,
      where: gm.group_id == ^group_id,
      select: gm.profile_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.each(fn profile_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        profile_topic(profile_id),
        {:group_unread_counts_updated, profile_id, group_id}
      )
    end)
  end

  defp broadcast_profile_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_updated, profile_id}
    )
  end

  defp broadcast_group_updated(%Group{id: group_id}), do: broadcast_group_updated(group_id)

  defp broadcast_group_updated(group_id) when is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_updated, group_id}
    )
  end

  defp link_profile_to_account(repo, %Profile{} = profile, %Account{} = account) do
    case profile.sharing do
      :shared ->
        if linked_to_account?(repo, profile, account) do
          {:ok, :already_linked}
        else
          repo.insert(
            AccountProfile.changeset(%AccountProfile{}, %{
              account_id: account.id,
              profile_id: profile.id
            })
          )
        end

      :unique ->
        existing_account_ids =
          from(ap in AccountProfile, where: ap.profile_id == ^profile.id, select: ap.account_id)
          |> repo.all()

        cond do
          existing_account_ids == [] ->
            repo.insert(
              AccountProfile.changeset(%AccountProfile{}, %{
                account_id: account.id,
                profile_id: profile.id
              })
            )

          account.id in existing_account_ids ->
            {:ok, :already_linked}

          true ->
            {:error, :profile_is_unique}
        end
    end
  end

  defp linked_to_account?(repo, %Profile{} = profile, %Account{} = account) do
    from(ap in AccountProfile,
      where: ap.profile_id == ^profile.id and ap.account_id == ^account.id,
      select: 1
    )
    |> repo.exists?()
  end
end
