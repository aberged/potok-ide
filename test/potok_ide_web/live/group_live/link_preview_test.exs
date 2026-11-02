defmodule PotokIdeWeb.GroupLive.LinkPreviewTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.LinkPreviews
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Value

  setup %{conn: conn} do
    Req.Test.stub(LinkPreviews, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, """
      <html><head>
        <meta property="og:title" content="Example article">
        <meta property="og:description" content="A short summary.">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="https://cdn.example.com/card.png">
      </head></html>
      """)
    end)

    {account, profile} = account_with_profile!("lp-live-owner")

    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "lp-live-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    %{conn: log_in_account(conn, account), profile: profile, group: group}
  end

  test "shows the card of a value's link", %{conn: conn, profile: profile, group: group} do
    {:ok, value} =
      Social.create_value(profile, group, %{"content" => "read https://example.com/article"})

    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

    card = "#value-link-preview-#{value.id}"
    assert has_element?(lv, card, "Example article")
    assert has_element?(lv, card, "A short summary.")
    assert has_element?(lv, card, "Example")

    assert has_element?(
             lv,
             "#value-link-preview-link-#{value.id}[href='https://example.com/article'][target=_blank]"
           )

    assert has_element?(
             lv,
             "#value-link-preview-image-#{value.id}[src='https://cdn.example.com/card.png'][referrerpolicy=no-referrer]"
           )
  end

  test "the card of a posted value shows up in the open chat", %{conn: conn, group: group} do
    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")
    Req.Test.allow(LinkPreviews, self(), lv.pid)

    lv
    |> form("#group-value-form", value: %{content: "https://example.com/new"})
    |> render_submit()

    assert [value] = Repo.all(Value)
    assert has_element?(lv, "#value-link-preview-#{value.id}", "Example article")
  end

  test "the author can remove the card, other members cannot", %{
    conn: conn,
    profile: profile,
    group: group
  } do
    {member_account, member} = account_with_profile!("lp-live-member")
    {:ok, invitation} = Social.invite_profile_to_group(profile, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)

    {:ok, value} = Social.create_value(profile, group, %{"content" => "https://example.com/x"})

    {:ok, member_lv, _html} =
      build_conn()
      |> log_in_account(member_account)
      |> live(~p"/groups/#{group.id}/values")

    assert has_element?(member_lv, "#value-link-preview-#{value.id}")
    refute has_element?(member_lv, "#value-link-preview-dismiss-#{value.id}")

    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

    lv |> element("#value-link-preview-dismiss-#{value.id}") |> render_click()

    refute has_element?(lv, "#value-link-preview-#{value.id}")
    refute has_element?(member_lv, "#value-link-preview-#{value.id}")
    assert Repo.get!(Value, value.id).link_preview_dismissed
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {Accounts.get_account!(account.id), profile}
  end
end
