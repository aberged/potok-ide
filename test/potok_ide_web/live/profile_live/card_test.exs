defmodule PotokIdeWeb.ProfileLive.CardTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Profile

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp live_as(conn, account, path) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(path)
  end

  setup do
    {ana_account, ana} = account_with_profile!(unique("ana"))
    {marko_account, marko} = account_with_profile!(unique("marko"))
    {stranger_account, _stranger} = account_with_profile!(unique("stranac"))

    {:ok, ana} =
      Social.update_profile_for_account(
        ana_account,
        ana.id,
        %{"description" => "Volim bicikl", "description_audience" => "shared_groups"},
        %{
          "first_name" => %{"value" => "Ana", "audience" => "shared_groups"},
          "place" => %{"value" => "Novi Sad", "audience" => "signed_in"},
          "phone" => %{"value" => "064 111 222", "audience" => "only_me"},
          "website" => %{"value" => "ana.rs", "audience" => "signed_in"}
        }
      )

    %{
      ana: ana,
      ana_account: ana_account,
      marko: marko,
      marko_account: marko_account,
      stranger_account: stranger_account
    }
  end

  test "a stranger sees only what is for everyone signed in", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_as(conn, ctx.stranger_account, ~p"/u/#{ctx.ana.username}")

    assert has_element?(lv, "#profile-card", ctx.ana.username)
    assert has_element?(lv, "#profile-card-field-place", "Novi Sad")

    assert has_element?(
             lv,
             "#profile-card-field-website a[href='https://ana.rs'][rel='nofollow noopener noreferrer ugc']"
           )

    refute render(lv) =~ "064 111 222"
    refute render(lv) =~ ">Ana<"
    refute has_element?(lv, "#profile-card-description")
    refute has_element?(lv, "#profile-card-groups")
  end

  test "someone in a group with the profile sees what is for its groups", %{conn: conn} = ctx do
    group = group_with_members!(ctx.ana, [ctx.marko])

    {:ok, lv, _html} = live_as(conn, ctx.marko_account, ~p"/u/#{ctx.ana.username}")

    assert render(lv) =~ "Ana"
    assert has_element?(lv, "#profile-card-description", "Volim bicikl")
    assert has_element?(lv, "#profile-card-group-#{group.id}", group.name)
    refute render(lv) =~ "064 111 222"
  end

  test "the profile's own account sees everything", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_as(conn, ctx.ana_account, ~p"/u/#{ctx.ana.username}")

    assert has_element?(lv, "#profile-card-field-phone a[href='tel:064111222']", "064 111 222")
    refute has_element?(lv, "#profile-card-message")
  end

  test "an unknown name, a process and a deleted profile look the same", %{conn: conn} = ctx do
    process =
      Repo.insert!(%Profile{username: unique("proces."), kind: :process, sharing: :unique})

    deleted = Repo.update!(Ecto.Changeset.change(ctx.marko, kind: :deleted))

    for name <- ["nema-ga", process.username, deleted.username] do
      {:ok, lv, _html} = live_as(conn, ctx.stranger_account, ~p"/u/#{name}")

      assert has_element?(lv, "#profile-card-missing")
      refute has_element?(lv, "#profile-card")
    end
  end

  test "the button writes to the profile", %{conn: conn} = ctx do
    {:ok, lv, _html} = live_as(conn, ctx.marko_account, ~p"/u/#{ctx.ana.username}")

    assert {:error, {:live_redirect, %{to: to}}} =
             lv |> element("#profile-card-message") |> render_click()

    assert {:ok, direct} = Social.get_or_create_direct_group(ctx.marko, ctx.ana)
    assert to == "/groups/#{direct.id}/values"
  end
end
