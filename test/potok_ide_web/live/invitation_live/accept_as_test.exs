defmodule PotokIdeWeb.InvitationLive.AcceptAsTest do
  @moduledoc """
  On Invitations, an invitation to a unique profile can be accepted with
  another unique profile of the account or a new one, which then becomes the
  current profile as the group opens.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.GroupInvitation

  setup %{conn: conn} do
    {_owner_account, owner} = account_with_profile!("aav-owner")
    {account, invited} = account_with_profile!("aav-invited")
    other = profile!(account, "aav-other")
    member = profile!(account, "aav-member")
    group = group_with_members!(owner, [member], %{"name" => "Lipa 5"})
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, invited)
    account = Accounts.get_account!(account.id)

    %{
      conn: log_in_account(conn, account),
      account: account,
      owner: owner,
      invited: invited,
      other: other,
      member: member,
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

  test "the chooser lists the other unique profiles and who cannot", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/invitations")

    refute has_element?(lv, "#accept-as-dialog")
    lv |> element("#invitation-accept-as-#{ctx.invitation.id}") |> render_click()

    assert has_element?(lv, "#accept-as-dialog")
    assert has_element?(lv, "#accept-as-note", "@aav-owner")
    assert has_element?(lv, "#accept-as-profile-#{ctx.other.id}")
    assert has_element?(lv, "#accept-as-choice-#{ctx.member.id}")
    refute has_element?(lv, "#accept-as-profile-#{ctx.member.id}")
    refute has_element?(lv, "#accept-as-choice-#{ctx.invited.id}")

    lv |> element("#accept-as-close") |> render_click()
    refute has_element?(lv, "#accept-as-dialog")
  end

  test "joining with another profile makes it current and opens the group", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/invitations")

    lv |> element("#invitation-accept-as-#{ctx.invitation.id}") |> render_click()
    lv |> element("#accept-as-profile-#{ctx.other.id}") |> render_click()

    group_path = ~p"/groups/#{ctx.group.id}"
    assert_redirect(lv, group_path)

    assert Social.member_of_group?(ctx.other, ctx.group)
    assert Accounts.get_account!(ctx.account.id).current_profile_id == ctx.other.id

    {:ok, group_lv, _html} = live(ctx.conn, group_path)
    assert render(group_lv) =~ "Lipa 5"
  end

  test "a new profile joins through the profile window", ctx do
    {:ok, lv, _html} = live(ctx.conn, ~p"/invitations")

    lv |> element("#invitation-accept-as-#{ctx.invitation.id}") |> render_click()
    lv |> element("#accept-as-new") |> render_click()

    refute has_element?(lv, "#accept-as-dialog")
    assert has_element?(lv, "#welcome-dialog-title", "New profile")
    refute has_element?(lv, "#welcome-remember-me")

    lv
    |> form("#welcome-profile-form", profile: %{username: "aav-owner"})
    |> render_submit()

    assert has_element?(lv, "#welcome-profile-form")
    refute Repo.get!(GroupInvitation, ctx.invitation.id).accepted_at

    lv
    |> form("#welcome-profile-form", profile: %{username: "aav-new"})
    |> render_submit()

    group_path = ~p"/groups/#{ctx.group.id}"
    assert_redirect(lv, group_path)

    new = Social.get_profile_by_username("aav-new")
    assert new.sharing == :unique
    assert Social.member_of_group?(new, ctx.group)
    assert Accounts.get_account!(ctx.account.id).current_profile_id == new.id
  end

  test "a shared current profile is not offered the choice", ctx do
    shared = profile!(ctx.account, "aav-shared", :shared)
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, shared)
    {:ok, _account} = Accounts.set_current_profile(ctx.account, shared)

    {:ok, lv, _html} = live(ctx.conn, ~p"/invitations")

    assert has_element?(lv, "#invitation-accept-#{invitation.id}")
    refute has_element?(lv, "#invitation-accept-as-#{invitation.id}")
  end
end
