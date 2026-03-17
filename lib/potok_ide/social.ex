defmodule PotokIde.Social do
  @moduledoc """
  Social domain context.

  Owns Profiles, Groups, Values, and the relationships between them.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias PotokIde.Repo

  alias PotokIde.Accounts.Account
  alias PotokIde.Social.{AccountProfile, Group, GroupInvitation, GroupMembership, Profile, Value}

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
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _step, reason, _changes} -> {:error, reason}
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
    end
  end

  def add_profile_to_account(%Profile{} = profile, %Account{} = account) do
    case profile.sharing do
      :shared ->
        Repo.insert(
          AccountProfile.changeset(%AccountProfile{}, %{
            account_id: account.id,
            profile_id: profile.id
          })
        )

      :unique ->
        existing_account_ids =
          from(ap in AccountProfile, where: ap.profile_id == ^profile.id, select: ap.account_id)
          |> Repo.all()

        cond do
          existing_account_ids == [] ->
            Repo.insert(
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
        {:ok, %{group: group}} -> {:ok, group}
        {:error, _step, reason, _changes} -> {:error, reason}
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
        {:ok, %{invitation: inv}} -> {:ok, inv}
        {:error, _step, reason, _changes} -> {:error, reason}
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

  def list_group_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id,
      order_by: [desc: v.inserted_at],
      preload: [:creator, :parent]
    )
    |> Repo.all()
  end

  def list_pending_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      order_by: [desc: i.inserted_at],
      preload: [:group, :inviter]
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
end
