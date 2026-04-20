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
    GroupAccountInvitation,
    GroupInvitation,
    GroupJoinRequest,
    GroupMembership,
    GroupValueRead,
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

  def get_profile(id), do: Repo.get(Profile, id)

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
    |> Multi.run(:account_already_has_profiles, fn repo, _changes ->
      {:ok,
       repo.exists?(
         from(account_profile in AccountProfile,
           where: account_profile.account_id == ^account.id,
           select: 1
         )
       )}
    end)
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
    |> Multi.run(:update_account_profiles, fn repo, %{profile: profile} ->
      changes =
        %{}
        |> maybe_put_profile_reference(
          :current_profile_id,
          account.current_profile_id,
          profile.id
        )
        |> maybe_put_profile_reference(
          :default_profile_id,
          account.default_profile_id,
          profile.id
        )

      if changes == %{} do
        {:ok, account}
      else
        account
        |> Ecto.Changeset.change(changes)
        |> repo.update()
      end
    end)
    |> Multi.run(:initial_direct_group, fn repo,
                                           %{
                                             profile: profile,
                                             account_already_has_profiles: already_has_profiles
                                           } ->
      maybe_create_initial_direct_group(repo, root_group, account, profile, already_has_profiles)
    end)
    |> Repo.transaction()
    |> case do
      {:ok,
       %{
         account_already_has_profiles: already_has_profiles,
         profile: profile,
         update_account_profiles: updated_account,
         initial_direct_group: initial_direct_group
       }} ->
        if match?(%Group{}, initial_direct_group) do
          broadcast_group_updated(root_group)
        end

        broadcast_account_profiles_updated(updated_account)
        materialize_pending_group_account_invitations(account, profile, already_has_profiles)
        {:ok, profile}

      {:ok,
       %{
         account_already_has_profiles: already_has_profiles,
         profile: profile,
         initial_direct_group: initial_direct_group
       }} ->
        if match?(%Group{}, initial_direct_group) do
          broadcast_group_updated(root_group)
        end

        broadcast_account_profiles_updated(account)
        materialize_pending_group_account_invitations(account, profile, already_has_profiles)
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

  def get_group!(id) do
    Group
    |> Repo.get!(id)
    |> maybe_preload_group_members()
  end

  def create_group(%Profile{} = creator, %Group{} = parent, attrs) do
    if not member_of_group?(creator, parent) do
      {:error, :not_a_member_of_parent_group}
    else
      attrs =
        attrs
        |> Map.new()
        |> Map.put_new("creator_id", creator.id)
        |> Map.put_new("parent_id", parent.id)
        |> Map.put_new("is_direct", false)
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

  def get_or_create_direct_group(%Profile{id: profile_id}, %Profile{id: profile_id}) do
    {:error, :same_profile}
  end

  def get_or_create_direct_group(%Profile{} = current_profile, %Profile{} = other_profile) do
    root_group = get_root_group!()

    case find_direct_group(Repo, root_group, current_profile, other_profile) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        attrs = %{
          "name" => direct_group_name(current_profile, other_profile),
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat,
          "has_public_chat" => true,
          "is_direct" => true,
          "is_public" => false,
          "creator_id" => current_profile.id,
          "parent_id" => root_group.id,
          "is_root" => false
        }

        Multi.new()
        |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
        |> Multi.insert(:current_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: current_profile.id
          })
        end)
        |> Multi.insert(:other_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: other_profile.id
          })
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{group: group}} ->
            broadcast_group_updated(root_group)
            {:ok, group}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  def update_group(%Profile{} = editor, %Group{} = group, attrs) do
    if editor.id != group.creator_id do
      {:error, :not_group_creator}
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

  def delete_group(%Profile{} = profile, %Group{} = group) do
    cond do
      group.is_root ->
        {:error, :cannot_delete_root_group}

      not member_of_group?(profile, group) ->
        {:error, :not_a_group_member}

      Repo.exists?(from child in Group, where: child.parent_id == ^group.id, select: 1) ->
        {:error, :group_has_children}

      true ->
        parent_id = group.parent_id

        Repo.delete(group)
        |> case do
          {:ok, deleted_group} = ok ->
            broadcast_group_deleted(deleted_group.id, parent_id)

            if parent_id do
              broadcast_group_updated(parent_id)
            end

            ok

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
        Multi.new()
        |> Multi.insert(
          :invitation,
          GroupInvitation.changeset(%GroupInvitation{}, %{
            group_id: group.id,
            inviter_id: inviter.id,
            invitee_id: invitee.id
          })
        )
        |> Multi.delete_all(
          :join_requests,
          from(r in GroupJoinRequest,
            where: r.group_id == ^group.id and r.requester_id == ^invitee.id
          )
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{invitation: invitation}} ->
            broadcast_profile_invitations_updated(invitee)
            broadcast_pending_invitations_count_updated(invitee)
            broadcast_group_join_request_updates_for_group(group)
            broadcast_group_updated(group)
            notify_profile_invitee_of_group_invitation(inviter, group, invitee)
            {:ok, invitation}

          {:error, :invitation, reason, _changes} ->
            {:error, reason}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  def invite_account_to_group(%Profile{} = inviter, %Group{} = group, %Account{} = account) do
    account = Accounts.get_account!(account.id)

    cond do
      not member_of_group?(inviter, group) ->
        {:error, :inviter_not_a_member}

      profile = get_account_default_profile(account) ->
        case invite_profile_to_group(inviter, group, profile) do
          {:ok, invitation} ->
            ensure_direct_group_between_profiles(profile, inviter)
            {:ok, invitation}

          error ->
            error
        end

      true ->
        %GroupAccountInvitation{}
        |> GroupAccountInvitation.changeset(%{
          group_id: group.id,
          inviter_id: inviter.id,
          account_id: account.id
        })
        |> Repo.insert()
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
      |> Multi.delete_all(
        :join_requests,
        from(r in GroupJoinRequest,
          where: r.group_id == ^invitation.group_id and r.requester_id == ^invitation.invitee_id
        )
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: inv}} ->
          broadcast_profile_invitations_updated(invitee)
          broadcast_pending_invitations_count_updated(invitee)
          broadcast_group_join_request_updates_for_group(invitation.group)
          broadcast_group_updated(inv.group_id)
          broadcast_profile_group_unread_counts_updated(invitee, inv.group_id)
          notify_profile_inviter_of_group_invitation_acceptance(invitation, invitee)
          {:ok, inv}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def remove_group_member(%Profile{} = actor, %Group{} = group, member_profile_id)
      when is_integer(member_profile_id) do
    case Repo.get(Profile, member_profile_id) do
      nil ->
        {:error, :member_not_found}

      member ->
        remove_group_member(actor, group, member)
    end
  end

  def remove_group_member(%Profile{} = actor, %Group{} = group, %Profile{} = member) do
    cond do
      group.is_root ->
        {:error, :cannot_remove_root_group_members}

      actor.id != group.creator_id ->
        {:error, :not_group_creator}

      member.id == group.creator_id ->
        {:error, :cannot_remove_group_creator}

      true ->
        case Repo.get_by(GroupMembership, group_id: group.id, profile_id: member.id) do
          nil ->
            {:error, :not_a_group_member}

          %GroupMembership{} ->
            Multi.new()
            |> Multi.delete_all(
              :membership,
              from(gm in GroupMembership,
                where: gm.group_id == ^group.id and gm.profile_id == ^member.id
              )
            )
            |> Multi.delete_all(
              :group_value_reads,
              from(gvr in GroupValueRead,
                where: gvr.group_id == ^group.id and gvr.profile_id == ^member.id
              )
            )
            |> Repo.transaction()
            |> case do
              {:ok, _changes} ->
                broadcast_group_updated(group)
                broadcast_group_unread_counts_updated(group)
                broadcast_profile_group_unread_counts_updated(member, group.id)
                {:ok, member}

              {:error, _step, reason, _changes} ->
                {:error, reason}
            end
        end
    end
  end

  def request_group_access(%Profile{} = requester, %Group{} = group) do
    cond do
      not group.is_public ->
        {:error, :group_not_public}

      member_of_group?(requester, group) ->
        {:error, :already_a_member}

      pending_group_invitation_for_profile?(group, requester) ->
        {:error, :already_invited}

      true ->
        %GroupJoinRequest{}
        |> GroupJoinRequest.changeset(%{group_id: group.id, requester_id: requester.id})
        |> Repo.insert()
        |> case do
          {:ok, request} ->
            broadcast_group_updated(group)
            broadcast_group_join_request_updates_for_group(group)
            {:ok, request}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_pending_group_join_requests(%Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: [:requester]
    )
    |> Repo.all()
  end

  def count_pending_group_join_requests(%Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id,
      select: count(r.id)
    )
    |> Repo.one()
  end

  def list_pending_group_join_requests_for_approver(%Profile{} = approver) do
    from(r in GroupJoinRequest,
      join: g in assoc(r, :group),
      on: g.id == r.group_id,
      where: g.creator_id == ^approver.id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: [:requester, group: :members]
    )
    |> Repo.all()
  end

  def count_pending_group_join_requests_for_approver(%Profile{} = approver) do
    from(r in GroupJoinRequest,
      join: g in assoc(r, :group),
      on: g.id == r.group_id,
      where: g.creator_id == ^approver.id,
      select: count(r.id)
    )
    |> Repo.one()
  end

  def list_pending_group_join_request_counts(groups) when is_list(groups) do
    group_ids =
      groups
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    case group_ids do
      [] ->
        %{}

      _ ->
        from(r in GroupJoinRequest,
          where: r.group_id in ^group_ids,
          group_by: r.group_id,
          select: {r.group_id, count(r.id)}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  def get_pending_group_join_request(%Profile{} = requester, %Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id and r.requester_id == ^requester.id
    )
    |> Repo.one()
  end

  def accept_group_join_request(%Profile{} = actor, %Group{} = group, request_id)
      when is_integer(request_id) do
    with :ok <- ensure_group_creator(actor, group),
         %GroupJoinRequest{} = request <- get_group_join_request(group, request_id) do
      Multi.new()
      |> Multi.insert(:membership, fn _changes ->
        GroupMembership.changeset(%GroupMembership{}, %{
          group_id: group.id,
          profile_id: request.requester_id
        })
      end)
      |> Multi.delete(:request, request)
      |> Multi.delete_all(
        :invitations,
        from(i in GroupInvitation,
          where:
            i.group_id == ^group.id and i.invitee_id == ^request.requester_id and
              is_nil(i.accepted_at)
        )
      )
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          requester = Repo.get!(Profile, request.requester_id)
          broadcast_group_updated(group)
          broadcast_profile_invitations_updated(requester)
          broadcast_pending_invitations_count_updated(requester)
          broadcast_group_join_request_updates_for_group(group)
          broadcast_profile_group_unread_counts_updated(requester, group.id)
          {:ok, requester}

        {:error, :membership, reason, _changes} ->
          {:error, reason}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :request_not_found}
    end
  end

  def reject_group_join_request(%Profile{} = actor, %Group{} = group, request_id)
      when is_integer(request_id) do
    with :ok <- ensure_group_creator(actor, group),
         %GroupJoinRequest{} = request <- get_group_join_request(group, request_id) do
      Repo.delete(request)
      |> case do
        {:ok, _request} ->
          broadcast_group_updated(group)
          broadcast_group_join_request_updates_for_group(group)
          {:ok, request}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :request_not_found}
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

  def delete_group_data_values(%Profile{} = actor, %Group{} = group) do
    with :ok <- ensure_group_creator(actor, group) do
      {deleted_count, _} =
        from(v in Value,
          where: v.group_id == ^group.id and v.is_data == true
        )
        |> Repo.delete_all()

      if deleted_count > 0 do
        broadcast_group_updated(group)
      end

      {:ok, deleted_count}
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
    get_account_profile(account, account.current_profile_id) ||
      get_account_profile(account, account.default_profile_id)
  end

  def get_account_default_profile(%Account{} = account) do
    get_account_profile(account, account.default_profile_id)
  end

  def list_child_groups(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(g in Group, where: g.parent_id == ^group.id, order_by: [asc: g.name])
    |> Repo.all()
  end

  def list_group_path(%Group{} = group) do
    do_list_group_path(group, [])
  end

  defp maybe_put_profile_reference(changes, _field, current_value, _profile_id)
       when not is_nil(current_value) do
    changes
  end

  defp maybe_put_profile_reference(changes, field, nil, profile_id) do
    Map.put(changes, field, profile_id)
  end

  defp get_account_profile(%Account{} = account, profile_id) when is_integer(profile_id) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: p.id == ^profile_id and ap.account_id == ^account.id,
      select: p
    )
    |> Repo.one()
  end

  defp get_account_profile(%Account{}, _profile_id), do: nil

  def list_visible_group_path_for_profile(%Group{} = group, nil), do: [group]

  def list_visible_group_path_for_profile(%Group{} = group, %Profile{} = profile) do
    list_group_path(group)
    |> maybe_preload_group_members()
    |> Enum.filter(fn path_group ->
      path_group.id == group.id or path_group.is_public or member_of_group?(profile, path_group)
    end)
  end

  def list_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    ordered_ids =
      ordered_child_group_ids_for_profile(
        group.id,
        profile.id,
        normalize_query_limit(opts[:limit]),
        normalize_query_offset(opts[:offset])
      )

    case ordered_ids do
      [] ->
        []

      _ ->
        groups_by_id =
          from(g in Group, where: g.id in ^ordered_ids)
          |> Repo.all()
          |> maybe_preload_group_members()
          |> Map.new(&{&1.id, &1})

        Enum.map(ordered_ids, &Map.fetch!(groups_by_id, &1))
    end
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

  defp ordered_child_group_ids_for_profile(parent_group_id, profile_id, limit, offset)
       when is_integer(parent_group_id) and is_integer(profile_id) do
    sql = ordered_child_group_ids_query(limit, offset)

    params =
      [parent_group_id, profile_id]
      |> maybe_append_query_param(limit)
      |> maybe_append_query_param(offset)

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [group_id] -> group_id end)

      {:error, _reason} ->
        []
    end
  end

  defp ordered_child_group_ids_query(limit, offset) do
    """
    WITH RECURSIVE visible_children AS (
      SELECT DISTINCT g.id
      FROM groups g
      LEFT JOIN group_memberships gm
        ON gm.group_id = g.id AND gm.profile_id = $2
      WHERE g.parent_id = $1
        AND (gm.profile_id IS NOT NULL OR g.is_public = TRUE)
    ),
    subtree(root_id, group_id) AS (
      SELECT vc.id, vc.id
      FROM visible_children vc

      UNION ALL

      SELECT s.root_id, child.id
      FROM subtree s
      JOIN groups child ON child.parent_id = s.group_id
    ),
    unread_counts AS (
      SELECT
        s.root_id,
        COUNT(v.id) FILTER (WHERE v.id > COALESCE(gvr.last_read_value_id, 0))::bigint AS unread_count
      FROM subtree s
      JOIN groups g ON g.id = s.group_id
      JOIN group_memberships gm
        ON gm.group_id = s.group_id AND gm.profile_id = $2
      LEFT JOIN values v
        ON v.group_id = s.group_id AND g.is_root = FALSE AND v.is_data = FALSE
      LEFT JOIN group_value_reads gvr
        ON gvr.group_id = s.group_id AND gvr.profile_id = $2
      GROUP BY s.root_id
    ),
    latest_values AS (
      SELECT v.group_id, MAX(v.inserted_at) AS latest_value_inserted_at
      FROM values v
      WHERE v.is_data = FALSE
      GROUP BY v.group_id
    )
    SELECT g.id
    FROM visible_children vc
    JOIN groups g ON g.id = vc.id
    LEFT JOIN unread_counts uc ON uc.root_id = g.id
    LEFT JOIN latest_values lv ON lv.group_id = g.id
    ORDER BY
      COALESCE(uc.unread_count, 0) DESC,
      lv.latest_value_inserted_at DESC NULLS LAST,
      g.inserted_at DESC,
      g.id DESC#{ordered_child_group_pagination_sql(limit, offset)}
    """
  end

  defp ordered_child_group_pagination_sql(limit, offset) do
    []
    |> maybe_add_limit_sql(limit)
    |> maybe_add_offset_sql(limit, offset)
    |> Enum.join()
  end

  defp maybe_add_limit_sql(parts, limit) when is_integer(limit), do: parts ++ [" LIMIT $3"]
  defp maybe_add_limit_sql(parts, _limit), do: parts

  defp maybe_add_offset_sql(parts, limit, offset)
       when is_integer(limit) and is_integer(offset),
       do: parts ++ [" OFFSET $4"]

  defp maybe_add_offset_sql(parts, nil, offset) when is_integer(offset),
    do: parts ++ [" OFFSET $3"]

  defp maybe_add_offset_sql(parts, _limit, _offset), do: parts

  defp maybe_append_query_param(params, value) when is_integer(value), do: params ++ [value]
  defp maybe_append_query_param(params, _value), do: params

  defp normalize_query_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_query_limit(_limit), do: nil

  defp normalize_query_offset(offset) when is_integer(offset) and offset >= 0, do: offset
  defp normalize_query_offset(_offset), do: nil

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
      where: v.group_id == ^group.id and v.is_data == false,
      order_by: [asc: v.inserted_at, asc: v.id],
      preload: [:creator, :parent]
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def count_group_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == false,
      select: count(v.id)
    )
    |> Repo.one()
  end

  def list_group_data_values(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      order_by: [asc: v.inserted_at, asc: v.id],
      preload: [:creator, :parent]
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def get_latest_data_value_id_for_group(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      order_by: [desc: v.inserted_at, desc: v.id],
      limit: 1,
      select: v.id
    )
    |> Repo.one()
  end

  def get_latest_data_value_for_group(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      order_by: [desc: v.inserted_at, desc: v.id],
      limit: 1
    )
    |> Repo.one()
  end

  def count_group_data_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
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

  def count_group_direct_unread_values(%Profile{} = profile, %Group{} = group) do
    sql = """
    SELECT COUNT(v.id)::bigint AS unread_count
    FROM groups g
    JOIN group_memberships gm
      ON gm.group_id = g.id AND gm.profile_id = $1
    LEFT JOIN group_value_reads gvr
      ON gvr.group_id = g.id AND gvr.profile_id = $1
    LEFT JOIN values v
      ON v.group_id = g.id
     AND v.is_data = FALSE
     AND v.id > COALESCE(gvr.last_read_value_id, 0)
    WHERE g.id = $2 AND g.is_root = FALSE
    """

    case Repo.query(sql, [profile.id, group.id]) do
      {:ok, %{rows: [[unread_count]]}} -> unread_count
      {:error, _reason} -> 0
    end
  end

  def list_pending_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id,
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at
      ],
      preload: [:inviter, group: :members]
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
      preload: [:inviter, group: :members]
    )
    |> Repo.one()
  end

  defp maybe_preload_group_members(%Group{is_direct: true} = group) do
    Repo.preload(group, :members)
  end

  defp maybe_preload_group_members(%Group{} = group), do: group

  defp maybe_preload_group_members(groups) when is_list(groups) do
    direct_group_ids =
      groups
      |> Enum.filter(& &1.is_direct)
      |> Enum.map(& &1.id)

    case direct_group_ids do
      [] ->
        groups

      _ ->
        preloaded_groups =
          from(g in Group,
            where: g.id in ^direct_group_ids,
            preload: [:members]
          )
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        Enum.map(groups, fn group -> Map.get(preloaded_groups, group.id, group) end)
    end
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

  defp ensure_group_creator(%Profile{id: actor_id}, %Group{creator_id: actor_id}), do: :ok
  defp ensure_group_creator(%Profile{}, %Group{}), do: {:error, :not_group_creator}

  defp get_group_join_request(%Group{} = group, request_id) when is_integer(request_id) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id and r.id == ^request_id
    )
    |> Repo.one()
  end

  defp pending_group_invitation_for_profile?(%Group{} = group, %Profile{} = profile) do
    from(i in GroupInvitation,
      where: i.group_id == ^group.id and i.invitee_id == ^profile.id and is_nil(i.accepted_at),
      select: 1
    )
    |> Repo.exists?()
  end

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

  defp find_direct_group(
         repo,
         %Group{} = root_group,
         %Profile{} = first_profile,
         %Profile{} = second_profile
       ) do
    requested_member_group_ids =
      from(membership in GroupMembership,
        where: membership.profile_id in ^[first_profile.id, second_profile.id],
        group_by: membership.group_id,
        having: count(membership.profile_id) == 2,
        select: membership.group_id
      )

    from(group in Group,
      join: membership in GroupMembership,
      on: membership.group_id == group.id,
      where: group.parent_id == ^root_group.id,
      where: group.is_direct,
      where: not group.is_public,
      where: not group.is_root,
      where: group.id in subquery(requested_member_group_ids),
      group_by: group.id,
      having: count(membership.profile_id) == 2,
      order_by: [asc: group.inserted_at],
      limit: 1
    )
    |> repo.one()
  end

  defp maybe_create_initial_direct_group(
         _repo,
         _root_group,
         %Account{invited_by_id: nil},
         _profile,
         _already_has_profiles
       ) do
    {:ok, nil}
  end

  defp maybe_create_initial_direct_group(
         _repo,
         _root_group,
         _account,
         _profile,
         true
       ) do
    {:ok, nil}
  end

  defp maybe_create_initial_direct_group(
         repo,
         %Group{} = root_group,
         %Account{} = account,
         %Profile{} = profile,
         false
       ) do
    case repo.get(Profile, account.invited_by_id) do
      %Profile{} = invited_by_profile ->
        create_direct_group(repo, root_group, profile, invited_by_profile)

      nil ->
        {:ok, nil}
    end
  end

  defp create_direct_group(
         repo,
         %Group{} = root_group,
         %Profile{} = current_profile,
         %Profile{} = other_profile
       ) do
    case find_direct_group(repo, root_group, current_profile, other_profile) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        attrs = %{
          "name" => direct_group_name(current_profile, other_profile),
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat,
          "has_public_chat" => true,
          "is_direct" => true,
          "is_public" => false,
          "creator_id" => current_profile.id,
          "parent_id" => root_group.id,
          "is_root" => false
        }

        Multi.new()
        |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
        |> Multi.insert(:current_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: current_profile.id
          })
        end)
        |> Multi.insert(:other_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: other_profile.id
          })
        end)
        |> repo.transaction()
        |> case do
          {:ok, %{group: group}} -> {:ok, group}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
    end
  end

  defp materialize_pending_group_account_invitations(
         _account,
         _profile,
         true
       ) do
    :ok
  end

  defp materialize_pending_group_account_invitations(
         %Account{} = account,
         %Profile{} = profile,
         false
       ) do
    account
    |> list_pending_group_account_invitations()
    |> Enum.each(fn pending_invitation ->
      case invite_profile_to_group(pending_invitation.inviter, pending_invitation.group, profile) do
        {:ok, _invitation} ->
          ensure_direct_group_between_profiles(profile, pending_invitation.inviter)
          _ = Repo.delete(pending_invitation)
          :ok

        {:error, %Ecto.Changeset{}} ->
          ensure_direct_group_between_profiles(profile, pending_invitation.inviter)
          _ = Repo.delete(pending_invitation)
          :ok

        {:error, :inviter_not_a_member} ->
          _ = Repo.delete(pending_invitation)
          :ok

        {:error, reason} ->
          Logger.warning(
            "Could not materialize pending group account invitation #{pending_invitation.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp ensure_direct_group_between_profiles(%Profile{} = profile, %Profile{} = other_profile) do
    case get_or_create_direct_group(profile, other_profile) do
      {:ok, _group} ->
        :ok

      {:error, :same_profile} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not create direct group for profiles #{profile.id} and #{other_profile.id}: #{inspect(reason)}"
        )
    end
  end

  defp list_pending_group_account_invitations(%Account{} = account) do
    from(invitation in GroupAccountInvitation,
      where: invitation.account_id == ^account.id,
      preload: [:group, :inviter],
      order_by: [asc: invitation.inserted_at]
    )
    |> Repo.all()
  end

  defp direct_group_name(%Profile{} = first_profile, %Profile{} = second_profile) do
    [first_profile.username, second_profile.username]
    |> Enum.sort()
    |> Enum.join(" & ")
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
    |> Enum.each(&deliver_account_push_notification(&1, payload, "group value", group.id))
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
    deliver_account_push_notification(account, payload, "profile notification", nil)
  end

  defp deliver_account_push_notification(%Account{} = account, payload, context, context_id) do
    case Accounts.deliver_push_notification(account, payload) do
      {:ok, _results} ->
        :ok

      {:error, :no_push_subscriptions} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Push delivery failed for account #{account.id} (#{context}#{format_push_context_id(context_id)}): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp format_push_context_id(nil), do: ""
  defp format_push_context_id(context_id), do: " #{context_id}"

  defp group_value_notification_payload(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    %{
      title: "#{creator.username} added a new value",
      body: group_value_notification_body(group, value),
      tag: "group-#{group.id}-value-#{value.id}-created",
      url: "/groups/#{group.id}/values",
      icon: "/images/pwa/icon-192.png",
      badge: "/images/pwa/icon-192.png"
    }
  end

  defp group_invitation_notification_payload(%Profile{} = inviter, %Group{} = group) do
    %{
      title: "#{inviter.username} invited you to #{group.name}",
      body: "Open Potok to review this group invitation.",
      tag: "group-#{group.id}-invitation-#{inviter.id}",
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
      where: v.group_id == ^group.id and v.is_data == false,
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
      LEFT JOIN values v
        ON v.group_id = s.group_id AND g.is_root = FALSE AND v.is_data = FALSE
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

  defp broadcast_profile_group_join_requests_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_group_join_requests_updated, profile_id}
    )
  end

  defp broadcast_pending_group_join_requests_count_updated(%Profile{id: profile_id} = profile) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:pending_group_join_requests_count_updated, profile_id,
       count_pending_group_join_requests_for_approver(profile)}
    )
  end

  defp broadcast_group_join_request_updates_for_group(%Group{creator_id: creator_id})
       when is_integer(creator_id) do
    case Repo.get(Profile, creator_id) do
      %Profile{} = creator ->
        broadcast_profile_group_join_requests_updated(creator)
        broadcast_pending_group_join_requests_count_updated(creator)

      nil ->
        :ok
    end
  end

  defp broadcast_group_join_request_updates_for_group(_group), do: :ok

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

  defp broadcast_group_deleted(group_id, parent_id) when is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_deleted, group_id, parent_id}
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
