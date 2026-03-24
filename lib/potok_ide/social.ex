defmodule PotokIde.Social do
  @moduledoc """
  Social domain context.

  Owns Profiles, Groups, Values, and the relationships between them.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PotokIde.Repo

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
    invitation = Repo.preload(invitation, :profile)

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
          broadcast_account_profiles_updated(invitee_account)
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
            ok

          error ->
            error
        end
    end
  end

  def accept_group_invitation(%GroupInvitation{} = invitation, %Profile{} = invitee) do
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
          broadcast_group_updated(inv.group_id)
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

      %Value{}
      |> Value.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _value} = ok ->
          broadcast_group_updated(group)
          ok

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

  def list_child_groups_for_profile(%Group{} = group, %Profile{} = profile) do
    import Ecto.Query, only: [from: 2]

    from(g in Group,
      join: gm in GroupMembership,
      on: gm.group_id == g.id,
      where: g.parent_id == ^group.id and (gm.profile_id == ^profile.id or g.is_public == true),
      order_by: [asc: g.name],
      distinct: g.id
    )
    |> Repo.all()
  end

  def list_group_members(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id,
      order_by: [asc: p.username]
    )
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

  def list_group_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id,
      order_by: [asc: v.inserted_at],
      preload: [:creator, :parent]
    )
    |> Repo.all()
  end

  def list_pending_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      # and is_nil(i.accepted_at),
      where: i.invitee_id == ^invitee.id,
      order_by: [desc: i.inserted_at],
      preload: [:group, :inviter]
    )
    |> Repo.all()
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

  defp account_topic(account_id), do: "accounts:#{account_id}"
  defp profile_topic(profile_id), do: "profiles:#{profile_id}"
  defp group_topic(group_id), do: "groups:#{group_id}"

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
