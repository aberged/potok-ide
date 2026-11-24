defmodule PotokIde.Social.ProfileFromInvitationTest do
  @moduledoc """
  The first profile made from an invitation's link goes into the group of the
  oldest invitation (the one whose email was sent); the others wait for the
  account, which picks the profile for each (`EmailInvitations`).
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{EmailInvitations, GroupAccountInvitation, GroupInvitation}

  setup do
    {_owner_account, owner} = account_with_profile!("pfi-owner")
    group = group_with_members!(owner, [])
    account = unconfirmed_account_fixture()

    %{owner: owner, group: group, account: account}
  end

  defp invite!(inviter, group, account, days_ago) do
    {:ok, %GroupAccountInvitation{} = invitation} =
      Social.invite_account_to_group(inviter, group, account)

    at = DateTime.add(DateTime.utc_now(:second), -days_ago, :day)

    Repo.update_all(from(i in GroupAccountInvitation, where: i.id == ^invitation.id),
      set: [inserted_at: at]
    )

    invitation
  end

  test "joins the group of the oldest invitation and leaves the others waiting", ctx do
    later_group = group_with_members!(ctx.owner, [])
    invite!(ctx.owner, later_group, ctx.account, 1)
    invite!(ctx.owner, ctx.group, ctx.account, 3)

    assert %GroupAccountInvitation{group: %{id: group_id}, inviter: %{id: inviter_id}} =
             Social.first_pending_account_invitation(ctx.account)

    assert group_id == ctx.group.id
    assert inviter_id == ctx.owner.id
    refute Social.account_has_profiles?(ctx.account)

    assert {:ok, profile, group} =
             Social.create_profile_from_invitation(ctx.account, %{"username" => "pfi-new"})

    assert group.id == ctx.group.id
    assert Social.member_of_group?(profile, ctx.group)
    refute Social.member_of_group?(profile, later_group)
    assert Social.account_has_profiles?(ctx.account)

    # The accepted one names the profile, dated as it was sent; the other
    # waits for the account, not for this profile.
    assert [%GroupInvitation{accepted_at: %DateTime{}, inviter_id: ^inviter_id}] =
             Repo.all(from(i in GroupInvitation, where: i.invitee_id == ^profile.id))

    assert [%{group: %{id: waiting_id}}] = EmailInvitations.list(ctx.account)
    assert waiting_id == later_group.id
  end

  test "makes the profile with no group when there is no invitation", ctx do
    assert {:ok, profile, nil} =
             Social.create_profile_from_invitation(ctx.account, %{
               "username" => "pfi-alone",
               "profile_picture_url" => "data:image/png;base64,iVBORw0KGgo="
             })

    assert profile.username == "pfi-alone"
    assert Social.account_has_profiles?(ctx.account)
  end

  test "makes the profile with no group when the inviter has left", ctx do
    {_account, other} = account_with_profile!("pfi-other")
    add_member!(ctx.owner, ctx.group, other)
    invite!(other, ctx.group, ctx.account, 1)
    {:ok, _left} = Social.leave_group(other, ctx.group)

    assert {:ok, profile, nil} =
             Social.create_profile_from_invitation(ctx.account, %{"username" => "pfi-late"})

    refute Social.member_of_group?(profile, ctx.group)
    refute Repo.exists?(from(i in GroupInvitation, where: i.invitee_id == ^profile.id))
  end

  test "an invitation past its days is not the one", ctx do
    invite!(ctx.owner, ctx.group, ctx.account, GroupInvitation.valid_days() + 1)

    refute Social.first_pending_account_invitation(ctx.account)

    assert {:ok, profile, nil} =
             Social.create_profile_from_invitation(ctx.account, %{"username" => "pfi-old"})

    refute Social.member_of_group?(profile, ctx.group)
  end

  test "a taken name makes nothing and keeps the invitation", ctx do
    invite!(ctx.owner, ctx.group, ctx.account, 1)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Social.create_profile_from_invitation(ctx.account, %{"username" => "pfi-owner"})

    assert changeset.errors[:username]
    refute Social.account_has_profiles?(ctx.account)
    assert Social.first_pending_account_invitation(ctx.account)
  end
end
