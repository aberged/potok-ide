defmodule PotokIdeWeb.GroupLive.AppCurrentProfileTest do
  @moduledoc """
  What `getCurrentProfile()` gives an app: of the details and the description
  only what the app's group sees, though the profile itself sees them all.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp app_group!(owner, members, attrs \\ %{}) do
    group_with_members!(
      owner,
      members,
      Map.merge(
        %{
          "description" => "<h1>App</h1>",
          "description_format" => :html,
          "uses_api" => true,
          "home_page" => :description
        },
        attrs
      )
    )
  end

  defp profile_in(conn, account, group) do
    {:ok, lv, _html} =
      conn
      |> log_in_account(Accounts.get_account!(account.id))
      |> live(~p"/groups/#{group.id}/group_home")

    render_hook(lv, "app_api", %{"method" => "current_profile", "params" => %{}, "app_id" => ""})
    assert_reply(lv, %{ok: true, profile: profile})
    profile
  end

  defp save!(account, profile, attrs, details) do
    {:ok, profile} = Social.update_profile_for_account(account, profile.id, attrs, details)
    profile
  end

  defp detail(value, audience, group_ids \\ []),
    do: %{"value" => value, "audience" => audience, "group_ids" => Enum.map(group_ids, &"#{&1}")}

  setup do
    {_owner_account, owner} = account_with_profile!(unique("vlasnik"))
    {account, ana} = account_with_profile!(unique("ana"))
    %{owner: owner, account: account, ana: ana}
  end

  test "each audience, in a group the profile is a member of", %{conn: conn} = ctx do
    here = app_group!(ctx.owner, [ctx.ana])
    elsewhere = group_with_members!(ctx.owner, [ctx.ana])

    save!(
      ctx.account,
      ctx.ana,
      %{
        "description" => "Volim bicikl",
        "description_audience" => "groups",
        "description_group_ids" => ["#{here.id}"]
      },
      %{
        "first_name" => detail("Ana", "shared_groups"),
        "place" => detail("Novi Sad", "signed_in"),
        "phone" => detail("064 111", "groups", [here.id]),
        "occupation" => detail("Arhitektkinja", "groups", [elsewhere.id]),
        "email" => detail("ana@primer.rs", "only_me")
      }
    )

    profile = profile_in(conn, ctx.account, here)

    assert profile.details == %{first_name: "Ana", place: "Novi Sad", phone: "064 111"}
    assert profile.description == "Volim bicikl"
    assert profile.username == ctx.ana.username
  end

  test "nothing is given of a description kept for the profile", %{conn: conn} = ctx do
    group = app_group!(ctx.owner, [ctx.ana])
    save!(ctx.account, ctx.ana, %{"description" => "Samo za mene"}, %{})

    profile = profile_in(conn, ctx.account, group)

    assert profile.description == nil
    assert profile.details == %{}
  end

  test "a non-member of a public group gives only what is for everyone", %{conn: conn} = ctx do
    group = app_group!(ctx.owner, [], %{"is_public" => true, "has_public_chat" => true})
    _elsewhere = group_with_members!(ctx.owner, [ctx.ana])

    save!(
      ctx.account,
      ctx.ana,
      %{"description" => "Komšija", "description_audience" => "shared_groups"},
      %{
        "first_name" => detail("Ana", "shared_groups"),
        "place" => detail("Novi Sad", "signed_in")
      }
    )

    profile = profile_in(conn, ctx.account, group)

    assert profile.details == %{place: "Novi Sad"}
    assert profile.description == nil
  end
end
