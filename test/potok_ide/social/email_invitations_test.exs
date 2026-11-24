defmodule PotokIde.Social.EmailInvitationsTest do
  # Not async: the push capture is global (`capture_push_requests!/0`).
  use PotokIde.DataCase, async: false

  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    EmailInvitations,
    GroupAccountInvitation,
    GroupInvitation,
    ProfileFacts
  }

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp invite(ctx, email),
    do:
      EmailInvitations.invite(ctx.owner, ctx.owner_account.id, ctx.group, email, &"/log-in/#{&1}")

  defp invitation!(ctx, account \\ nil) do
    account = account || ctx.account
    :ok = invite(ctx, account.email)
    [invitation] = EmailInvitations.list(account)
    invitation
  end

  defp age!(schema, id, days) do
    at = DateTime.add(DateTime.utc_now(:second), -days, :day)
    Repo.update_all(from(i in schema, where: i.id == ^id), set: [inserted_at: at])
    at
  end

  # Accounts of the fixtures get emails of their own.
  defp empty_mailbox do
    receive do
      {:email, _email} -> empty_mailbox()
    after
      0 -> :ok
    end
  end

  setup do
    {owner_account, owner} = account_with_profile!(unique("vlasnik"))
    {account, profile} = account_with_profile!(unique("pozvan"))

    %{
      owner_account: owner_account,
      owner: owner,
      group: group_with_members!(owner, []),
      account: account,
      profile: profile
    }
  end

  describe "invite/5" do
    test "answers the same for an account, one with no profile and none", ctx do
      new = unique_account_email()
      without_profile = account_fixture()
      empty_mailbox()

      for email <- [ctx.account.email, without_profile.email, new] do
        assert invite(ctx, email) == :ok
      end

      assert_received {:email, %Swoosh.Email{to: [{"", ^new}]}}
      refute_received {:email, %Swoosh.Email{to: [{"", _other}]}}

      refute Repo.exists?(GroupInvitation)
      assert Repo.aggregate(GroupAccountInvitation, :count) == 3
    end

    test "counts every address against the inviter's limit", ctx do
      {max, _window} = RateLimit.limit(:invitation_email)
      for _ <- 1..(max - 1), do: RateLimit.hit(:invitation_email, ctx.owner_account.id)

      assert invite(ctx, ctx.account.email) == :ok
      assert {:error, :rate_limited, _} = invite(ctx, unique_account_email())
      assert {:error, :rate_limited, _} = invite(ctx, account_fixture().email)
    end

    test "says only what concerns the inviter", ctx do
      {outsider_account, outsider} = account_with_profile!(unique("stranac"))
      empty_mailbox()

      assert EmailInvitations.invite(
               outsider,
               outsider_account.id,
               ctx.group,
               unique_account_email(),
               & &1
             ) == {:error, :inviter_not_a_member}

      refute_received {:email, _email}
    end

    test "each inviter keeps their own, with the address they typed", ctx do
      {other_account, other} = account_with_profile!(unique("drugi"))
      add_member!(ctx.owner, ctx.group, other)

      :ok = invite(ctx, ctx.account.email)
      :ok = invite(ctx, ctx.account.email)
      :ok = EmailInvitations.invite(other, other_account.id, ctx.group, ctx.account.email, & &1)

      assert length(EmailInvitations.list(ctx.account)) == 2

      email = ctx.account.email
      assert [%{email: ^email}] = EmailInvitations.list_sent(ctx.owner)
      assert [%{email: ^email}] = EmailInvitations.list_sent(other)
    end

    test "a lapsed invitation makes way for a new one", ctx do
      old = invitation!(ctx)
      age!(GroupAccountInvitation, old.id, GroupInvitation.valid_days() + 1)

      assert EmailInvitations.list(ctx.account) == []
      assert invitation!(ctx).id != old.id
    end

    test "pushes to the account's devices, and tells no other holder of its profiles", ctx do
      capture_push_requests!()
      endpoint = push_device!(ctx.account)
      _other = push_device!(account_fixture())

      :ok = invite(ctx, ctx.account.email)

      assert pushed_endpoints() == [endpoint]
    end

    test "links to log in stop at the address's limit, the answer stays", ctx do
      account = unconfirmed_account_fixture()
      key = RateLimit.email_key(account.email)
      {max, _window} = RateLimit.limit(:magic_link_email)
      for _ <- 1..max, do: RateLimit.hit(:magic_link_email, key)
      empty_mailbox()

      assert invite(ctx, account.email) == :ok
      refute_received {:email, _email}
      assert [_invitation] = EmailInvitations.list(account)
    end
  end

  describe "accept/3" do
    test "the profile joins, and only then does the inviter see it", ctx do
      invitation = invitation!(ctx)
      sent_at = age!(GroupAccountInvitation, invitation.id, 3)
      invitation = EmailInvitations.get(ctx.account, invitation.id)

      refute Repo.exists?(from(i in GroupInvitation, where: i.inviter_id == ^ctx.owner.id))

      assert {:ok, group} = EmailInvitations.accept(ctx.account, invitation, ctx.profile)

      assert group.id == ctx.group.id
      assert Social.member_of_group?(ctx.profile, ctx.group)
      assert EmailInvitations.list(ctx.account) == []
      assert EmailInvitations.list_sent(ctx.owner) == []

      assert [%GroupInvitation{accepted_at: %DateTime{}, inserted_at: ^sent_at} = accepted] =
               Repo.all(from(i in GroupInvitation, where: i.invitee_id == ^ctx.profile.id))

      assert accepted.inviter_id == ctx.owner.id

      refute Social.get_root_group!()
             |> Social.list_child_groups()
             |> Enum.any?(& &1.is_direct)
    end

    test "a member or a blocked profile is refused, and the invitation waits", ctx do
      invitation = invitation!(ctx)
      add_member!(ctx.owner, ctx.group, ctx.profile)

      assert EmailInvitations.choices(ctx.account, invitation) == [{ctx.profile, :member}]

      assert {:error, :member} = EmailInvitations.accept(ctx.account, invitation, ctx.profile)
      assert [_waiting] = EmailInvitations.list(ctx.account)

      {blocked_account, blocked} = account_with_profile!(unique("blokiran"))
      {:ok, _block} = Social.block_from_group(ctx.owner, ctx.group, blocked)
      invitation = invitation!(ctx, blocked_account)

      assert {:error, :blocked} = EmailInvitations.accept(blocked_account, invitation, blocked)
      refute Repo.exists?(from(i in GroupInvitation, where: i.invitee_id == ^blocked.id))
    end

    test "only the account it is for, with a profile it holds", ctx do
      invitation = invitation!(ctx)
      {other_account, other} = account_with_profile!(unique("tudj"))

      assert {:error, :not_found} = EmailInvitations.accept(other_account, invitation, other)
      assert {:error, :not_held} = EmailInvitations.accept(ctx.account, invitation, other)
      assert EmailInvitations.get(other_account, invitation.id) == nil
      assert {:error, :not_found} = EmailInvitations.delete(other_account, invitation)
      assert [_waiting] = EmailInvitations.list(ctx.account)
    end

    test "a lapsed one, or one whose inviter left, goes", ctx do
      invitation = invitation!(ctx)
      age!(GroupAccountInvitation, invitation.id, GroupInvitation.valid_days() + 1)
      lapsed = EmailInvitations.get(ctx.account, invitation.id)

      assert {:error, :expired} = EmailInvitations.accept(ctx.account, lapsed, ctx.profile)
      assert EmailInvitations.get(ctx.account, invitation.id) == nil

      {other_account, other} = account_with_profile!(unique("ode"))
      add_member!(ctx.owner, ctx.group, other)
      :ok = EmailInvitations.invite(other, other_account.id, ctx.group, ctx.account.email, & &1)
      [invitation] = EmailInvitations.list(ctx.account)
      {:ok, _} = Social.leave_group(other, ctx.group)

      assert {:error, :lapsed} = EmailInvitations.accept(ctx.account, invitation, ctx.profile)
      refute Social.member_of_group?(ctx.profile, ctx.group)
      assert EmailInvitations.list(ctx.account) == []
    end

    test "a lapsed invitation to the profile itself does not stand in the way", ctx do
      {:ok, own} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.profile)
      age!(GroupInvitation, own.id, GroupInvitation.valid_days() + 1)
      invitation = invitation!(ctx)

      assert {:ok, _group} = EmailInvitations.accept(ctx.account, invitation, ctx.profile)
      assert Social.member_of_group?(ctx.profile, ctx.group)
    end

    test "a new profile joins at once", ctx do
      invitation = invitation!(ctx)

      assert {:ok, profile, group} =
               EmailInvitations.create_profile_and_accept(ctx.account, invitation, %{
                 "username" => unique("nov")
               })

      assert group.id == ctx.group.id
      assert Social.member_of_group?(profile, ctx.group)
      refute Social.member_of_group?(ctx.profile, ctx.group)
    end
  end

  test "the badge counts the account's invitations on its own pages only", ctx do
    {other_account, _other} = account_with_profile!(unique("suvlasnik"))

    {:ok, shared} =
      Social.update_profile_for_account(ctx.account, ctx.profile.id, %{sharing: :shared})

    PotokIde.PollsFixtures.share_profile!(shared, other_account)
    _invitation = invitation!(ctx)

    assert Social.nav_counts(shared, account: ctx.account).pending_invitations == 1
    assert Social.nav_counts(shared, account: other_account).pending_invitations == 0
    assert Social.nav_counts(shared).pending_invitations == 0
  end

  test "the invited account sees the inviter as a member of the group would", ctx do
    _invitation = invitation!(ctx)

    facts = ProfileFacts.load(ctx.account, ctx.profile, ctx.owner)
    assert MapSet.member?(facts.relation_group_ids, ctx.group.id)

    # Not the other way round: the inviter knows an address, not a profile.
    inviter = ProfileFacts.load(ctx.owner_account, ctx.owner, ctx.profile)
    assert MapSet.size(ProfileFacts.group_ids(inviter)) == 0
  end

  test "a deleted account takes its invitations along", ctx do
    _invitation = invitation!(ctx)

    assert {:ok, _} = Accounts.Deletion.delete(ctx.account)
    refute Repo.exists?(GroupAccountInvitation)
  end
end
