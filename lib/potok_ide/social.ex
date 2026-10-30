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
  alias PotokIde.Storage

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.Accounts.PushSubscription

  alias PotokIde.Social.{
    Access,
    AccountProfile,
    Group,
    GroupAccountInvitation,
    GroupInvitation,
    GroupJoinRequestApproval,
    GroupJoinRequest,
    GroupManifest,
    GroupMemberRole,
    GroupMembership,
    GroupRole,
    GroupValueRead,
    Mentions,
    Profile,
    ProfileInvitation,
    Value,
    ValueAttachment,
    ValueReaction
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

  @doc """
  Subscribes the caller to `{:presence_changed, topic, key, online?}` for one
  profile in `group` and returns whether that profile is online there now.
  """
  def watch_group_presence(%Group{} = group, profile_id) when is_integer(profile_id) do
    topic = group_presence_topic(group)
    key = Integer.to_string(profile_id)
    # Subscribing first means a change between the two calls still arrives.
    :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, key))
    Presence.online?(topic, key)
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

  @doc """
  Loads the picture column (excluded from regular queries via `load_in_query: false`)
  into an already fetched profile or group.
  """
  def load_picture(%Profile{id: id} = profile) do
    url =
      from(p in Profile, where: p.id == ^id, select: p.profile_picture_url)
      |> Repo.one()

    %{profile | profile_picture_url: url}
  end

  def load_picture(%Group{id: id} = group) do
    url =
      from(g in Group, where: g.id == ^id, select: g.group_picture_url)
      |> Repo.one()

    %{group | group_picture_url: url}
  end

  def load_picture(nil), do: nil

  @doc "Minimal data needed to serve a profile avatar: `%{id, username, picture_url}` or nil."
  def get_profile_avatar_source(id) do
    from(p in Profile,
      where: p.id == ^id,
      select: %{id: p.id, name: p.username, picture_url: p.profile_picture_url}
    )
    |> Repo.one()
  end

  @doc "Minimal data needed to serve a group avatar: `%{id, name, picture_url}` or nil."
  def get_group_avatar_source(id) do
    from(g in Group,
      where: g.id == ^id,
      select: %{id: g.id, name: g.name, picture_url: g.group_picture_url}
    )
    |> Repo.one()
  end

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
    attrs = Map.new(attrs)

    cond do
      not member_of_group?(creator, parent) ->
        {:error, :not_a_member_of_parent_group}

      not Access.can?(creator, parent, :create_subgroups) ->
        {:error, :not_permitted}

      # A thread group may only point at a chat value of its own parent.
      not chat_value_in_group?(Map.get(attrs, "parent_value_id"), parent.id) ->
        {:error, :invalid_parent_value}

      true ->
        attrs =
          attrs
          |> Map.put("creator_id", creator.id)
          |> Map.put("parent_id", parent.id)
          |> Map.put_new("is_direct", false)
          |> Map.put_new("is_root", false)

        insert_group_with_creator(creator, parent, attrs)
    end
  end

  defp insert_group_with_creator(%Profile{} = creator, %Group{} = parent, attrs) do
    Multi.new()
    |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
    |> Multi.insert(:membership, fn %{group: group} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: group.id,
        profile_id: creator.id
      })
    end)
    |> insert_admin_role(creator)
    |> Repo.transaction()
    |> case do
      {:ok, %{group: group}} ->
        broadcast_group_updated(parent)
        {:ok, group}

      {:error, _step, reason, _changes} ->
        {:error, reason}
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
        |> insert_admin_role(current_profile)
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
    if not Access.can?(editor, group, :edit_group) do
      {:error, :not_permitted}
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

  @doc """
  Updates only the description of a group. Sub-group lists never show the
  description, so unlike `update_group/3` this neither notifies the parent
  nor triggers a full reload in the group's own subscribers.
  """
  def update_group_description(%Profile{} = editor, %Group{} = group, attrs) do
    if not Access.can?(editor, group, :edit_group) do
      {:error, :not_permitted}
    else
      attrs =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(["description", "description_format"])

      group
      |> Group.update_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, updated_group} ->
          broadcast_group_description_updated(updated_group)
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

      not Access.admin?(profile, group) ->
        {:error, :not_permitted}

      Repo.exists?(from child in Group, where: child.parent_id == ^group.id, select: 1) ->
        {:error, :group_has_children}

      true ->
        parent_id = group.parent_id

        # The group has no sub-groups, so its own values hold all the files
        # that go with it.
        Multi.new()
        |> Multi.delete_all(
          :attachments,
          from(a in ValueAttachment, where: a.group_id == ^group.id, select: a.storage_key)
        )
        |> Multi.delete(:group, group)
        |> Repo.transaction()
        |> case do
          {:ok, %{group: deleted_group, attachments: {_count, storage_keys}}} ->
            Storage.delete_later(storage_keys)
            broadcast_group_deleted(deleted_group.id, parent_id)

            if parent_id do
              broadcast_group_updated(parent_id)
            end

            {:ok, deleted_group}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  def invite_profile_to_group(%Profile{} = inviter, %Group{} = group, %Profile{} = invitee) do
    cond do
      not member_of_group?(inviter, group) ->
        {:error, :inviter_not_a_member}

      group.is_direct ->
        {:error, :direct_group}

      not Access.can?(inviter, group, :invite_members) ->
        {:error, :not_permitted}

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
            broadcast_profile_group_join_requests_updated(invitee)
            broadcast_profile_invitations_updated(inviter)
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

      group.is_direct ->
        {:error, :direct_group}

      not Access.can?(inviter, group, :invite_members) ->
        {:error, :not_permitted}

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
          broadcast_profile_group_join_requests_updated(invitee)
          broadcast_profile_invitations_updated(invitation.inviter)
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

  def delete_group_invitation(%GroupInvitation{} = invitation, %Profile{} = invitee) do
    if invitation.invitee_id != invitee.id do
      {:error, :invitee_mismatch}
    else
      case Repo.delete(invitation) do
        {:ok, deleted_invitation} ->
          broadcast_profile_invitations_updated(invitee)

          case Repo.get(Profile, invitation.inviter_id) do
            %Profile{} = inviter -> broadcast_profile_invitations_updated(inviter)
            nil -> :ok
          end

          {:ok, deleted_invitation}

        {:error, reason} ->
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
    actor_access = Access.for_profile(actor, group)
    member_access = Access.for_profile(member, group, manifest: actor_access.manifest)

    cond do
      group.is_root ->
        {:error, :cannot_remove_root_group_members}

      group.is_direct ->
        {:error, :direct_group}

      not Access.can?(actor_access, :remove_members) ->
        {:error, :not_permitted}

      not member_access.member? ->
        {:error, :not_a_group_member}

      # Only admins remove admins, and a group never loses its last admin.
      member_access.admin? and not actor_access.admin? ->
        {:error, :not_permitted}

      member_access.admin? and Access.count_admins(group) <= 1 ->
        {:error, :last_admin}

      true ->
        # The member's roles go with the membership (composite foreign key).
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
            broadcast_profile_group_join_requests_updated(requester)
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
    requests =
      from(r in GroupJoinRequest,
        join: gm in GroupMembership,
        on: gm.group_id == r.group_id and gm.profile_id == ^approver.id,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [:requester, group: :members]
      )
      |> Repo.all()

    approvable_ids =
      requests
      |> Enum.map(& &1.group)
      |> Enum.uniq_by(& &1.id)
      |> approvable_group_ids(approver)

    Enum.filter(requests, &MapSet.member?(approvable_ids, &1.group_id))
  end

  def count_pending_group_join_requests_for_approver(%Profile{} = approver) do
    from(r in GroupJoinRequest,
      join: gm in GroupMembership,
      on: gm.group_id == r.group_id and gm.profile_id == ^approver.id,
      group_by: r.group_id,
      select: {r.group_id, count(r.id)}
    )
    |> Repo.all()
    |> approvable_join_request_total(approver)
  end

  # Join request counts per group the approver belongs to, summed over the
  # groups where they may manage requests. Groups are only loaded when there
  # are requests at all.
  defp approvable_join_request_total([], _approver), do: 0

  defp approvable_join_request_total(counts, %Profile{} = approver) do
    counts = Map.new(counts)

    approvable_ids =
      from(g in Group, where: g.id in ^Map.keys(counts))
      |> Repo.all()
      |> approvable_group_ids(approver)

    counts
    |> Enum.filter(fn {group_id, _count} -> MapSet.member?(approvable_ids, group_id) end)
    |> Enum.reduce(0, fn {_group_id, count}, total -> total + count end)
  end

  @doc """
  The three header badges in one query: pending invitations, join requests
  the profile may approve and unread values (the root group's count). The
  same numbers as `count_pending_invitations/1`,
  `count_pending_group_join_requests_for_approver/1` and
  `count_root_group_unread_values/1`; the approver's groups are only loaded
  when some of them have join requests. `root_unread_as_of` is the
  unread count's `as_of` (see `root_group_unread_snapshot/1`).

  `unread: false` leaves the unread count out (0, `as_of` nil), for pages
  that count unread values themselves.
  """
  def nav_counts(profile, opts \\ [])

  def nav_counts(nil, _opts),
    do: %{
      pending_invitations: 0,
      pending_group_join_requests: 0,
      root_unread: 0,
      root_unread_as_of: nil
    }

  def nav_counts(%Profile{id: profile_id} = profile, opts) do
    unread? = Keyword.get(opts, :unread, true)

    unread_sql =
      if unread? do
        """
        (
          SELECT COUNT(v.id)
          FROM group_memberships gm
          LEFT JOIN group_value_reads gvr
            ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
          JOIN values v
            ON v.group_id = gm.group_id
           AND v.is_data = FALSE
           AND v.id > COALESCE(gvr.last_read_value_id, 0)
          WHERE gm.profile_id = $1
            AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
        ),
        (SELECT COALESCE(MAX(id), 0)::bigint FROM values)
        """
      else
        "0::bigint, NULL::bigint"
      end

    sql = """
    SELECT
      (SELECT COUNT(*) FROM group_invitations WHERE invitee_id = $1 AND accepted_at IS NULL) +
      (SELECT COUNT(*) FROM profile_invitations WHERE invitee_id = $1 AND accepted_at IS NULL),
      (
        SELECT COALESCE(array_agg(ARRAY[r.group_id, r.request_count]), '{}')
        FROM (
          SELECT jr.group_id, COUNT(*) AS request_count
          FROM group_join_requests jr
          JOIN group_memberships gm ON gm.group_id = jr.group_id AND gm.profile_id = $1
          GROUP BY jr.group_id
        ) r
      ),
      #{unread_sql}
    """

    case Repo.query(sql, [profile_id], cache_statement: "social_nav_counts_#{unread?}") do
      {:ok, %{rows: [[invitations, join_request_counts, unread, unread_as_of]]}} ->
        %{
          pending_invitations: invitations,
          pending_group_join_requests:
            join_request_counts
            |> Enum.map(fn [group_id, count] -> {group_id, count} end)
            |> approvable_join_request_total(profile),
          root_unread: unread,
          root_unread_as_of: unread_as_of
        }

      {:error, _reason} ->
        nav_counts(nil, opts)
    end
  end

  defp approvable_group_ids(groups, %Profile{} = approver) do
    groups
    |> Enum.filter(&Access.can?(approver, &1, :manage_join_requests))
    |> MapSet.new(& &1.id)
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

  def list_approved_group_join_requests_for_approver(%Profile{} = approver, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_request_search_query(opts[:search])

    from(a in GroupJoinRequestApproval,
      join: g in assoc(a, :group),
      join: requester in assoc(a, :requester),
      where: a.approver_id == ^approver.id,
      where: ^approved_request_name_search_dynamic(search),
      order_by: [desc: a.approved_at, desc: a.id],
      offset: ^offset,
      preload: [:requester, group: :members]
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def count_approved_group_join_requests_for_approver(%Profile{} = approver, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    search = normalize_request_search_query(opts[:search])

    from(a in GroupJoinRequestApproval,
      join: g in assoc(a, :group),
      join: requester in assoc(a, :requester),
      where: a.approver_id == ^approver.id,
      where: ^approved_request_name_search_dynamic(search),
      select: count(a.id)
    )
    |> Repo.one()
  end

  def list_approved_group_join_requests_for_requester(%Profile{} = requester, opts \\ []) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_request_search_query(opts[:search])

    refs =
      from(x in subquery(request_history_union_query(requester, search)),
        order_by: [desc: x.sort_at, desc: x.rank, desc: x.id],
        select: {x.kind, x.id}
      )
      |> maybe_limit(limit)
      |> maybe_offset(offset)
      |> Repo.all()

    load_request_history_entries(refs)
  end

  def count_approved_group_join_requests_for_requester(%Profile{} = requester, opts \\ []) do
    search = normalize_request_search_query(opts[:search])

    from(x in subquery(request_history_union_query(requester, search)), select: count())
    |> Repo.one()
  end

  def get_pending_group_join_request(%Profile{} = requester, %Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id and r.requester_id == ^requester.id
    )
    |> Repo.one()
  end

  def accept_group_join_request(%Profile{} = actor, %Group{} = group, request_id)
      when is_integer(request_id) do
    with :ok <- ensure_permission(actor, group, :manage_join_requests),
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
      |> Multi.insert(:approval, fn _changes ->
        GroupJoinRequestApproval.changeset(%GroupJoinRequestApproval{}, %{
          group_id: group.id,
          requester_id: request.requester_id,
          approver_id: actor.id,
          approved_at: DateTime.utc_now(:second)
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          requester = Repo.get!(Profile, request.requester_id)
          broadcast_group_updated(group)
          broadcast_profile_invitations_updated(requester)
          broadcast_profile_group_join_requests_updated(requester)
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
    with :ok <- ensure_permission(actor, group, :manage_join_requests),
         %GroupJoinRequest{} = request <- get_group_join_request(group, request_id) do
      Repo.delete(request)
      |> case do
        {:ok, _request} ->
          requester = Repo.get!(Profile, request.requester_id)

          broadcast_group_updated(group)
          broadcast_profile_group_join_requests_updated(requester)
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

  @doc "Loads a single value with the associations the values tab renders, or nil."
  def get_value_for_display(id) when is_integer(id) do
    from(v in Value, where: v.id == ^id, preload: ^value_display_preloads())
    |> Repo.one()
  end

  # Everything `Components.value_message/1` renders for a chat value: the
  # replied-to value with its author for the quote (or its files when it has
  # no text), the value's files and its thread.
  defp value_display_preloads do
    reactions = from(r in ValueReaction, order_by: [asc: r.id])

    [
      :creator,
      :thread,
      attachments: attachments_in_order(),
      parent: [:creator, attachments: attachments_in_order()],
      reactions: {reactions, :profile}
    ]
  end

  defp attachments_in_order, do: from(a in ValueAttachment, order_by: [asc: a.id])

  @doc """
  Posts a chat value. `attachments` are files already in `PotokIde.Storage`,
  as maps with `:storage_key`, `:filename`, `:content_type` and `:byte_size`;
  they come from the upload, never from `attrs`. A value with files may have
  no text.
  """
  def create_value(%Profile{} = creator, %Group{} = group, attrs, attachments \\ []) do
    attrs = Map.new(attrs)

    cond do
      data_value_attrs?(attrs) and attachments == [] ->
        create_data_value(creator, group, attrs)

      data_value_attrs?(attrs) ->
        {:error, :invalid_attachments}

      not member_of_group?(creator, group) ->
        {:error, :not_a_member_of_group}

      not Access.can?(creator, group, :post_values) ->
        {:error, :not_permitted}

      attachments != [] and not Access.can?(creator, group, :attach_files) ->
        {:error, :not_permitted}

      length(attachments) > Storage.max_files() ->
        {:error, :too_many_attachments}

      # The reply quote shows the parent's content, so it must be a chat
      # value the group's members can already read.
      not chat_value_in_group?(Map.get(attrs, "parent_id"), group.id) ->
        {:error, :invalid_parent}

      true ->
        attrs =
          attrs
          |> Map.put("creator_id", creator.id)
          |> Map.put("group_id", group.id)

        changeset =
          %Value{}
          |> Value.changeset(attrs, attachments?: attachments != [])
          |> put_mentions(creator, group)

        Multi.new()
        |> Multi.insert(:value, changeset)
        |> Multi.run(:attachments, fn repo, %{value: value} ->
          insert_value_attachments(repo, value, attachments)
        end)
        |> Multi.run(:mark_creator_read, fn repo, %{value: value} ->
          upsert_group_value_read(repo, creator.id, group.id, value.id)
        end)
        |> Multi.run(:group_last_value_at, fn repo, %{value: value} ->
          {:ok, set_group_last_value_at(repo, group.id, value.inserted_at)}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{value: value}} ->
            value = Repo.preload(value, value_display_preloads())
            broadcast_value_created(group, value)
            broadcast_group_value_unread(creator, group, value)
            notify_group_members_of_new_value(creator, group, value)
            {:ok, value}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  defp insert_value_attachments(repo, %Value{} = value, attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn file, {:ok, inserted} ->
      %ValueAttachment{
        value_id: value.id,
        group_id: value.group_id,
        profile_id: value.creator_id,
        storage_key: Map.fetch!(file, :storage_key)
      }
      |> ValueAttachment.changeset(Map.take(file, [:filename, :content_type, :byte_size]))
      |> repo.insert()
      |> case do
        {:ok, attachment} -> {:cont, {:ok, [attachment | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Inserts an app (data) value. Data values never count as unread and never
  notify anyone, so this skips the read marker, the per-member unread
  broadcasts and push notifications that chat values trigger.
  """
  def create_data_value(%Profile{} = creator, %Group{} = group, attrs) do
    if not member_of_group?(creator, group) do
      {:error, :not_a_member_of_group}
    else
      attrs =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.merge(%{"is_data" => true, "creator_id" => creator.id, "group_id" => group.id})

      %Value{}
      |> Value.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, value} ->
          value = %{value | creator: creator}
          broadcast_data_value_created(group, value)
          {:ok, value}

        error ->
          error
      end
    end
  end

  defp data_value_attrs?(attrs) do
    Map.get(attrs, "is_data", Map.get(attrs, :is_data)) in [true, "true"]
  end

  # True when `value_id` is empty or names a chat value of the group.
  defp chat_value_in_group?(value_id, _group_id) when value_id in [nil, ""], do: true

  defp chat_value_in_group?(value_id, group_id) do
    case Integer.parse(to_string(value_id)) do
      {id, ""} ->
        Repo.exists?(
          from(v in Value, where: v.id == ^id and v.group_id == ^group_id and v.is_data == false)
        )

      _ ->
        false
    end
  end

  @doc """
  Updates the content of the profile's own value. Only `content` and
  `content_format` can change, so an edit never moves a value or changes what
  it replies to. Replies are re-broadcast so their quotes show the new text.
  """
  def update_value(%Profile{} = profile, %Value{} = value, attrs) do
    if value.creator_id != profile.id do
      {:error, :not_value_creator}
    else
      attrs = Map.take(Map.new(attrs), ["content", "content_format", :content, :content_format])

      # Mentions follow the new text, but an edit notifies nobody. A value
      # with files may lose its text.
      value
      |> Value.changeset(attrs, attachments?: value_has_attachments?(value))
      |> put_mentions(profile, Repo.get!(Group, value.group_id))
      |> Repo.update()
      |> case do
        {:ok, updated_value} ->
          updated_value = Repo.preload(updated_value, value_display_preloads(), force: true)
          broadcast_value_updated(updated_value)
          broadcast_values_updated(reply_ids(updated_value))
          {:ok, updated_value}

        error ->
          error
      end
    end
  end

  def delete_value(%Profile{} = profile, %Value{} = value) do
    if value.creator_id != profile.id and
         not Access.can?(profile, Repo.get!(Group, value.group_id), :delete_values) do
      {:error, :not_value_creator}
    else
      # Read before the delete: `values.parent_id` is nilified with it.
      reply_ids = reply_ids(value)

      Multi.new()
      |> Multi.delete_all(
        :attachments,
        from(a in ValueAttachment, where: a.value_id == ^value.id, select: a.storage_key)
      )
      |> Multi.delete(:value, value)
      |> Multi.run(:group_last_value_at, fn repo, _changes ->
        latest =
          from(v in Value,
            where: v.group_id == ^value.group_id and v.is_data == false,
            select: max(v.inserted_at)
          )
          |> repo.one()

        {:ok, set_group_last_value_at(repo, value.group_id, latest)}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{value: deleted_value, attachments: {_count, storage_keys}}} ->
          Storage.delete_later(storage_keys)
          broadcast_value_deleted(deleted_value)
          broadcast_group_unread_counts_updated(deleted_value.group_id)
          broadcast_values_updated(reply_ids)
          {:ok, deleted_value}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # `groups.last_value_at` orders the sub-groups list. `update_all` leaves
  # `updated_at` alone, which the group avatar URL uses as its cache buster.
  defp set_group_last_value_at(repo, group_id, last_value_at) do
    {count, _} =
      from(g in Group, where: g.id == ^group_id)
      |> repo.update_all(set: [last_value_at: last_value_at])

    count
  end

  defp value_has_attachments?(%Value{attachments: attachments}) when is_list(attachments),
    do: attachments != []

  defp value_has_attachments?(%Value{id: value_id}),
    do: Repo.exists?(from(a in ValueAttachment, where: a.value_id == ^value_id))

  # Chat values only: data values never mention anyone.
  defp put_mentions(%Ecto.Changeset{} = changeset, %Profile{} = author, %Group{} = group) do
    if Ecto.Changeset.get_field(changeset, :is_data) do
      changeset
    else
      {mentions, profile_ids} =
        changeset
        |> Ecto.Changeset.get_field(:content)
        |> Mentions.resolve(author, group)

      Ecto.Changeset.change(changeset, mentions: mentions, mentioned_profile_ids: profile_ids)
    end
  end

  defp reply_ids(%Value{id: value_id}) do
    from(v in Value, where: v.parent_id == ^value_id and v.is_data == false, select: v.id)
    |> Repo.all()
  end

  # Re-sends values whose rendering depends on another row: replies quote
  # their parent, and a value shows a link to its thread.
  defp broadcast_values_updated([]), do: :ok

  defp broadcast_values_updated(value_ids) do
    from(v in Value, where: v.id in ^value_ids, preload: ^value_display_preloads())
    |> Repo.all()
    |> Enum.each(&broadcast_value_updated/1)
  end

  @doc """
  Opens the thread of chat `value`: the sub-group of the value's group that
  points at it through `parent_value_id`. The first call creates it as a
  chat-first group with every member of `group`, named by `attrs["name"]`;
  later calls return it and add the profile when it joined `group` after the
  thread was created. Viewers of `group` are sent the value again so its
  thread link appears.
  """
  def get_or_create_value_thread(%Profile{} = profile, %Group{} = group, %Value{} = value, attrs) do
    cond do
      value.group_id != group.id or value.is_data ->
        {:error, :value_not_found}

      group.is_direct or group.is_root ->
        {:error, :threads_not_supported}

      not member_of_group?(profile, group) ->
        {:error, :not_a_member_of_group}

      thread = get_value_thread(value) ->
        join_value_thread(profile, thread)

      not Access.can?(profile, group, :open_threads) ->
        {:error, :not_permitted}

      true ->
        create_value_thread(profile, group, value, attrs)
    end
  end

  defp get_value_thread(%Value{id: value_id}) do
    Repo.one(from(g in Group, where: g.parent_value_id == ^value_id))
  end

  # A profile that joins a thread late brings along its roles from the parent
  # group, like the members copied when the thread was opened.
  defp join_value_thread(%Profile{} = profile, %Group{} = thread) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      {inserted, _} =
        Repo.insert_all(
          GroupMembership,
          [%{group_id: thread.id, profile_id: profile.id, inserted_at: now, updated_at: now}],
          on_conflict: :nothing
        )

      if inserted == 1 do
        Repo.insert_all(
          GroupMemberRole,
          parent_member_roles_query(thread.parent_id, thread.id, now)
          |> where([r], r.profile_id == ^profile.id),
          on_conflict: :nothing
        )
      end

      thread
    end)
  end

  defp parent_member_roles_query(parent_id, thread_id, now) do
    from(r in GroupMemberRole,
      where: r.group_id == ^parent_id,
      select: %{
        group_id: type(^thread_id, :id),
        profile_id: r.profile_id,
        role_key: r.role_key,
        inserted_at: type(^now, :utc_datetime),
        updated_at: type(^now, :utc_datetime)
      }
    )
  end

  defp create_value_thread(%Profile{} = profile, %Group{} = group, %Value{} = value, attrs) do
    now = DateTime.utc_now(:second)

    group_attrs = %{
      "name" => Map.get(Map.new(attrs), "name"),
      "description" => "",
      "description_format" => :markdown,
      "home_page" => :chat,
      "is_public" => group.is_public,
      "is_direct" => false,
      "is_root" => false,
      "creator_id" => profile.id,
      "parent_id" => group.id,
      "parent_value_id" => value.id
    }

    Multi.new()
    |> Multi.insert(:group, Group.changeset(%Group{}, group_attrs))
    |> Multi.insert_all(:memberships, GroupMembership, fn %{group: thread} ->
      from(gm in GroupMembership,
        where: gm.group_id == ^group.id,
        select: %{
          group_id: type(^thread.id, :id),
          profile_id: gm.profile_id,
          inserted_at: type(^now, :utc_datetime),
          updated_at: type(^now, :utc_datetime)
        }
      )
    end)
    |> Multi.insert_all(:member_roles, GroupMemberRole, fn %{group: thread} ->
      parent_member_roles_query(group.id, thread.id, now)
    end)
    |> Multi.insert(
      :admin_role,
      fn %{group: thread} -> admin_member_role(thread.id, profile.id) end,
      on_conflict: :nothing
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{group: thread}} ->
        broadcast_group_updated(group)
        broadcast_values_updated([value.id])
        {:ok, thread}

      {:error, :group, %Ecto.Changeset{} = changeset, _changes} ->
        # Someone else opened the thread first: the unique index kept theirs.
        case {Keyword.has_key?(changeset.errors, :parent_value_id), get_value_thread(value)} do
          {true, %Group{} = thread} -> join_value_thread(profile, thread)
          _ -> {:error, changeset}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  The chat value a thread group was started from, with its author, when the
  profile can read the group the value lives in; nil otherwise.
  """
  def get_thread_origin(%Profile{} = profile, %Group{parent_value_id: value_id})
      when is_integer(value_id) do
    from(v in Value,
      join: g in assoc(v, :group),
      where: v.id == ^value_id and v.is_data == false,
      preload: [:creator, attachments: ^attachments_in_order(), group: g]
    )
    |> Repo.one()
    |> case do
      %Value{group: group} = value ->
        if group.is_public or member_of_group?(profile, group), do: value

      nil ->
        nil
    end
  end

  def get_thread_origin(_profile, _group), do: nil

  @doc """
  Adds the profile's `emoji` reaction to a chat value, or removes it when the
  profile already reacted with that emoji. A profile can hold several
  different emoji on the same value. Returns the value reloaded for display
  and broadcasts it as a `:value_updated` so every viewer re-renders it.
  """
  def toggle_value_reaction(%Profile{} = profile, %Group{} = group, %Value{} = value, emoji) do
    cond do
      value.group_id != group.id or value.is_data ->
        {:error, :value_not_found}

      not is_binary(emoji) ->
        {:error, :invalid_emoji}

      not member_of_group?(profile, group) ->
        {:error, :not_a_member_of_group}

      not Access.can?(profile, group, :react) ->
        {:error, :not_permitted}

      true ->
        existing =
          from(r in ValueReaction,
            where: r.value_id == ^value.id and r.profile_id == ^profile.id and r.emoji == ^emoji
          )

        result =
          if Repo.exists?(existing) do
            Repo.delete_all(existing)
            :ok
          else
            %ValueReaction{value_id: value.id, profile_id: profile.id}
            |> ValueReaction.changeset(%{emoji: emoji})
            # A double click races the existence check; the unique index settles it.
            |> Repo.insert(on_conflict: :nothing)
          end

        case {result, get_value_for_display(value.id)} do
          {{:error, %Ecto.Changeset{}} = error, _value} ->
            error

          {_result, nil} ->
            {:error, :value_not_found}

          {_result, %Value{} = updated_value} ->
            broadcast_value_updated(updated_value)
            notify_value_creator_of_reaction(result, profile, group, updated_value)
            {:ok, updated_value}
        end
    end
  end

  def delete_group_data_values(%Profile{} = actor, %Group{} = group) do
    with :ok <- ensure_permission(actor, group, :edit_group) do
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
  # Roles
  # ---------

  @doc "What `profile` may do in `group`; see `PotokIde.Social.Access`."
  def get_group_access(profile, %Group{} = group), do: Access.for_profile(profile, group)

  def change_group_role(%GroupRole{} = role, attrs \\ %{}), do: GroupRole.changeset(role, attrs)

  @doc """
  Adds a custom role to the group's own manifest. Only admins of the group
  that owns the manifest change it; the root manifest is fixed.
  """
  def create_group_role(%Profile{} = actor, %Group{} = group, attrs) do
    with {:ok, manifest} <- editable_manifest(actor, group) do
      position = manifest.roles |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)

      %GroupRole{manifest_id: manifest.id, key: Ecto.UUID.generate(), position: position + 1}
      |> GroupRole.changeset(take_role_attrs(attrs))
      |> Repo.insert()
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  def rename_group_role(%Profile{} = actor, %Group{} = group, role_key, attrs) do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_custom_role(manifest, role_key) do
      role
      |> GroupRole.changeset(take_role_attrs(attrs))
      |> Repo.update()
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  defp take_role_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["name"])
  end

  @doc """
  Sets whether the role allows (`:allow`), denies (`:deny`) or says nothing
  about (`:neutral`) a permission. "admin" always holds every permission and
  "everyone" can only allow.
  """
  def set_group_role_permission(%Profile{} = actor, %Group{} = group, role_key, permission, state)
      when state in [:allow, :deny, :neutral] do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_role(manifest, role_key),
         :ok <- validate_permission_change(role, permission, state) do
      allowed = List.delete(role.allowed, permission)
      denied = List.delete(role.denied, permission)

      {allowed, denied} =
        case state do
          :allow -> {[permission | allowed], denied}
          :deny -> {allowed, [permission | denied]}
          :neutral -> {allowed, denied}
        end

      role
      |> GroupRole.permissions_changeset(
        sort_permissions(allowed),
        sort_permissions(denied)
      )
      |> Repo.update()
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  defp validate_permission_change(%GroupRole{key: key}, permission, state) do
    cond do
      permission not in GroupRole.permissions() -> {:error, :invalid_permission}
      key == GroupRole.admin_key() -> {:error, :builtin_role}
      key == GroupRole.everyone_key() and state == :deny -> {:error, :invalid_permission}
      true -> :ok
    end
  end

  defp sort_permissions(permissions) do
    Enum.filter(GroupRole.permissions(), &(&1 in permissions))
  end

  @doc """
  Deletes a custom role together with its assignments in every group that
  uses the manifest. Groups with a copy of the manifest keep their own.
  """
  def delete_group_role(%Profile{} = actor, %Group{} = group, role_key) do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_custom_role(manifest, role_key) do
      group_ids = Access.group_ids_using_manifest(manifest)

      Multi.new()
      |> Multi.delete(:role, role)
      |> Multi.delete_all(
        :assignments,
        from(r in GroupMemberRole, where: r.group_id in ^group_ids and r.role_key == ^role.key)
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{role: role}} ->
          broadcast_group_roles_updated(group_ids)
          {:ok, role}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Gives a group that inherits its manifest a copy of it to change. Role keys
  are kept, so every assignment stays valid.
  """
  def create_own_group_manifest(%Profile{} = actor, %Group{} = group) do
    access = Access.for_profile(actor, group)

    cond do
      group.is_direct ->
        {:error, :direct_group}

      not access.admin? ->
        {:error, :not_permitted}

      Access.own_manifest?(group, access.manifest) ->
        {:error, :own_manifest}

      true ->
        now = DateTime.utc_now(:second)

        Multi.new()
        |> Multi.insert(:manifest, %GroupManifest{group_id: group.id})
        |> Multi.insert_all(:roles, GroupRole, fn %{manifest: manifest} ->
          Enum.map(access.manifest.roles, fn role ->
            role
            |> Map.take([:key, :name, :allowed, :denied, :position])
            |> Map.merge(%{manifest_id: manifest.id, inserted_at: now, updated_at: now})
          end)
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{manifest: manifest}} ->
            broadcast_manifest_updated(manifest)
            {:ok, Access.effective_manifest(group)}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Drops the group's own manifest so it inherits again. Assignments of roles
  the inherited manifest does not have are deleted, except "admin".
  """
  def revert_to_inherited_group_manifest(%Profile{} = actor, %Group{} = group) do
    with {:ok, manifest} <- editable_manifest(actor, group) do
      group_ids = Access.group_ids_using_manifest(manifest)

      Repo.transaction(fn ->
        Repo.delete_all(from(m in GroupManifest, where: m.id == ^manifest.id))

        kept_keys = [
          GroupRole.admin_key()
          | Enum.map(Access.load_effective_manifest(group).roles, & &1.key)
        ]

        from(r in GroupMemberRole,
          where: r.group_id in ^group_ids and r.role_key not in ^kept_keys
        )
        |> Repo.delete_all()
      end)
      |> case do
        {:ok, _deleted} ->
          broadcast_group_roles_updated(group_ids)
          {:ok, Access.effective_manifest(group)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp editable_manifest(%Profile{} = actor, %Group{} = group) do
    access = Access.for_profile(actor, group)

    cond do
      group.is_root -> {:error, :root_manifest_is_fixed}
      not access.admin? -> {:error, :not_permitted}
      not Access.own_manifest?(group, access.manifest) -> {:error, :manifest_is_inherited}
      true -> {:ok, access.manifest}
    end
  end

  defp fetch_role(%GroupManifest{roles: roles}, role_key) do
    case Enum.find(roles, &(&1.key == role_key)) do
      %GroupRole{} = role -> {:ok, role}
      nil -> {:error, :role_not_found}
    end
  end

  defp fetch_custom_role(manifest, role_key) do
    case fetch_role(manifest, role_key) do
      {:ok, role} -> if GroupRole.builtin?(role), do: {:error, :builtin_role}, else: {:ok, role}
      error -> error
    end
  end

  defp broadcast_manifest_updated(%GroupManifest{} = manifest) do
    manifest
    |> Access.group_ids_using_manifest()
    |> broadcast_group_roles_updated()
  end

  @doc """
  Gives a member of the group one of the effective manifest's roles. Only
  the group's admins assign roles; "everyone" is implicit.
  """
  def assign_group_member_role(%Profile{} = actor, %Group{} = group, profile_id, role_key)
      when is_integer(profile_id) and is_binary(role_key) do
    with {:ok, _access} <- ensure_role_assignable(actor, group, profile_id, role_key) do
      %GroupMemberRole{group_id: group.id, profile_id: profile_id, role_key: role_key}
      |> Repo.insert(on_conflict: :nothing)
      |> case do
        {:ok, member_role} ->
          broadcast_group_roles_updated([group.id])
          {:ok, member_role}

        error ->
          error
      end
    end
  end

  def unassign_group_member_role(%Profile{} = actor, %Group{} = group, profile_id, role_key)
      when is_integer(profile_id) and is_binary(role_key) do
    with {:ok, access} <- ensure_role_assignable(actor, group, profile_id, role_key) do
      member_access =
        Access.for_profile(%Profile{id: profile_id}, group, manifest: access.manifest)

      if role_key == GroupRole.admin_key() and member_access.admin? and
           Access.count_admins(group) <= 1 do
        {:error, :last_admin}
      else
        from(r in GroupMemberRole,
          where:
            r.group_id == ^group.id and r.profile_id == ^profile_id and r.role_key == ^role_key
        )
        |> Repo.delete_all()

        broadcast_group_roles_updated([group.id])
        :ok
      end
    end
  end

  defp ensure_role_assignable(%Profile{} = actor, %Group{} = group, profile_id, role_key) do
    access = Access.for_profile(actor, group)
    role_keys = Enum.map(access.manifest.roles, & &1.key)

    cond do
      group.is_direct ->
        {:error, :direct_group}

      not access.admin? ->
        {:error, :not_permitted}

      role_key == GroupRole.everyone_key() or role_key not in role_keys ->
        {:error, :role_not_found}

      not member_of_group?(%Profile{id: profile_id}, group) ->
        {:error, :not_a_group_member}

      true ->
        {:ok, access}
    end
  end

  @doc """
  Suggestions for an `@` mention typed in the group's composer: members whose
  username starts with `query` and, when the profile may mention roles, the
  matching roles of the effective manifest.
  """
  def list_mention_candidates(%Profile{} = profile, %Group{} = group, query)
      when is_binary(query) do
    access = Access.for_profile(profile, group)
    query = query |> String.trim() |> String.downcase() |> String.slice(0, 32)

    if Access.can?(access, :post_values) do
      roles = mention_role_candidates(access, group, query)
      profiles = mention_profile_candidates(profile, group, query, 8 - length(roles))
      roles ++ profiles
    else
      []
    end
  end

  defp mention_role_candidates(%Access{} = access, %Group{} = group, query) do
    if Access.can?(access, :mention_roles) do
      counts = Access.role_member_counts(group)

      access.manifest.roles
      |> Enum.filter(&String.starts_with?(String.downcase(&1.name), query))
      |> Enum.take(3)
      |> Enum.map(fn role ->
        count =
          if role.key == GroupRole.everyone_key(),
            do: count_group_members(group),
            else: Map.get(counts, role.key, 0)

        %{kind: :role, key: role.key, name: role.name, member_count: count}
      end)
    else
      []
    end
  end

  defp mention_profile_candidates(%Profile{} = profile, %Group{} = group, query, limit) do
    pattern = String.replace(query, ~r/[\\%_]/, "\\\\\\0") <> "%"

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id and p.id != ^profile.id and ilike(p.username, ^pattern),
      order_by: [asc: fragment("lower(?)", p.username)],
      limit: ^limit,
      select: %{kind: :profile, id: p.id, name: p.username, updated_at: p.updated_at}
    )
    |> Repo.all()
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

  def list_invitable_profiles_for_group(
        %Profile{} = inviter,
        %Group{} = group,
        search_term,
        opts \\ []
      )
      when is_binary(search_term) do
    normalized_search_term = String.trim(search_term)

    if normalized_search_term == "" do
      []
    else
      limit = Keyword.get(opts, :limit, 6)
      like_search_term = "%#{normalized_search_term}%"
      prefix_search_term = "#{normalized_search_term}%"

      from(p in Profile,
        left_join: gm in GroupMembership,
        on: gm.profile_id == p.id and gm.group_id == ^group.id,
        left_join: gi in GroupInvitation,
        on:
          gi.invitee_id == p.id and gi.group_id == ^group.id and
            is_nil(gi.accepted_at),
        where:
          p.id != ^inviter.id and is_nil(gm.profile_id) and is_nil(gi.id) and
            ilike(p.username, ^like_search_term),
        order_by: [
          asc:
            fragment(
              "CASE WHEN lower(?) LIKE lower(?) THEN 0 ELSE 1 END",
              p.username,
              ^prefix_search_term
            ),
          asc: p.username
        ],
        limit: ^limit
      )
      |> Repo.all()
    end
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
    ancestor_ids = ancestor_group_ids(group)

    groups_by_id =
      from(g in Group, where: g.id in ^ancestor_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(ancestor_ids, &Map.get(groups_by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  # Ids from the root down to (and including) `group`, in one recursive query.
  defp ancestor_group_ids(%Group{id: group_id}) do
    sql = """
    WITH RECURSIVE path AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT parent.id, parent.parent_id, path.depth + 1
      FROM groups parent
      JOIN path ON parent.id = path.parent_id
    )
    SELECT id FROM path ORDER BY depth DESC
    """

    case Repo.query(sql, [group_id], cache_statement: "social_ancestor_group_ids") do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      {:error, _reason} -> [group_id]
    end
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

  @doc """
  The path from the root down to `group` (see `list_group_path/1`), keeping
  only the groups the profile can see: the group itself, public ones and its
  memberships. The root's path is the root alone, so it costs no query.
  """
  def list_visible_group_path_for_profile(%Group{} = group, nil), do: [group]

  def list_visible_group_path_for_profile(%Group{parent_id: nil} = group, %Profile{}),
    do: maybe_preload_group_members([group])

  def list_visible_group_path_for_profile(%Group{} = group, %Profile{} = profile) do
    fields = Group.__schema__(:query_fields)

    # The ancestors with their columns and the membership, in one statement.
    sql = """
    WITH RECURSIVE path AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT parent.id, parent.parent_id, path.depth + 1
      FROM groups parent
      JOIN path ON parent.id = path.parent_id
    )
    SELECT #{group_columns_sql(fields)},
      EXISTS (
        SELECT 1 FROM group_memberships gm WHERE gm.group_id = g.id AND gm.profile_id = $2
      )
    FROM path
    JOIN groups g ON g.id = path.id
    ORDER BY path.depth DESC
    """

    %{rows: rows} =
      Repo.query!(sql, [group.id, profile.id], cache_statement: "social_visible_group_path")

    rows
    |> Enum.flat_map(fn row ->
      {path_group, [member?]} = load_group_row(fields, row)

      if path_group.id == group.id or path_group.is_public or member?,
        do: [path_group],
        else: []
    end)
    |> maybe_preload_group_members()
  end

  @doc """
  Child groups of `group` the profile can see, most active first. Options:
  `:is_direct` and `:is_thread` (true or false keep only those groups, nil
  keeps both; thread groups are the ones started from a chat value),
  `:search` on the name, and `:limit` / `:offset`.
  """
  def list_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    {groups, _rest} = child_group_rows(group, profile, opts, false)
    groups
  end

  @doc "Counts what `list_child_groups_for_profile/3` returns, with the same filters."
  def count_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    %{rows: [[count]]} =
      Repo.query!(
        "WITH #{visible_children_sql()} SELECT COUNT(*) FROM visible_children",
        visible_children_params(group, profile, opts),
        cache_statement: "social_count_child_groups"
      )

    count
  end

  @doc """
  The ids `list_child_groups_for_profile/3` would return, in the same order.
  Takes the same options, plus `:unread_overview` to reuse one the caller
  already loaded with `unread_overview/1`.
  """
  def list_child_group_ids_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    ordered_child_group_ids_for_profile(group, profile, opts)
  end

  @doc """
  A page of `list_child_groups_for_profile/3` with the count of everything it
  pages through (`count_child_groups_for_profile/3`), in one query:
  `{groups, total}`. Takes the options of `list_child_group_ids_for_profile/3`
  but `:offset`.
  """
  def list_child_groups_page_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    opts = Keyword.delete(opts, :offset)
    {groups, totals} = child_group_rows(group, profile, opts, true)

    # The count comes with the rows, so an empty page means nothing to count
    # unless the page itself was empty by asking for no rows.
    total =
      case {totals, normalize_query_limit(opts[:limit])} do
        {[[total] | _], _limit} -> total
        {[], 0} -> count_child_groups_for_profile(group, profile, opts)
        {[], _limit} -> 0
      end

    {groups, total}
  end

  # The ordered sub-groups with their columns in one query, and per group the
  # columns after them: the count of all (`count?`) or none.
  # The order, the page and the count work on narrow rows; only the page's
  # groups are read in full (sorting every visible group's full row measured
  # slower than the two queries this replaces).
  defp child_group_rows(group, profile, opts, count?) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    fields = Group.__schema__(:query_fields)
    total = if count?, do: ", COUNT(*) OVER () AS total", else: ""

    sql = """
    WITH page AS (
      #{ordered_child_groups_query("vc.id, COALESCE(uc.unread_count, 0) AS unread#{total}", limit, offset)}
    )
    SELECT #{group_columns_sql(fields)}#{if count?, do: ", page.total", else: ""}
    FROM page
    JOIN groups g ON g.id = page.id
    ORDER BY page.unread DESC, g.last_value_at DESC NULLS LAST, g.inserted_at DESC, g.id DESC
    """

    %{rows: rows} =
      Repo.query!(sql, ordered_child_groups_params(group, profile, opts, limit, offset),
        cache_statement: "social_child_groups_#{count?}_#{limit != nil}_#{offset != nil}"
      )

    {groups, rest} =
      rows
      |> Enum.map(&load_group_row(fields, &1))
      |> Enum.unzip()

    {maybe_preload_group_members(groups), rest}
  end

  defp ordered_child_group_ids_for_profile(%Group{} = group, %Profile{} = profile, opts) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])

    %{rows: rows} =
      Repo.query!(
        ordered_child_group_ids_query(limit, offset),
        ordered_child_groups_params(group, profile, opts, limit, offset),
        cache_statement: "social_child_group_ids_#{limit != nil}_#{offset != nil}"
      )

    Enum.map(rows, fn [group_id] -> group_id end)
  end

  defp ordered_child_groups_params(group, profile, opts, limit, offset) do
    # Only children with something unread below them sort by it; the counts
    # come from the overview instead of a walk down every child's sub-tree.
    {unread_ids, unread_counts} =
      (opts[:unread_overview] || unread_overview(profile)).groups
      |> Enum.filter(fn {_id, info} -> info.parent_id == group.id and info.visible? end)
      |> Enum.map(fn {id, info} -> {id, info.subtree} end)
      |> Enum.unzip()

    visible_children_params(group, profile, opts)
    |> Kernel.++([unread_ids, unread_counts])
    |> maybe_append_query_param(limit)
    |> maybe_append_query_param(offset)
  end

  # The `groups g` columns `Repo.load/2` makes a `Group` of.
  defp group_columns_sql(fields),
    do: Enum.map_join(fields, ", ", &"g.#{Group.__schema__(:field_source, &1)}")

  # A `Group` from a row that starts with `group_columns_sql/1`, and the
  # row's other columns.
  defp load_group_row(fields, row) do
    {values, rest} = Enum.split(row, length(fields))
    {Repo.load(Group, {fields, values}), rest}
  end

  # The sub-groups of $1 that profile $2 can see: its memberships plus the
  # public ones, filtered by $3 (direct), $4 (name search) and $5 (thread).
  # The memberships are read first, behind OFFSET 0: the cached generic plan
  # would otherwise walk every child of the group to probe them, and the root
  # is the parent of every direct conversation.
  defp visible_children_sql do
    filters =
      "($3::boolean IS NULL OR g.is_direct = $3)" <>
        " AND ($4::text IS NULL OR g.name ILIKE '%' || $4 || '%')" <>
        " AND ($5::boolean IS NULL OR (g.parent_value_id IS NOT NULL) = $5)"

    """
    visible_children AS (
      SELECT g.id, g.inserted_at, g.last_value_at
      FROM (
        SELECT gm.group_id FROM group_memberships gm WHERE gm.profile_id = $2 OFFSET 0
      ) m
      JOIN groups g ON g.id = m.group_id
      WHERE g.parent_id = $1
        AND #{filters}

      UNION

      SELECT g.id, g.inserted_at, g.last_value_at
      FROM groups g
      WHERE g.parent_id = $1
        AND g.is_public = TRUE
        AND #{filters}
    )
    """
  end

  defp visible_children_params(%Group{} = group, %Profile{} = profile, opts) do
    [
      group.id,
      profile.id,
      normalize_boolean_filter(opts[:is_direct]),
      normalize_group_search_term(opts[:search]),
      normalize_boolean_filter(opts[:is_thread])
    ]
  end

  @doc """
  Sorts sub-groups the way `list_child_group_ids_for_profile/3` orders them,
  with the unread counts of an `unread_overview/1` result, for a page that
  keeps its list in memory.
  """
  def sort_child_groups(groups, %{groups: unread}) do
    Enum.sort_by(groups, &child_group_sort_key(&1, unread), :desc)
  end

  # The ORDER BY of `ordered_child_groups_query/3`: unread first, then the
  # newest value (groups without one last), the newest group and the id.
  defp child_group_sort_key(%Group{} = group, unread) do
    {
      get_in(unread, [group.id, :subtree]) || 0,
      if(group.last_value_at, do: DateTime.to_unix(group.last_value_at, :microsecond), else: -1),
      DateTime.to_unix(group.inserted_at, :microsecond),
      group.id
    }
  end

  defp ordered_child_group_ids_query(limit, offset),
    do: ordered_child_groups_query("vc.id", limit, offset)

  # Unread counts arrive as $6 / $7; the newest chat value comes from
  # `groups.last_value_at`, kept up to date by `create_value/4` and
  # `delete_value/2`. `sort_child_groups/2` sorts the same way in memory.
  defp ordered_child_groups_query(select, limit, offset) do
    """
    WITH #{visible_children_sql()}
    SELECT #{select}
    FROM visible_children vc
    LEFT JOIN UNNEST($6::bigint[], $7::bigint[]) AS uc(group_id, unread_count)
      ON uc.group_id = vc.id
    ORDER BY
      COALESCE(uc.unread_count, 0) DESC,
      vc.last_value_at DESC NULLS LAST,
      vc.inserted_at DESC,
      vc.id DESC#{ordered_child_group_pagination_sql(limit, offset)}
    """
  end

  defp ordered_child_group_pagination_sql(limit, offset) do
    []
    |> maybe_add_limit_sql(limit)
    |> maybe_add_offset_sql(limit, offset)
    |> Enum.join()
  end

  # $1..$7 are the filters and unread counts of `ordered_child_group_ids_query/2`.
  defp maybe_add_limit_sql(parts, limit) when is_integer(limit), do: parts ++ [" LIMIT $8"]
  defp maybe_add_limit_sql(parts, _limit), do: parts

  defp maybe_add_offset_sql(parts, limit, offset)
       when is_integer(limit) and is_integer(offset),
       do: parts ++ [" OFFSET $9"]

  defp maybe_add_offset_sql(parts, nil, offset) when is_integer(offset),
    do: parts ++ [" OFFSET $8"]

  defp maybe_add_offset_sql(parts, _limit, _offset), do: parts

  defp maybe_append_query_param(params, value) when is_integer(value), do: params ++ [value]
  defp maybe_append_query_param(params, _value), do: params

  defp normalize_query_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_query_limit(_limit), do: nil

  defp normalize_query_offset(offset) when is_integer(offset) and offset >= 0, do: offset
  defp normalize_query_offset(_offset), do: nil

  defp normalize_boolean_filter(true), do: true
  defp normalize_boolean_filter(false), do: false
  defp normalize_boolean_filter(_), do: nil

  defp normalize_group_search_term(search_term) when is_binary(search_term) do
    search_term
    |> String.trim()
    |> case do
      "" -> nil
      value -> String.slice(value, 0, 120)
    end
  end

  defp normalize_group_search_term(_), do: nil

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
      preload: ^value_display_preloads()
    )
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  @doc """
  Keyset page of chat values: the newest `limit` values older than
  `before_id` (or the newest overall), oldest first. Fetches one extra row
  to tell whether older values exist, so no count query is needed.
  """
  def list_group_values_page(%Group{} = group, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    rows =
      from(v in Value,
        where: v.group_id == ^group.id and v.is_data == false,
        order_by: [desc: v.id],
        limit: ^(limit + 1),
        preload: ^value_display_preloads()
      )
      |> maybe_before_id(opts[:before_id])
      |> Repo.all()

    {Enum.reverse(Enum.take(rows, limit)), length(rows) > limit}
  end

  defp maybe_before_id(query, before_id) when is_integer(before_id),
    do: from(v in query, where: v.id < ^before_id)

  defp maybe_before_id(query, _before_id), do: query

  @doc """
  Keyset page of the files attached in the group, newest first, with their
  uploaders. Returns `{attachments, more?}` like `list_group_values_page/2`.
  """
  def list_group_attachments(%Group{} = group, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    rows =
      from(a in ValueAttachment,
        where: a.group_id == ^group.id,
        order_by: [desc: a.id],
        limit: ^(limit + 1),
        preload: :profile
      )
      |> maybe_before_id(opts[:before_id])
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  @doc """
  The attachment when the profile is a member of the group it was posted in
  (only members read a group's values); nil otherwise.
  """
  def get_attachment_for_download(%Profile{id: profile_id}, attachment_id)
      when is_integer(attachment_id) do
    from(a in ValueAttachment,
      join: gm in GroupMembership,
      on: gm.group_id == a.group_id and gm.profile_id == ^profile_id,
      where: a.id == ^attachment_id
    )
    |> Repo.one()
  end

  def get_attachment_for_download(_profile, _attachment_id), do: nil

  @group_tree_max_depth 10
  @group_tree_max_groups 500
  @attachment_tree_max_files 1000

  # `group` and the sub-groups below it the profile can see, the same rule as
  # the sub-groups tab (members, or public groups), skipping direct
  # conversations. Breadth first, so `group` comes first; the walk stops at
  # #{@group_tree_max_depth} levels and #{@group_tree_max_groups} groups.
  # Returns `{rows, truncated?}`.
  defp visible_group_tree_rows(%Group{} = group, profile_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE tree AS (
          SELECT g.id, g.parent_id, g.name, g.parent_value_id, g.is_public, 0 AS depth
          FROM groups g
          WHERE g.id = $1

          UNION ALL

          SELECT c.id, c.parent_id, c.name, c.parent_value_id, c.is_public, t.depth + 1
          FROM groups c
          JOIN tree t ON c.parent_id = t.id
          WHERE t.depth < $3
            AND c.is_direct = FALSE
            AND (
              c.is_public = TRUE
              OR EXISTS (
                SELECT 1 FROM group_memberships gm
                WHERE gm.group_id = c.id AND gm.profile_id = $2
              )
            )
        )
        SELECT
          t.id,
          t.parent_id,
          t.name,
          t.parent_value_id IS NOT NULL,
          t.is_public,
          EXISTS (
            SELECT 1 FROM group_memberships gm
            WHERE gm.group_id = t.id AND gm.profile_id = $2
          )
        FROM tree t
        ORDER BY t.depth, t.id
        LIMIT $4
        """,
        [group.id, profile_id, @group_tree_max_depth, @group_tree_max_groups + 1]
      )

    groups =
      rows
      |> Enum.take(@group_tree_max_groups)
      |> Enum.map(fn [id, parent_id, name, thread?, public?, member?] ->
        %{
          id: id,
          parent_id: parent_id,
          name: name,
          thread?: thread?,
          public?: public?,
          member?: member?
        }
      end)

    {groups, length(rows) > @group_tree_max_groups}
  end

  @doc """
  The sub-groups below `group` the profile can see, as a folder tree: the
  same groups as the sub-groups tab lists level by level (members, or public
  groups; no direct conversations), sorted by name. A nil profile sees only
  public groups.

  Options: `threads?: false` leaves out threads and everything below them;
  `search:` keeps the groups whose name contains the term and the folders on
  the way to them.

  Each node is `%{group: %{id, name, thread?, public?, member?}, children:
  [...], descendant_count: n, match?: bool, open?: bool}`; `open?` is set on
  the folders that lead to a search match. Returns `%{nodes, ids,
  thread_count, truncated?}`: `ids` of every node shown, `thread_count` of
  the threads in the tree before any filter, and whether the walk stopped at
  #{@group_tree_max_depth} levels or #{@group_tree_max_groups} groups.
  """
  def sub_group_tree(%Group{} = group, profile, opts \\ []) do
    {groups, truncated?} = visible_group_tree_rows(group, profile && profile.id)

    search =
      case normalize_group_search_term(opts[:search]) do
        nil -> nil
        term -> String.downcase(term)
      end

    groups_by_parent =
      groups
      |> Enum.reject(&(&1.id == group.id))
      |> Enum.reject(&(&1.thread? and opts[:threads?] == false))
      |> Enum.group_by(& &1.parent_id)

    nodes =
      group.id
      |> build_sub_group_nodes(groups_by_parent, search)
      |> prune_sub_group_nodes(search)

    %{
      nodes: nodes,
      ids: sub_group_node_ids(nodes),
      thread_count: Enum.count(groups, &(&1.thread? and &1.id != group.id)),
      truncated?: truncated?
    }
  end

  defp build_sub_group_nodes(parent_id, groups_by_parent, search) do
    groups_by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn sub_group ->
      children = build_sub_group_nodes(sub_group.id, groups_by_parent, search)
      match? = search != nil and String.contains?(String.downcase(sub_group.name), search)

      %{
        group: Map.delete(sub_group, :parent_id),
        children: children,
        descendant_count: Enum.sum_by(children, &(&1.descendant_count + 1)),
        match?: match?,
        open?: false
      }
    end)
    |> Enum.sort_by(&{String.downcase(&1.group.name), &1.group.id})
  end

  # Counts stay those of the whole tree, so a folder keeps saying how many
  # sub-groups it has while a search shows only some of them.
  defp prune_sub_group_nodes(nodes, nil), do: nodes

  defp prune_sub_group_nodes(nodes, search) do
    Enum.flat_map(nodes, fn node ->
      children = prune_sub_group_nodes(node.children, search)

      if node.match? or children != [] do
        [%{node | children: children, open?: children != []}]
      else
        []
      end
    end)
  end

  defp sub_group_node_ids(nodes) do
    Enum.flat_map(nodes, &[&1.group.id | sub_group_node_ids(&1.children)])
  end

  @doc """
  The files of `group` and its sub-groups as a folder tree for the profile.
  It walks down through the sub-groups the profile can see, the same rule as
  the sub-groups tab (members, or public groups), skipping direct
  conversations. Files are listed only for groups the profile is a member of,
  and folders with no files anywhere below them are left out.

  Each node is `%{group: %{id, name, thread?, public?, member?}, files: [...],
  children: [...], file_count: n, byte_size: n}`. The walk stops at
  #{@group_tree_max_depth} levels and #{@group_tree_max_groups} groups,
  and only the newest #{@attachment_tree_max_files} files are placed;
  `{tree, truncated?}` tells whether anything was cut.
  """
  def attachment_tree(%Group{} = group, %Profile{} = profile) do
    {folders, groups_truncated?} = visible_group_tree_rows(group, profile.id)

    member_group_ids = for folder <- folders, folder.member?, do: folder.id

    files =
      from(a in ValueAttachment,
        where: a.group_id in ^member_group_ids,
        order_by: [desc: a.id],
        limit: ^(@attachment_tree_max_files + 1)
      )
      |> Repo.all()

    files_truncated? = length(files) > @attachment_tree_max_files

    files_by_group =
      files
      |> Enum.take(@attachment_tree_max_files)
      |> Enum.group_by(& &1.group_id)

    folders_by_parent = Enum.group_by(folders, & &1.parent_id)
    [root | _] = folders

    {build_attachment_folder(root, folders_by_parent, files_by_group, true),
     groups_truncated? or files_truncated?}
  end

  defp build_attachment_folder(folder, folders_by_parent, files_by_group, root?) do
    children =
      folders_by_parent
      |> Map.get(folder.id, [])
      |> Enum.map(&build_attachment_folder(&1, folders_by_parent, files_by_group, false))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{String.downcase(&1.group.name), &1.group.id})

    files =
      files_by_group
      |> Map.get(folder.id, [])
      |> Enum.sort_by(&{String.downcase(&1.filename), &1.id})

    file_count = length(files) + Enum.sum_by(children, & &1.file_count)

    if file_count == 0 and not root? do
      nil
    else
      %{
        group: Map.delete(folder, :parent_id),
        files: files,
        children: children,
        file_count: file_count,
        byte_size: Enum.sum_by(files, & &1.byte_size) + Enum.sum_by(children, & &1.byte_size)
      }
    end
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
      preload: [:creator, :parent]
    )
    |> maybe_filter_data_value_field(opts[:search_field], opts[:search_value])
    |> maybe_order_data_value_field(opts[:order_by], opts[:order_dir])
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  @doc """
  Data values for the app API as plain maps. Joins only the creator's
  username instead of preloading full structs, caps the page size and
  supports `after_id` / `before_id` cursors for incremental reads.
  Returns `{rows, has_more?}`.
  """
  def list_group_data_value_rows(%Group{} = group, opts \\ []) do
    limit = opts[:limit] |> Kernel.||(50) |> min(200) |> max(1)

    rows =
      from(v in Value,
        join: c in assoc(v, :creator),
        where: v.group_id == ^group.id and v.is_data == true,
        limit: ^(limit + 1),
        select: %{
          id: v.id,
          content: v.content,
          data: v.data,
          content_format: v.content_format,
          is_data: v.is_data,
          group_id: v.group_id,
          parent_id: v.parent_id,
          creator_id: v.creator_id,
          creator_username: c.username,
          inserted_at: v.inserted_at,
          updated_at: v.updated_at
        }
      )
      |> maybe_after_id(opts[:after_id])
      |> maybe_before_id(opts[:before_id])
      |> maybe_filter_data_value_field(opts[:search_field], opts[:search_value])
      |> maybe_order_data_value_field(opts[:order_by], opts[:order_dir])
      |> maybe_offset(opts[:offset])
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp maybe_after_id(query, after_id) when is_integer(after_id),
    do: from(v in query, where: v.id > ^after_id)

  defp maybe_after_id(query, _after_id), do: query

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

  @doc """
  Moves the profile's read marker in `group` up to `up_to`: a value id, or
  `:latest` for the group's newest chat value. It never moves back.
  """
  def mark_group_values_read(profile, group, up_to \\ :latest)

  def mark_group_values_read(nil, _group, _up_to), do: :ok

  def mark_group_values_read(%Profile{} = profile, %Group{} = group, up_to) do
    latest_value_id = if up_to == :latest, do: latest_group_value_id(group), else: up_to

    case latest_value_id do
      nil ->
        :ok

      latest_value_id ->
        case upsert_group_value_read(Repo, profile.id, group.id, latest_value_id) do
          # A page marks what it shows and counts again itself, so only the
          # profile's other pages are told.
          {:ok, :updated} ->
            broadcast_from_profile_group_unread_counts_updated(profile, group.id)
            :ok

          # Nothing was unread; skip the broadcast so subscribers do not recount for no reason.
          {:ok, :unchanged} ->
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
      _ -> profile |> unread_overview() |> unread_counts_for(group_ids)
    end
  end

  @doc """
  Unread count for the root group. Every non-root group is a descendant of the
  root, so this is simply the sum of unread values across the profile's
  memberships — no tree traversal needed.
  """
  def count_root_group_unread_values(profile), do: root_group_unread_snapshot(profile).count

  @doc """
  `count_root_group_unread_values/1` with the newest value id the count saw
  (`as_of`, as in `unread_overview/1`), so a page can add later values to it
  one by one. `as_of` is `nil` when the count failed.
  """
  def root_group_unread_snapshot(nil), do: %{count: 0, as_of: nil}

  def root_group_unread_snapshot(%Profile{id: profile_id}) do
    sql = """
    SELECT
      (
        SELECT COUNT(v.id)::bigint
        FROM group_memberships gm
        LEFT JOIN group_value_reads gvr
          ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
        JOIN values v
          ON v.group_id = gm.group_id
         AND v.is_data = FALSE
         AND v.id > COALESCE(gvr.last_read_value_id, 0)
        WHERE gm.profile_id = $1
          AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
      ),
      (SELECT COALESCE(MAX(id), 0)::bigint FROM values)
    """

    case Repo.query(sql, [profile_id], cache_statement: "social_root_unread_count") do
      {:ok, %{rows: [[count, as_of]]}} -> %{count: count, as_of: as_of}
      {:error, _reason} -> %{count: 0, as_of: nil}
    end
  end

  @doc """
  Sums unread values of the visible child groups (and their subtrees) of `group`,
  split by whether the child is a direct group. Returns `%{direct: n, other: n}`.
  """
  def child_group_unread_summary(nil, _group), do: %{direct: 0, other: 0}

  def child_group_unread_summary(%Profile{} = profile, %Group{id: group_id}) do
    profile
    |> unread_overview()
    |> child_unread_summary(group_id)
  end

  @doc """
  A profile's unread values for every group that has some at or below it, in
  one query: `%{total: n, as_of: id, groups: %{group_id => %{subtree: n,
  own: n, parent_id: id, direct?: bool, visible?: bool}}}`. `own` counts the
  group's own values, `subtree` adds those of its sub-groups, `visible?` says
  whether the profile can see the group (member, or a public group) and
  `total` is the root group's count. `as_of` is the newest value id when the
  count was taken: `add_unread_value/3` skips values up to it.

  Values only count in groups the profile is a member of, so the query starts
  from those memberships and walks up to the root, instead of walking down
  through every group below the one being looked at. Read the result with
  `unread_counts_for/2` and `child_unread_summary/2`.
  """
  def unread_overview(nil), do: %{total: 0, as_of: 0, groups: %{}}

  def unread_overview(%Profile{id: profile_id}) do
    {own, as_of} = own_unread_counts(profile_id)

    groups =
      case Map.keys(own) do
        [] -> %{}
        group_ids -> group_chain(profile_id, group_ids)
      end

    subtree =
      Enum.reduce(own, %{}, fn {group_id, count}, acc ->
        group_id
        |> self_and_ancestor_ids(groups)
        |> Enum.reduce(acc, &Map.update(&2, &1, count, fn sum -> sum + count end))
      end)

    %{
      total: own |> Map.values() |> Enum.sum(),
      as_of: as_of,
      groups:
        Map.new(subtree, fn {group_id, count} ->
          {group_id,
           Map.merge(groups[group_id], %{subtree: count, own: Map.get(own, group_id, 0)})}
        end)
    }
  end

  # Unread chat values per group the profile is a member of (the root's own
  # values never count), leaving out groups with none, and the newest value id
  # the same statement saw: one statement, so one snapshot for both. (Folding
  # `group_chain/2` into it saves a round trip but measured slower.)
  defp own_unread_counts(profile_id) do
    sql = """
    SELECT hw.max_id, c.group_id, c.unread
    FROM (SELECT COALESCE(MAX(id), 0)::bigint AS max_id FROM values) hw
    LEFT JOIN LATERAL (
      SELECT gm.group_id, COUNT(v.id)::bigint AS unread
      FROM group_memberships gm
      LEFT JOIN group_value_reads gvr
        ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
      JOIN values v
        ON v.group_id = gm.group_id
       AND v.is_data = FALSE
       AND v.id > COALESCE(gvr.last_read_value_id, 0)
      WHERE gm.profile_id = $1
        AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
      GROUP BY gm.group_id
    ) c ON TRUE
    """

    %{rows: [[as_of | _] | _] = rows} =
      Repo.query!(sql, [profile_id], cache_statement: "social_own_unread_counts")

    own =
      for [_as_of, group_id, count] <- rows, group_id != nil, into: %{}, do: {group_id, count}

    {own, as_of}
  end

  # `group_ids` and all their ancestors with what the overview needs about
  # them.
  defp group_chain(profile_id, group_ids) do
    sql = """
    WITH RECURSIVE #{group_chain_cte("g.id = ANY($2::bigint[])")}
    SELECT c.id, c.parent_id, c.is_direct, c.is_public OR gm.profile_id IS NOT NULL
    FROM chain c
    LEFT JOIN group_memberships gm
      ON gm.group_id = c.id AND gm.profile_id = $1
    """

    %{rows: rows} =
      Repo.query!(sql, [profile_id, group_ids], cache_statement: "social_group_chain")

    Map.new(rows, fn [group_id, parent_id, direct?, visible?] ->
      {group_id, %{parent_id: parent_id, direct?: direct?, visible?: visible?}}
    end)
  end

  # A group and its ancestors up to the root (in no particular order), with
  # what a page needs to count a value of the group without a query: see
  # `add_unread_value/3`. Groups never move, so this is the same for everyone.
  defp group_ancestry(group_id) do
    sql = """
    WITH RECURSIVE #{group_chain_cte("g.id = ANY($1::bigint[])")}
    SELECT c.id, c.parent_id, c.is_direct, c.is_public, c.is_thread
    FROM chain c
    """

    %{rows: rows} =
      Repo.query!(sql, [[group_id]], cache_statement: "social_group_ancestry")

    Enum.map(rows, fn [id, parent_id, direct?, public?, thread?] ->
      %{id: id, parent_id: parent_id, direct?: direct?, public?: public?, thread?: thread?}
    end)
  end

  # The groups `seed` picks and all their ancestors. Each step looks one parent
  # up by its primary key (the LATERAL ... LIMIT 1 keeps the planner from
  # scanning every group for a handful of rows).
  defp group_chain_cte(seed) do
    """
    chain(id, parent_id, is_direct, is_public, is_thread) AS (
      SELECT g.id, g.parent_id, g.is_direct, g.is_public, g.parent_value_id IS NOT NULL
      FROM groups g
      WHERE #{seed}

      UNION

      SELECT p.id, p.parent_id, p.is_direct, p.is_public, p.is_thread
      FROM chain c
      CROSS JOIN LATERAL (
        SELECT g.id, g.parent_id, g.is_direct, g.is_public,
               g.parent_value_id IS NOT NULL AS is_thread
        FROM groups g
        WHERE g.id = c.parent_id
        LIMIT 1
      ) p
    )
    """
  end

  @doc """
  Counts a value from a `{:group_value_unread, profile_id, unread}` broadcast
  into an `unread_overview/1` result, without a query. Returns
  `{:ok, overview}`, or `:counted` when the overview already holds the value
  (it is not newer than `as_of`).

  Groups of the value's chain the overview did not have yet are added. Their
  `visible?` is `true` for a public group, the value's own group (the profile
  is a member) and the ids in `visible_ids` (groups the page shows), and `nil`
  when only a recount can tell.
  """
  def add_unread_value(%{as_of: as_of}, %{value_id: value_id}, _visible_ids)
      when value_id <= as_of,
      do: :counted

  def add_unread_value(overview, %{group_id: group_id, chain: chain}, visible_ids) do
    groups =
      Enum.reduce(chain, overview.groups, fn node, groups ->
        entry =
          Map.get_lazy(groups, node.id, fn ->
            %{
              parent_id: node.parent_id,
              direct?: node.direct?,
              visible?: (node.public? or node.id == group_id or node.id in visible_ids) || nil,
              subtree: 0,
              own: 0
            }
          end)

        own = if node.id == group_id, do: entry.own + 1, else: entry.own
        Map.put(groups, node.id, %{entry | subtree: entry.subtree + 1, own: own})
      end)

    {:ok, %{overview | total: overview.total + 1, groups: groups}}
  end

  defp self_and_ancestor_ids(group_id, groups) do
    case groups do
      %{^group_id => %{parent_id: parent_id}} ->
        [group_id | self_and_ancestor_ids(parent_id, groups)]

      _ ->
        []
    end
  end

  @doc "Unread values at or below each of `group_ids`, from `unread_overview/1`."
  def unread_counts_for(%{groups: groups}, group_ids) do
    Map.new(group_ids, fn group_id ->
      {group_id, get_in(groups, [group_id, :subtree]) || 0}
    end)
  end

  @doc "`child_group_unread_summary/2` from an `unread_overview/1` result."
  def child_unread_summary(%{groups: groups}, group_id) do
    Enum.reduce(groups, %{direct: 0, other: 0}, fn
      {_id, %{parent_id: ^group_id, visible?: true, direct?: true, subtree: count}}, acc ->
        %{acc | direct: acc.direct + count}

      {_id, %{parent_id: ^group_id, visible?: true, subtree: count}}, acc ->
        %{acc | other: acc.other + count}

      _group, acc ->
        acc
    end)
  end

  def list_pending_invitations(%Profile{} = invitee, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: inviter in assoc(i, :inviter),
      where: i.invitee_id == ^invitee.id,
      where: ^invitation_name_search_dynamic(search),
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      offset: ^offset,
      preload: [:inviter, group: :members]
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def list_group_invitations_for_inviter(%Profile{} = inviter, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: invitee in assoc(i, :invitee),
      where: i.inviter_id == ^inviter.id,
      where: ^sent_invitation_name_search_dynamic(search),
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      offset: ^offset,
      preload: [:invitee, group: :members]
    )
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def count_group_invitations_for_invitee(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id,
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_inviter(%Profile{} = inviter) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.inviter_id == ^inviter.id,
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_invitee(%Profile{} = invitee, opts) when is_list(opts) do
    import Ecto.Query, only: [from: 2]

    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: inviter in assoc(i, :inviter),
      where: i.invitee_id == ^invitee.id,
      where: ^invitation_name_search_dynamic(search),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_inviter(%Profile{} = inviter, opts) when is_list(opts) do
    import Ecto.Query, only: [from: 2]

    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: invitee in assoc(i, :invitee),
      where: i.inviter_id == ^inviter.id,
      where: ^sent_invitation_name_search_dynamic(search),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_pending_invitations(%Profile{id: invitee_id}) do
    sql = """
    SELECT
      (SELECT COUNT(*) FROM group_invitations WHERE invitee_id = $1 AND accepted_at IS NULL) +
      (SELECT COUNT(*) FROM profile_invitations WHERE invitee_id = $1 AND accepted_at IS NULL)
    """

    case Repo.query(sql, [invitee_id], cache_statement: "social_pending_invitations_count") do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _reason} -> 0
    end
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

  def get_group_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id,
      preload: [:inviter, group: :members]
    )
    |> Repo.one()
  end

  defp invitation_name_search_dynamic(""), do: true

  defp invitation_name_search_dynamic(search_term) do
    dynamic(
      [_i, g, inviter],
      ilike(g.name, ^"%#{search_term}%") or ilike(inviter.username, ^"%#{search_term}%")
    )
  end

  defp sent_invitation_name_search_dynamic(""), do: true

  defp sent_invitation_name_search_dynamic(search_term) do
    dynamic(
      [_i, g, invitee],
      ilike(g.name, ^"%#{search_term}%") or ilike(invitee.username, ^"%#{search_term}%")
    )
  end

  defp normalize_invitation_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_invitation_search_query(_), do: ""

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

  defp ensure_permission(%Profile{} = actor, %Group{} = group, permission) do
    if Access.can?(actor, group, permission), do: :ok, else: {:error, :not_permitted}
  end

  # The creator of a group is its first admin. Runs after the `:group` step and
  # the creator's membership.
  defp insert_admin_role(%Multi{} = multi, %Profile{id: profile_id}) do
    Multi.insert(multi, :admin_role, fn %{group: group} ->
      admin_member_role(group.id, profile_id)
    end)
  end

  defp admin_member_role(group_id, profile_id) do
    %GroupMemberRole{group_id: group_id, profile_id: profile_id, role_key: GroupRole.admin_key()}
  end

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
        |> insert_admin_role(current_profile)
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

  defp maybe_filter_data_value_field(query, search_field, search_value) do
    field = normalize_data_value_jsonb_field(search_field)
    value = normalize_data_value_search_value(search_value)

    case {field, value} do
      {nil, _} ->
        query

      {_, nil} ->
        query

      {jsonb_field, jsonb_value} ->
        from(v in query,
          where:
            ilike(fragment("COALESCE(? ->> ?, '')", v.data, ^jsonb_field), ^"%#{jsonb_value}%")
        )
    end
  end

  defp maybe_order_data_value_field(query, order_field, order_dir) do
    case normalize_data_value_jsonb_field(order_field) do
      nil ->
        from(v in query, order_by: [asc: v.inserted_at, asc: v.id])

      "number" = jsonb_field ->
        case normalize_data_value_order_dir(order_dir) do
          :desc ->
            from(v in query,
              order_by: [
                desc:
                  fragment(
                    "CASE WHEN COALESCE(? ->> ?, '') ~ '^-{0,1}[0-9]+(\\.[0-9]+){0,1}$' THEN (? ->> ?)::numeric END",
                    v.data,
                    ^jsonb_field,
                    v.data,
                    ^jsonb_field
                  ),
                desc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                desc: v.inserted_at,
                desc: v.id
              ]
            )

          :asc ->
            from(v in query,
              order_by: [
                asc:
                  fragment(
                    "CASE WHEN COALESCE(? ->> ?, '') ~ '^-{0,1}[0-9]+(\\.[0-9]+){0,1}$' THEN (? ->> ?)::numeric END",
                    v.data,
                    ^jsonb_field,
                    v.data,
                    ^jsonb_field
                  ),
                asc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                asc: v.inserted_at,
                asc: v.id
              ]
            )
        end

      jsonb_field ->
        case normalize_data_value_order_dir(order_dir) do
          :desc ->
            from(v in query,
              order_by: [
                desc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                desc: v.inserted_at,
                desc: v.id
              ]
            )

          :asc ->
            from(v in query,
              order_by: [
                asc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                asc: v.inserted_at,
                asc: v.id
              ]
            )
        end
    end
  end

  defp normalize_data_value_jsonb_field(field) when is_binary(field) do
    field
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_data_value_jsonb_field(_field), do: nil

  defp normalize_data_value_search_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_data_value_search_value(_value), do: nil

  defp normalize_data_value_order_dir("desc"), do: :desc
  defp normalize_data_value_order_dir(_value), do: :asc

  # Pending requests and approvals are merged in SQL so ordering, search and
  # pagination happen in the database instead of loading the whole history.
  defp request_history_union_query(%Profile{} = requester, search) do
    pending =
      from(r in GroupJoinRequest,
        join: g in assoc(r, :group),
        where: r.requester_id == ^requester.id,
        where: ^request_history_search_dynamic(search, :pending),
        select: %{
          kind: fragment("'request'::text"),
          id: r.id,
          sort_at: r.inserted_at,
          rank: fragment("0::integer")
        }
      )

    approved =
      from(a in GroupJoinRequestApproval,
        join: g in assoc(a, :group),
        join: approver in assoc(a, :approver),
        where: a.requester_id == ^requester.id,
        where: ^request_history_search_dynamic(search, :approved),
        select: %{
          kind: fragment("'approval'::text"),
          id: a.id,
          sort_at: a.approved_at,
          rank: fragment("1::integer")
        }
      )

    union_all(pending, ^approved)
  end

  defp request_history_search_dynamic("", _kind), do: true

  defp request_history_search_dynamic(search_term, :pending) do
    dynamic([_r, g], ilike(g.name, ^"%#{search_term}%"))
  end

  defp request_history_search_dynamic(search_term, :approved) do
    dynamic(
      [_a, g, approver],
      ilike(g.name, ^"%#{search_term}%") or ilike(approver.username, ^"%#{search_term}%")
    )
  end

  defp load_request_history_entries([]), do: []

  defp load_request_history_entries(refs) do
    request_ids = for {"request", id} <- refs, do: id
    approval_ids = for {"approval", id} <- refs, do: id

    requests =
      from(r in GroupJoinRequest, where: r.id in ^request_ids, preload: [:group])
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    approvals =
      from(a in GroupJoinRequestApproval,
        where: a.id in ^approval_ids,
        preload: [:group, :approver]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    refs
    |> Enum.map(fn
      {"request", id} -> requests[id] && pending_request_history_entry(requests[id])
      {"approval", id} -> approvals[id] && approved_request_history_entry(approvals[id])
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp pending_request_history_entry(%GroupJoinRequest{} = request) do
    %{
      id: "request-#{request.id}",
      source_id: request.id,
      status: :pending,
      group: request.group,
      approver: nil,
      requested_at: request.inserted_at,
      approved_at: nil,
      sort_at: request.inserted_at
    }
  end

  defp approved_request_history_entry(%GroupJoinRequestApproval{} = approval) do
    %{
      id: "approval-#{approval.id}",
      source_id: approval.id,
      status: :approved,
      group: approval.group,
      approver: approval.approver,
      requested_at: nil,
      approved_at: approval.approved_at,
      sort_at: approval.approved_at
    }
  end

  defp approved_request_name_search_dynamic(""), do: true

  defp approved_request_name_search_dynamic(search_term) do
    dynamic(
      [_a, g, requester],
      ilike(g.name, ^"%#{search_term}%") or ilike(requester.username, ^"%#{search_term}%")
    )
  end

  defp normalize_request_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_request_search_query(_), do: ""

  defp maybe_offset(query, offset) when is_integer(offset) and offset >= 0 do
    offset(query, ^offset)
  end

  defp maybe_offset(query, _offset), do: query

  defp notify_group_members_of_new_value(
         %Profile{} = _creator,
         %Group{} = _group,
         %Value{is_data: true}
       ),
       do: :ok

  # Accounts of mentioned members get the mention payload instead of the
  # generic one, so nobody is notified twice about the same value.
  defp notify_group_members_of_new_value(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    payload = group_value_notification_payload(creator, group, value)
    mention_payload = group_value_mention_notification_payload(creator, group, value)

    run_notification(fn ->
      mentioned_account_ids =
        value.mentioned_profile_ids
        |> recipient_account_ids_for_profiles()
        |> MapSet.new()

      group
      |> push_subscriptions_for_group_value(creator)
      |> Enum.each(fn [%PushSubscription{account_id: account_id} | _] = subscriptions ->
        if MapSet.member?(mentioned_account_ids, account_id) do
          deliver_push_to_subscriptions(
            subscriptions,
            account_id,
            mention_payload,
            "group mention",
            group.id
          )
        else
          deliver_push_to_subscriptions(
            subscriptions,
            account_id,
            payload,
            "group value",
            group.id
          )
        end
      end)
    end)
  end

  # Only a reaction that was added notifies (a racing duplicate comes back
  # without an id), and only an author who is still a member and is not the
  # reactor. Accounts that also hold the reactor's profile are skipped.
  defp notify_value_creator_of_reaction(
         {:ok, %ValueReaction{id: reaction_id, emoji: emoji}},
         %Profile{} = reactor,
         %Group{} = group,
         %Value{creator: %Profile{} = creator} = value
       )
       when not is_nil(reaction_id) do
    if creator.id != reactor.id and member_of_group?(creator, group) do
      payload = value_reaction_notification_payload(reactor, group, value, emoji)
      reactor_account_ids = recipient_account_ids_for_profiles([reactor.id])

      run_notification(fn ->
        creator
        |> recipient_accounts_for_profile_notification(reactor_account_ids)
        |> Enum.each(&deliver_account_push_notification(&1, payload, "value reaction", group.id))
      end)
    end

    :ok
  end

  defp notify_value_creator_of_reaction(_result, _reactor, _group, _value), do: :ok

  defp recipient_account_ids_for_profiles([]), do: []

  defp recipient_account_ids_for_profiles(profile_ids) do
    from(ap in AccountProfile,
      where: ap.profile_id in ^profile_ids,
      distinct: true,
      select: ap.account_id
    )
    |> Repo.all()
  end

  # Push delivery involves HTTP calls to FCM / web push endpoints; run it off the
  # caller (usually a LiveView process) so the UI responds immediately. Tests
  # run it inline so they can assert on the requests deterministically.
  defp run_notification(fun) when is_function(fun, 0) do
    if Application.get_env(:potok_ide, :async_notifications, true) do
      {:ok, _pid} = Task.Supervisor.start_child(PotokIde.TaskSupervisor, fun)
      :ok
    else
      fun.()
      :ok
    end
  end

  defp notify_profile_invitee_of_group_invitation(
         %Profile{} = inviter,
         %Group{} = group,
         %Profile{} = invitee
       ) do
    payload = group_invitation_notification_payload(inviter, group)

    run_notification(fn ->
      invitee
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(&deliver_profile_notification(&1, payload, "group invitation", inviter.id))
    end)
  end

  defp notify_profile_inviter_of_group_invitation_acceptance(
         %GroupInvitation{} = invitation,
         %Profile{} = invitee
       ) do
    payload = group_invitation_accepted_notification_payload(invitation.group, invitee)

    run_notification(fn ->
      invitation.inviter
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(
        &deliver_profile_notification(&1, payload, "group invitation acceptance", invitee.id)
      )
    end)
  end

  defp notify_profile_invitee_of_shared_profile_invitation(
         %Profile{} = inviter,
         %Profile{} = shared_profile,
         %Profile{} = invitee
       ) do
    payload = shared_profile_invitation_notification_payload(inviter, shared_profile)

    run_notification(fn ->
      invitee
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(
        &deliver_profile_notification(&1, payload, "shared profile invitation", inviter.id)
      )
    end)
  end

  defp notify_profile_inviter_of_shared_profile_acceptance(
         %ProfileInvitation{} = invitation,
         %Profile{} = invitee,
         %Account{} = invitee_account
       ) do
    payload = shared_profile_invitation_accepted_notification_payload(invitation.profile, invitee)

    run_notification(fn ->
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
    end)
  end

  # The push subscriptions of the members' accounts, grouped per account in
  # one query. Members without a subscribed device cost nothing, where loading
  # every member's account and then its subscriptions took a query per member.
  defp push_subscriptions_for_group_value(%Group{} = group, %Profile{} = creator) do
    member_account_ids =
      from(ap in AccountProfile,
        join: gm in GroupMembership,
        on: gm.profile_id == ap.profile_id,
        where: gm.group_id == ^group.id and gm.profile_id != ^creator.id,
        select: ap.account_id
      )

    from(subscription in PushSubscription,
      where: subscription.account_id in subquery(member_account_ids),
      order_by: [asc: subscription.account_id, desc: subscription.updated_at]
    )
    |> Repo.all()
    |> Enum.chunk_by(& &1.account_id)
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
    account
    |> Accounts.list_push_subscriptions()
    |> deliver_push_to_subscriptions(account.id, payload, context, context_id)
  end

  defp deliver_push_to_subscriptions(subscriptions, account_id, payload, context, context_id) do
    case Accounts.deliver_push_notification_to_subscriptions(subscriptions, payload) do
      {:ok, _results} ->
        :ok

      {:error, :no_push_subscriptions} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Push delivery failed for account #{account_id} (#{context}#{format_push_context_id(context_id)}): #{inspect(reason)}"
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
      badge: profile_avatar_url(creator)
    }
  end

  defp group_value_mention_notification_payload(
         %Profile{} = creator,
         %Group{} = group,
         %Value{} = value
       ) do
    %{
      group_value_notification_payload(creator, group, value)
      | title: "#{creator.username} mentioned you in #{group.name}"
    }
  end

  # One tag per value, so later reactions replace the earlier notification.
  defp value_reaction_notification_payload(
         %Profile{} = reactor,
         %Group{} = group,
         %Value{} = value,
         emoji
       ) do
    body =
      case notification_excerpt(value) do
        nil -> group.name
        snippet -> "#{group.name}: #{snippet}"
      end

    %{
      title: "#{reactor.username} reacted #{emoji} to your value",
      body: body,
      tag: "group-#{group.id}-value-#{value.id}-reactions",
      url: "/groups/#{group.id}/values",
      badge: profile_avatar_url(reactor)
    }
  end

  defp group_invitation_notification_payload(%Profile{} = inviter, %Group{} = group) do
    %{
      title: "#{inviter.username} invited you to #{group.name}",
      body: "Open Potok to review this group invitation.",
      tag: "group-#{group.id}-invitation-#{inviter.id}",
      url: "/invitations",
      badge: profile_avatar_url(inviter)
    }
  end

  defp group_invitation_accepted_notification_payload(%Group{} = group, %Profile{} = invitee) do
    %{
      title: "#{invitee.username} accepted your invitation",
      body: "#{invitee.username} joined #{group.name}.",
      tag: "group-#{group.id}-invitation-accepted",
      url: "/groups/#{group.id}",
      badge: profile_avatar_url(invitee)
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
      badge: profile_avatar_url(shared_profile)
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
      badge: profile_avatar_url(shared_profile)
    }
  end

  defp group_value_notification_body(%Group{} = group, %Value{} = value) do
    excerpt = notification_excerpt(value)

    case excerpt do
      nil ->
        "New value in #{group.name}"

      snippet ->
        "New value in #{group.name}: #{snippet}"
    end
  end

  defp notification_excerpt(%Value{content: content} = value),
    do: notification_excerpt(content) || Value.attachment_summary(value, 120)

  defp notification_excerpt(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= 120 -> trimmed
      true -> String.slice(trimmed, 0, 117) <> "..."
    end
  end

  defp notification_excerpt(_content), do: nil

  # Notification badges and icons cannot be SVG, which the avatar URL serves
  # by default.
  defp profile_avatar_url(%Profile{id: profile_id}),
    do: "/avatar/profile/#{profile_id}?format=png"

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

  defp upsert_group_value_read(repo, profile_id, group_id, last_read_value_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The WHERE clause makes the upsert a no-op (num_rows = 0) when the read
    # marker would not advance, which lets callers skip redundant broadcasts.
    sql = """
    INSERT INTO group_value_reads (profile_id, group_id, last_read_value_id, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (profile_id, group_id)
    DO UPDATE SET
      last_read_value_id = EXCLUDED.last_read_value_id,
      updated_at = EXCLUDED.updated_at
    WHERE COALESCE(group_value_reads.last_read_value_id, 0) < EXCLUDED.last_read_value_id
    """

    case repo.query(sql, [profile_id, group_id, last_read_value_id, now, now],
           cache_statement: "social_upsert_group_value_read"
         ) do
      {:ok, %{num_rows: 0}} -> {:ok, :unchanged}
      {:ok, _result} -> {:ok, :updated}
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

  defp broadcast_group_join_request_updates_for_group(%Group{} = group) do
    group
    |> Access.profile_ids_with_permission(:manage_join_requests)
    |> Enum.each(&broadcast_profile_group_join_requests_updated(%Profile{id: &1}))
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
    group_id
    |> group_member_profile_ids()
    |> Enum.each(fn profile_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        profile_topic(profile_id),
        {:group_unread_counts_updated, profile_id, group_id}
      )
    end)
  end

  # Skips the calling process, which already knows (see `mark_group_values_read/3`).
  defp broadcast_from_profile_group_unread_counts_updated(%Profile{id: profile_id}, group_id) do
    Phoenix.PubSub.broadcast_from(
      PotokIde.PubSub,
      self(),
      profile_topic(profile_id),
      {:group_unread_counts_updated, profile_id, group_id}
    )
  end

  # A new chat value is one more unread value for every member but its
  # creator. It goes out with the group's chain up to the root, worked out
  # once here, so each member's pages add it to their counts without a query
  # (`add_unread_value/3`) instead of all counting again at once. The creator's
  # read marker moved past it, which may have read older values too, so the
  # creator's other pages count again. The root group's values never count.
  defp broadcast_group_value_unread(_creator, %Group{is_root: true}, _value), do: :ok

  defp broadcast_group_value_unread(%Profile{} = creator, %Group{id: group_id}, %Value{} = value) do
    unread = %{
      group_id: group_id,
      value_id: value.id,
      inserted_at: value.inserted_at,
      chain: group_ancestry(group_id)
    }

    group_id
    |> group_member_profile_ids()
    |> Enum.reject(&(&1 == creator.id))
    |> Enum.each(fn profile_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        profile_topic(profile_id),
        {:group_value_unread, profile_id, unread}
      )
    end)

    broadcast_from_profile_group_unread_counts_updated(creator, group_id)
  end

  defp group_member_profile_ids(group_id) do
    from(gm in GroupMembership,
      where: gm.group_id == ^group_id,
      select: gm.profile_id,
      distinct: true
    )
    |> Repo.all()
  end

  defp broadcast_profile_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_updated, profile_id}
    )
  end

  # Every manifest or role change ends here, so the cached manifests go first:
  # the pages reload them on this message.
  defp broadcast_group_roles_updated(group_ids) when is_list(group_ids) do
    Access.forget_manifests(group_ids)

    Enum.each(group_ids, fn group_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        group_topic(group_id),
        {:group_roles_updated, group_id}
      )
    end)
  end

  defp broadcast_group_updated(%Group{id: group_id}), do: broadcast_group_updated(group_id)

  defp broadcast_group_updated(group_id) when is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_updated, group_id}
    )
  end

  # Value broadcasts carry the preloaded value so subscribers do not each
  # query it again.
  defp broadcast_value_created(%Group{id: group_id}, %Value{} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_created, group_id, value}
    )
  end

  defp broadcast_data_value_created(%Group{id: group_id}, %Value{} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:data_value_created, group_id, value}
    )
  end

  defp broadcast_value_updated(%Value{group_id: group_id} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_updated, group_id, value}
    )
  end

  defp broadcast_group_description_updated(%Group{id: group_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_description_updated, group_id}
    )
  end

  defp broadcast_value_deleted(%Value{group_id: group_id, id: value_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_deleted, group_id, value_id}
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
