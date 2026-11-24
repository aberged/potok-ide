defmodule PotokIde.Social.AcceptInvitationAsTest do
  @moduledoc """
  An invitation to a unique profile may be accepted by another unique profile
  of the same account, or by a new one, which comes into the group in the
  invitee's place. The invitation then names the profile that came in.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures, only: [share_profile!: 2]

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{GroupInvitation, GroupJoinRequest, Profile}

  setup do
    {_owner_account, owner} = account_with_profile!("aia-owner")
    {account, invited} = account_with_profile!("aia-invited")
    other = profile!(account, "aia-other")
    group = group_with_members!(owner, [], %{"is_public" => true})
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, invited)

    %{
      owner: owner,
      account: Accounts.get_account!(account.id),
      invited: invited,
      other: other,
      group: group,
      invitation: invitation
    }
  end

  defp profile!(account, username, sharing \\ :unique) do
    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: sharing
      })

    profile
  end

  describe "accept_group_invitation_as/3" do
    test "another unique profile comes in, and the invitation names it", ctx do
      assert {:ok, accepted} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)

      assert accepted.invitee_id == ctx.other.id
      assert accepted.accepted_at
      assert Social.member_of_group?(ctx.other, ctx.group)
      refute Social.member_of_group?(ctx.invited, ctx.group)
      assert Social.count_pending_invitations(ctx.invited) == 0

      assert [%{invitee: %{username: "aia-other"}, accepted_at: %DateTime{}}] =
               Social.list_group_invitations_for_inviter(ctx.owner)
    end

    test "the invitee itself accepts as before", ctx do
      assert {:ok, accepted} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.invited)

      assert accepted.invitee_id == ctx.invited.id
      assert Social.member_of_group?(ctx.invited, ctx.group)
    end

    test "the inviter gets the push that it was accepted", ctx do
      capture_push_requests!()
      owner_account = Accounts.get_account!(account_id_of(ctx.owner))
      endpoint = push_device!(owner_account)

      assert {:ok, _} = Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)
      assert pushed_endpoints() == [endpoint]
    end

    test "the profile's own invitation and request in the group go", ctx do
      {_account, admin} = account_with_profile!("aia-admin")
      add_member!(ctx.owner, ctx.group, admin)
      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, admin.id, "admin")
      {:ok, own} = Social.invite_profile_to_group(admin, ctx.group, ctx.other)
      # Inviting drops a request, so this one is put in by hand.
      {:ok, _request} = insert_request(ctx.other, ctx.group)

      assert {:ok, _} = Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)
      refute Repo.get(GroupInvitation, own.id)
      refute Repo.exists?(from(r in GroupJoinRequest, where: r.requester_id == ^ctx.other.id))
    end

    test "a sub-group that inherits members takes in the profile that came in", ctx do
      child = group_with_members!(ctx.owner, [], %{"inherits_members" => true, parent: ctx.group})

      assert {:ok, _} = Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)
      assert Social.member_of_group?(ctx.other, child)
      refute Social.member_of_group?(ctx.invited, child)
    end

    test "a profile already in the group is refused", ctx do
      add_member!(ctx.owner, ctx.group, ctx.other)

      assert {:error, :already_member} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)

      assert Repo.get!(GroupInvitation, ctx.invitation.id).accepted_at == nil
    end

    test "a profile blocked in the group is refused", ctx do
      assert {:ok, _} = Social.block_from_group(ctx.owner, ctx.group, ctx.other)

      assert {:error, :blocked} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, ctx.other)

      refute Social.member_of_group?(ctx.other, ctx.group)
    end

    test "a shared profile accepts nothing in another's place", ctx do
      shared = profile!(ctx.account, "aia-shared", :shared)

      assert {:error, :not_unique} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, shared)
    end

    test "an invitation to a shared profile goes to nobody else", ctx do
      shared = profile!(ctx.account, "aia-shared", :shared)
      {other_account, _} = account_with_profile!("aia-holder")
      share_profile!(shared, other_account)
      {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, shared)

      assert {:error, :not_unique} =
               Social.accept_group_invitation_as(invitation, ctx.account, ctx.other)

      assert Social.invitation_profile_choices(ctx.account, invitation) == []
    end

    test "another account's profile is refused, and so is another account", ctx do
      {stranger_account, stranger} = account_with_profile!("aia-stranger")

      assert {:error, :not_held} =
               Social.accept_group_invitation_as(ctx.invitation, ctx.account, stranger)

      assert {:error, :invitee_mismatch} =
               Social.accept_group_invitation_as(ctx.invitation, stranger_account, stranger)

      assert {:error, :not_held} =
               Social.accept_group_invitation_as(ctx.invitation, stranger_account, ctx.invited)
    end

    test "a lapsed invitation is not accepted, and goes", ctx do
      at = DateTime.add(DateTime.utc_now(:second), -(GroupInvitation.valid_days() + 1), :day)

      Repo.update_all(from(i in GroupInvitation, where: i.id == ^ctx.invitation.id),
        set: [inserted_at: at]
      )

      invitation = Repo.get!(GroupInvitation, ctx.invitation.id)

      assert {:error, :expired} =
               Social.accept_group_invitation_as(invitation, ctx.account, ctx.other)

      refute Social.member_of_group?(ctx.other, ctx.group)
      refute Repo.get(GroupInvitation, invitation.id)
    end

    test "an accepted invitation is not accepted again", ctx do
      {:ok, accepted} = Social.accept_group_invitation(ctx.invitation, ctx.invited)

      assert {:error, _} = Social.accept_group_invitation_as(accepted, ctx.account, ctx.other)
      refute Social.member_of_group?(ctx.other, ctx.group)
    end
  end

  describe "invitation_profile_choices/2" do
    test "lists the account's other unique profiles, with why one cannot", ctx do
      member = profile!(ctx.account, "aia-member")
      blocked = profile!(ctx.account, "aia-blocked")
      _shared = profile!(ctx.account, "aia-shared", :shared)
      add_member!(ctx.owner, ctx.group, member)
      {:ok, _} = Social.block_from_group(ctx.owner, ctx.group, blocked)

      choices =
        ctx.account
        |> Social.invitation_profile_choices(ctx.invitation)
        |> Map.new(fn {profile, reason} -> {profile.username, reason} end)

      assert choices == %{"aia-blocked" => :blocked, "aia-member" => :member, "aia-other" => nil}
    end
  end

  describe "create_profile_and_accept_invitation/3" do
    test "makes a unique profile and takes it into the group", ctx do
      assert {:ok, %Profile{} = profile, group} =
               Social.create_profile_and_accept_invitation(ctx.account, ctx.invitation, %{
                 "username" => "aia-new",
                 "profile_picture_url" => ""
               })

      assert group.id == ctx.group.id
      assert profile.sharing == :unique
      assert Social.get_profile_for_account(ctx.account, profile.id)
      assert Social.member_of_group?(profile, ctx.group)
      refute Social.member_of_group?(ctx.invited, ctx.group)
      assert Repo.get!(GroupInvitation, ctx.invitation.id).invitee_id == profile.id
    end

    test "a taken name gives the form back, and nothing is accepted", ctx do
      assert {:error, %Ecto.Changeset{}} =
               Social.create_profile_and_accept_invitation(ctx.account, ctx.invitation, %{
                 "username" => "aia-owner"
               })

      assert Repo.get!(GroupInvitation, ctx.invitation.id).accepted_at == nil
    end

    test "a lapsed invitation makes no profile", ctx do
      at = DateTime.add(DateTime.utc_now(:second), -(GroupInvitation.valid_days() + 1), :day)

      Repo.update_all(from(i in GroupInvitation, where: i.id == ^ctx.invitation.id),
        set: [inserted_at: at]
      )

      invitation = Repo.get!(GroupInvitation, ctx.invitation.id)

      assert {:error, :expired} =
               Social.create_profile_and_accept_invitation(ctx.account, invitation, %{
                 "username" => "aia-late"
               })

      refute Social.get_profile_by_username("aia-late")
    end
  end

  defp account_id_of(%Profile{id: profile_id}) do
    Repo.one!(
      from(ap in PotokIde.Social.AccountProfile,
        where: ap.profile_id == ^profile_id,
        select: ap.account_id
      )
    )
  end

  defp insert_request(profile, group) do
    Repo.insert(%GroupJoinRequest{group_id: group.id, requester_id: profile.id})
  end
end
