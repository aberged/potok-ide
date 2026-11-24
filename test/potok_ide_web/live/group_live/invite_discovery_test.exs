defmodule PotokIdeWeb.GroupLive.InviteDiscoveryTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp discovery!(profile, discovery),
    do: Repo.update!(Ecto.Changeset.change(profile, discovery: discovery))

  defp invite(conn, account, group, identifier) do
    {:ok, lv, _html} =
      conn
      |> log_in_account(Accounts.get_account!(account.id))
      |> live(~p"/groups/#{group.id}/invite_profile")

    lv
    |> form("#group-invite-form-0", %{"invite" => %{"identifier" => identifier}})
    |> render_submit()

    lv
  end

  setup do
    {account, owner} = account_with_profile!(unique("vlasnik"))
    %{account: account, owner: owner, group: group_with_members!(owner, [])}
  end

  test "a hidden name answers as a name nobody has", %{conn: conn} = ctx do
    {_account, hidden} = account_with_profile!(unique("skriven"))
    discovery!(hidden, :shared_groups)

    for name <- [hidden.username, "niko-nema-ovo"] do
      lv = invite(conn, ctx.account, ctx.group, name)
      assert render(lv) =~ "No profile found with that username."
    end

    refute Repo.get_by(Social.GroupInvitation, invitee_id: hidden.id)
  end

  test "a name found by its exact spelling is invited", %{conn: conn} = ctx do
    {_account, known} = account_with_profile!(unique("poznat"))

    lv = invite(conn, ctx.account, ctx.group, known.username)

    assert render(lv) =~ "Invitation sent."
    assert Repo.get_by(Social.GroupInvitation, invitee_id: known.id)
  end

  test "someone sharing a group is invited by name whatever they chose", %{conn: conn} = ctx do
    {_account, friend} = account_with_profile!(unique("drug"))
    _other = group_with_members!(ctx.owner, [friend])
    discovery!(friend, :shared_groups)

    lv = invite(conn, ctx.account, ctx.group, friend.username)

    assert render(lv) =~ "Invitation sent."
  end

  test "looking names up stops at the account's limit", %{conn: conn} = ctx do
    {max, _window} = RateLimit.limit(:profile_lookup)
    for _ <- 1..max, do: :ok = RateLimit.hit(:profile_lookup, ctx.account.id)

    lv = invite(conn, ctx.account, ctx.group, "niko-nema-ovo")

    assert render(lv) =~ "Too many requests"
  end

  test "the card of a hidden profile is not found, a findable one opens", %{conn: conn} = ctx do
    {_account, hidden} = account_with_profile!(unique("skriven"))
    {_account, known} = account_with_profile!(unique("poznat"))
    discovery!(hidden, :shared_groups)
    conn = log_in_account(conn, Accounts.get_account!(ctx.account.id))

    {:ok, lv, _html} = live(conn, ~p"/u/#{hidden.username}")
    assert has_element?(lv, "#profile-card-missing")

    {:ok, lv, _html} = live(conn, ~p"/u/#{known.username}")
    assert has_element?(lv, "#profile-card", known.username)
  end
end
