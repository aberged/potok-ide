defmodule PotokIdeWeb.GroupLive.ProfileCardTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.{GroupRequests, ProfileDetails, ProfileFacts}

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp live_as(conn, account, path) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(path)
  end

  defp name!(account, profile, audience \\ "shared_groups", group_ids \\ []) do
    {:ok, profile} =
      Social.update_profile_for_account(account, profile.id, %{}, %{
        "first_name" => %{
          "value" => "Ime-#{profile.username}",
          "audience" => audience,
          "group_ids" => group_ids
        }
      })

    profile
  end

  setup do
    {ana_account, ana} = account_with_profile!(unique("ana"))
    {marko_account, marko} = account_with_profile!(unique("marko"))
    %{ana: ana, ana_account: ana_account, marko: marko, marko_account: marko_account}
  end

  test "a member's name opens their card, with their name under it", %{conn: conn} = ctx do
    group = group_with_members!(ctx.ana, [ctx.marko])
    name!(ctx.marko_account, ctx.marko)

    {:ok, lv, _html} = live_as(conn, ctx.ana_account, ~p"/groups/#{group.id}/members")

    assert has_element?(lv, "#member-#{ctx.marko.id}", "Ime-#{ctx.marko.username}")

    lv
    |> element("#member-#{ctx.marko.id} button[phx-click='open_profile_card']")
    |> render_click()

    assert has_element?(lv, "#profile-card-dialog #profile-card", ctx.marko.username)
    assert has_element?(lv, "#profile-card-message")

    lv |> element("#profile-card-close") |> render_click()
    refute has_element?(lv, "#profile-card-dialog")
  end

  test "the author of a message in an open chat opens for a non-member", %{conn: conn} = ctx do
    {:ok, group} =
      Social.create_group(ctx.ana, Social.get_root_group!(), %{
        "name" => unique("otvoreno"),
        "description" => "",
        "description_format" => :markdown,
        "home_page" => :chat,
        "is_public" => true,
        "has_public_chat" => true
      })

    {:ok, value} =
      Social.create_value(ctx.ana, group, %{
        "content" => "Dobro došli",
        "content_format" => "markdown"
      })

    {:ok, lv, _html} = live_as(conn, ctx.marko_account, ~p"/groups/#{group.id}/values")

    lv |> element("#value-author-#{value.id}") |> render_click()

    assert has_element?(lv, "#profile-card-dialog #profile-card", ctx.ana.username)

    lv |> element("#profile-card-close") |> render_click()
    refute has_element?(lv, "#profile-card-dialog")

    # The picture opens it too, and as a button it cuts itself to a circle,
    # which daisyUI's `.avatar` does for a `div` only.
    avatar = "button#value-author-avatar-#{value.id}.rounded-full.overflow-hidden"
    assert has_element?(lv, avatar <> " img")
    lv |> element(avatar) |> render_click()

    assert has_element?(lv, "#profile-card-dialog #profile-card", ctx.ana.username)
  end

  test "someone the group does not show opens nothing", %{conn: conn} = ctx do
    group = group_with_members!(ctx.ana, [])
    {_account, stranger} = account_with_profile!(unique("stranac"))

    {:ok, lv, _html} = live_as(conn, ctx.ana_account, ~p"/groups/#{group.id}/values")

    render_hook(lv, "open_profile_card", %{"id" => stranger.id})
    render_hook(lv, "open_profile_card", %{"id" => "nije-broj"})

    refute has_element?(lv, "#profile-card-dialog")
  end

  test "whoever decides a request sees the one asking as a member would", ctx do
    group = group_with_members!(ctx.ana, [ctx.marko], %{"is_public" => true})
    {asker_account, asker} = account_with_profile!(unique("molba"))
    asker = name!(asker_account, asker)
    {:ok, _request} = GroupRequests.request_access(asker, group, %{})

    manager = ProfileFacts.load(ctx.ana_account, ctx.ana, asker)
    assert MapSet.member?(manager.relation_group_ids, group.id)

    assert [%{key: :first_name}] =
             ProfileDetails.visible_fields(ProfileDetails.list_fields(asker), manager)

    member = ProfileFacts.load(ctx.marko_account, ctx.marko, asker)
    assert MapSet.size(member.relation_group_ids) == 0
    assert ProfileDetails.visible_fields(ProfileDetails.list_fields(asker), member) == []
  end

  test "the invited sees the inviter as a member of the group would", ctx do
    group = group_with_members!(ctx.ana, [])
    ana = name!(ctx.ana_account, ctx.ana, "groups", ["#{group.id}"])
    {:ok, _invitation} = Social.invite_profile_to_group(ana, group, ctx.marko)

    facts = ProfileFacts.load(ctx.marko_account, ctx.marko, ana)

    assert MapSet.member?(facts.relation_group_ids, group.id)

    assert [%{key: :first_name}] =
             ProfileDetails.visible_fields(ProfileDetails.list_fields(ana), facts)
  end
end
