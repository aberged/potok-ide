defmodule PotokIde.Social.GroupInvitationExpiryTest do
  @moduledoc """
  A group invitation waits `GroupInvitation.valid_days/0` to be accepted,
  then lapses: it is not accepted, shown or counted, the profile can be
  invited anew, and the hourly sweep deletes it. An accepted one stays.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupAccountInvitation, GroupInvitation}

  setup do
    {_owner_account, owner} = account_with_profile!("gie-owner")
    {_invitee_account, invitee} = account_with_profile!("gie-invitee")
    group = group_with_members!(owner, [], %{"is_public" => true})

    %{owner: owner, invitee: invitee, group: group}
  end

  defp age!(schema, id, days) do
    at = DateTime.add(DateTime.utc_now(:second), -days, :day)
    Repo.update_all(from(i in schema, where: i.id == ^id), set: [inserted_at: at])
    Repo.get!(schema, id)
  end

  test "an invitation past its days is not accepted, and goes", ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    invitation = age!(GroupInvitation, invitation.id, GroupInvitation.valid_days() + 1)

    assert GroupInvitation.expired?(invitation)
    assert {:error, :expired} = Social.accept_group_invitation(invitation, ctx.invitee)
    refute Social.member_of_group?(ctx.invitee, ctx.group)
    refute Repo.get(GroupInvitation, invitation.id)
  end

  test "one still within its days is accepted", ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    invitation = age!(GroupInvitation, invitation.id, GroupInvitation.valid_days() - 1)

    refute GroupInvitation.expired?(invitation)
    assert {:ok, _} = Social.accept_group_invitation(invitation, ctx.invitee)
    assert Social.member_of_group?(ctx.invitee, ctx.group)
  end

  test "a lapsed invitation is not shown or counted, and the profile can be invited anew",
       ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    age!(GroupInvitation, invitation.id, GroupInvitation.valid_days() + 1)

    assert Social.count_pending_invitations(ctx.invitee) == 0
    assert Social.list_pending_invitations(ctx.invitee) == []
    assert Social.count_group_invitations_for_inviter(ctx.owner) == 0
    refute Social.get_pending_invitation_for_invitee(ctx.invitee, invitation.id)

    # Nothing stops a request any more, nor a new invitation.
    assert {:ok, _} = Social.request_group_access(ctx.invitee, ctx.group)
    assert {:ok, fresh} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    assert Social.count_pending_invitations(ctx.invitee) == 1
    refute Repo.get(GroupInvitation, invitation.id)
    assert {:ok, _} = Social.accept_group_invitation(fresh, ctx.invitee)
  end

  test "an accepted invitation stays on the list however old", ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    {:ok, _} = Social.accept_group_invitation(invitation, ctx.invitee)
    age!(GroupInvitation, invitation.id, 400)

    assert [%GroupInvitation{id: id}] = Social.list_pending_invitations(ctx.invitee)
    assert id == invitation.id
    assert Social.delete_expired_invitations() == 0
  end

  test "the sweep deletes lapsed invitations and as old account invitations", ctx do
    {:ok, lapsed} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.invitee)
    age!(GroupInvitation, lapsed.id, GroupInvitation.valid_days() + 1)

    {_other_account, other} = account_with_profile!("gie-other")
    {:ok, fresh} = Social.invite_profile_to_group(ctx.owner, ctx.group, other)

    {:ok, %GroupAccountInvitation{} = old} =
      Social.invite_account_to_group(ctx.owner, ctx.group, account_fixture())

    age!(GroupAccountInvitation, old.id, GroupInvitation.valid_days() + 1)

    assert Social.delete_expired_invitations() == 2
    refute Repo.get(GroupInvitation, lapsed.id)
    refute Repo.get(GroupAccountInvitation, old.id)
    assert Repo.get(GroupInvitation, fresh.id)
  end

  test "an invitation sent to an address keeps its days once the account has a profile",
       ctx do
    account = account_fixture()

    {:ok, %GroupAccountInvitation{} = pending} =
      Social.invite_account_to_group(ctx.owner, ctx.group, account)

    sent = age!(GroupAccountInvitation, pending.id, 10).inserted_at

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "gie-late",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    assert [%GroupInvitation{inserted_at: ^sent}] =
             Social.list_pending_invitations(profile)
  end

  test "one sent to an address too long ago becomes no invitation", ctx do
    account = account_fixture()

    {:ok, %GroupAccountInvitation{} = pending} =
      Social.invite_account_to_group(ctx.owner, ctx.group, account)

    age!(GroupAccountInvitation, pending.id, GroupInvitation.valid_days() + 1)

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "gie-later",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    assert Social.list_pending_invitations(profile) == []
  end
end
