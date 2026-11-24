defmodule PotokIdeWeb.InvitationLive.AccountInvitationsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.EmailInvitations

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp live_invitations(conn, account) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(~p"/invitations")
  end

  defp invite!(ctx) do
    :ok =
      EmailInvitations.invite(
        ctx.owner,
        ctx.owner_account.id,
        ctx.group,
        ctx.account.email,
        &"/log-in/#{&1}"
      )

    [invitation] = EmailInvitations.list(ctx.account)
    invitation
  end

  defp current!(account),
    do: Social.get_account_current_profile(Accounts.get_account!(account.id))

  setup do
    {owner_account, owner} = account_with_profile!(unique("vlasnik"))
    {account, profile} = account_with_profile!(unique("pozvan"))

    {:ok, second} =
      Social.create_profile_for_account(account, %{
        username: unique("drugi"),
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    %{
      owner_account: owner_account,
      owner: owner,
      group: group_with_members!(owner, []),
      account: account,
      profile: profile,
      second: second
    }
  end

  test "the current profile joins", %{conn: conn} = ctx do
    invitation = invite!(ctx)
    {:ok, lv, _html} = live_invitations(conn, ctx.account)

    assert has_element?(lv, "#account-invitation-#{invitation.id}", ctx.group.name)

    assert has_element?(
             lv,
             "#account-invitation-inviter-#{invitation.id}[href='/u/#{ctx.owner.username}']"
           )

    lv |> element("#account-invitation-accept-#{invitation.id}") |> render_click()

    assert_redirect(lv, ~p"/groups/#{ctx.group.id}")
    assert Social.member_of_group?(ctx.profile, ctx.group)
  end

  test "it shows whichever profile is current, and another one joins",
       %{conn: conn} = ctx do
    invitation = invite!(ctx)
    {:ok, _} = Accounts.set_current_profile(ctx.account, ctx.second)
    {:ok, lv, _html} = live_invitations(conn, ctx.account)

    lv |> element("#account-invitation-accept-as-#{invitation.id}") |> render_click()

    assert has_element?(lv, "#accept-as-dialog")
    assert has_element?(lv, "#accept-as-choice-#{ctx.profile.id}")
    assert has_element?(lv, "#accept-as-choice-#{ctx.second.id}")

    lv |> element("#accept-as-profile-#{ctx.profile.id}") |> render_click()

    assert_redirect(lv, ~p"/groups/#{ctx.group.id}")
    assert Social.member_of_group?(ctx.profile, ctx.group)
    refute Social.member_of_group?(ctx.second, ctx.group)
    assert current!(ctx.account).id == ctx.profile.id
  end

  test "a new profile joins", %{conn: conn} = ctx do
    invitation = invite!(ctx)
    {:ok, lv, _html} = live_invitations(conn, ctx.account)

    lv |> element("#account-invitation-accept-as-#{invitation.id}") |> render_click()
    lv |> element("#accept-as-new") |> render_click()
    username = unique("nov")
    render_hook(lv, "create_profile", %{"profile" => %{"username" => username}})

    assert_redirect(lv, ~p"/groups/#{ctx.group.id}")
    assert current!(ctx.account).username == username
    assert Social.member_of_group?(current!(ctx.account), ctx.group)
  end

  test "a member is told why, and the invitation stays", %{conn: conn} = ctx do
    add_member!(ctx.owner, ctx.group, ctx.profile)
    invitation = invite!(ctx)
    {:ok, lv, _html} = live_invitations(conn, ctx.account)

    lv |> element("#account-invitation-accept-#{invitation.id}") |> render_click()

    assert has_element?(lv, "#flash-error p", "That profile is already a member of the group.")
    assert has_element?(lv, "#account-invitation-#{invitation.id}")
  end

  test "deleting it takes it off both pages at once", %{conn: conn} = ctx do
    invitation = invite!(ctx)
    {:ok, lv, _html} = live_invitations(conn, ctx.account)
    {:ok, sent, _html} = live_invitations(build_conn(), ctx.owner_account)
    sent |> element("#invitations-tab-sent") |> render_click()

    assert has_element?(sent, "#sent-by-email-#{invitation.id}", ctx.account.email)
    refute render(sent) =~ ctx.profile.username

    lv |> element("#account-invitation-delete-#{invitation.id}") |> render_click()

    refute has_element?(lv, "#account-invitations")
    refute has_element?(sent, "#sent-by-email-#{invitation.id}")
    assert EmailInvitations.list(ctx.account) == []
  end

  test "a new one reaches the page and the badge while they are open", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_invitations(conn, ctx.account)
    refute has_element?(lv, "#account-invitations")

    invitation = invite!(ctx)

    assert has_element?(lv, "#account-invitation-#{invitation.id}")
    assert_push_event(lv, "pending_invitations_count_updated", %{count: 1})
  end

  test "someone else's invitation is not found", %{conn: conn} = ctx do
    invitation = invite!(ctx)
    {other_account, other} = account_with_profile!(unique("tudj"))
    {:ok, lv, _html} = live_invitations(conn, other_account)

    for event <-
          ~w(account_invitation_accept account_invitation_accept_as account_invitation_delete) do
      render_hook(lv, event, %{"id" => "#{invitation.id}"})
    end

    refute has_element?(lv, "#accept-as-dialog")
    refute Social.member_of_group?(other, ctx.group)
    assert [_waiting] = EmailInvitations.list(ctx.account)
  end
end
