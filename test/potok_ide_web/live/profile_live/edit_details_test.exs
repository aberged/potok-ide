defmodule PotokIdeWeb.ProfileLive.EditDetailsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.ProfileDetails

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp live_edit(conn, account, profile) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(~p"/profiles/#{profile.id}/edit")
  end

  setup do
    {account, profile} = account_with_profile!(unique("ana"))
    %{account: account, profile: profile}
  end

  test "the details tab holds every field with who sees it", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_edit(conn, ctx.account, ctx.profile)

    lv |> element("#profile-edit-tab-details") |> render_click()

    assert has_element?(lv, "#profile-edit-details:not(.hidden)")

    for key <- ~w(first_name last_name occupation place phone email website) do
      assert has_element?(
               lv,
               "#profile-edit-detail-#{key}-field textarea, #profile-edit-detail-#{key}-field input[name='details[#{key}][value]']"
             )

      assert has_element?(
               lv,
               "#profile-edit-detail-#{key}-audience select[name='details[#{key}][audience]']"
             )
    end

    # Names start for the groups, a phone for the profile alone.
    assert has_element?(
             lv,
             "select[name='details[first_name][audience]'] option[value='shared_groups'][selected]"
           )

    assert has_element?(
             lv,
             "select[name='details[phone][audience]'] option[value='only_me'][selected]"
           )

    assert has_element?(
             lv,
             "#profile-edit-description-audience select[name='profile[description_audience]']"
           )
  end

  test "saving stores the details", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_edit(conn, ctx.account, ctx.profile)

    lv
    |> form("#edit-profile-form",
      details: %{
        first_name: %{value: "Ana", audience: "signed_in"},
        email: %{value: "ana@primer.rs", audience: "shared_groups"}
      }
    )
    |> render_change()

    assert has_element?(lv, "#profile-edit-save-bar")

    lv
    |> form("#edit-profile-form",
      details: %{
        first_name: %{value: "Ana", audience: "signed_in"},
        email: %{value: "ana@primer.rs", audience: "shared_groups"}
      }
    )
    |> render_submit()

    assert_redirect(lv, ~p"/profiles")

    assert [
             %{key: :first_name, value: "Ana", audience: :signed_in},
             %{key: :email, value: "ana@primer.rs", audience: :shared_groups}
           ] = ProfileDetails.list_fields(ctx.profile)
  end

  test "picked groups list the profile's own groups, not its direct conversations",
       %{conn: conn} = ctx do
    {_account, marko} = account_with_profile!(unique("marko"))
    group = group_with_members!(ctx.profile, [marko])
    {:ok, direct} = Social.get_or_create_direct_group(ctx.profile, marko)

    {:ok, lv, _html} = live_edit(conn, ctx.account, ctx.profile)

    refute has_element?(lv, "#profile-edit-detail-phone-audience-groups")

    lv
    |> form("#edit-profile-form", details: %{phone: %{value: "064 111", audience: "groups"}})
    |> render_change()

    assert has_element?(
             lv,
             "#profile-edit-detail-phone-audience-groups input[type='checkbox'][value='#{group.id}']"
           )

    refute has_element?(
             lv,
             "#profile-edit-detail-phone-audience-groups input[value='#{direct.id}']"
           )

    lv
    |> form("#edit-profile-form",
      details: %{phone: %{value: "064 111", audience: "groups", group_ids: ["#{group.id}"]}}
    )
    |> render_submit()

    assert_redirect(lv, ~p"/profiles")
    assert [%{key: :phone, group_ids: [group_id]}] = ProfileDetails.list_fields(ctx.profile)
    assert group_id == group.id
  end

  test "a description for picked groups opens unchanged, even after leaving one",
       %{conn: conn} = ctx do
    {_account, marko} = account_with_profile!(unique("marko"))
    group = group_with_members!(marko, [ctx.profile])
    left = group_with_members!(marko, [ctx.profile])

    {:ok, _} =
      Social.update_profile_for_account(ctx.account, ctx.profile.id, %{
        "description" => "Komšija",
        "description_audience" => "groups",
        "description_group_ids" => ["#{group.id}", "#{left.id}"]
      })

    {:ok, _} = Social.leave_group(ctx.profile, left)

    {:ok, lv, _html} = live_edit(conn, ctx.account, ctx.profile)

    refute has_element?(lv, "#profile-edit-save-bar")

    assert has_element?(
             lv,
             "#profile-edit-description-audience-groups input[value='#{group.id}'][checked]"
           )
  end

  test "a wrong detail opens its tab and saves nothing", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_edit(conn, ctx.account, ctx.profile)

    lv
    |> form("#edit-profile-form", details: %{phone: %{value: "zovi me", audience: "only_me"}})
    |> render_submit()

    assert has_element?(lv, "#profile-edit-details:not(.hidden)")
    assert has_element?(lv, "#profile-edit-detail-phone-field", "is not a phone number")
    assert ProfileDetails.list_fields(ctx.profile) == []
  end

  test "a new profile cannot pick groups for its description", %{conn: conn} = ctx do
    {:ok, lv, _html} =
      conn
      |> log_in_account(Accounts.get_account!(ctx.account.id))
      |> live(~p"/profiles/new")

    assert has_element?(
             lv,
             "#profile-new-description-audience select option[value='shared_groups']"
           )

    refute has_element?(lv, "#profile-new-description-audience select option[value='groups']")
  end
end
